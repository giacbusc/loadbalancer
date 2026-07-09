package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/omarshaarawi/loadbalancer/pkg/loadbalancer"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	LevelTrace = slog.Level(-8)
	LevelFatal = slog.Level(12)
)

func getEnvOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvFloat(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

func getEnvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return def
}

func getEnvDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

func main() {
	ctx := context.Background()
	port := flag.String("port", getEnvOrDefault("LB_PORT", "8080"), "Port to listen on")
	algorithm := flag.String("algorithm", getEnvOrDefault("LB_ALGORITHM", "prequal"), "Load balancing algorithm")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	// Backend list from env var, comma-separated: "host1:port,host2:port"
	backendsStr := os.Getenv("BACKENDS")
	if backendsStr == "" {
		backendsStr = "server1:80,server2:80,server3:80"
	}
	backends := strings.Split(backendsStr, ",")

	config := &loadbalancer.Config{
		ProbeInterval:    getEnvDuration("LB_PROBE_INTERVAL", time.Second),
		ProbeTimeout:     getEnvDuration("LB_PROBE_TIMEOUT", 2*time.Second),
		HealthCheckPath:  getEnvOrDefault("LB_HEALTH_PATH", "/health"),
		SelectionChoices: getEnvInt("LB_SELECTION_CHOICES", 2),
		Algorithm:        loadbalancer.Algorithm(*algorithm),
		QRIF:             getEnvFloat("LB_QRIF", 0.84),
		UseServerRIF:     getEnvOrDefault("LB_USE_SERVER_RIF", "false") == "true",
	}

	lb := loadbalancer.NewLoadBalancer(config, logger)

	logger.Info("Load balancer configured",
		slog.String("algorithm", string(config.Algorithm)),
		slog.Float64("qrif", config.QRIF),
		slog.Int("selection_choices", config.SelectionChoices),
		slog.Bool("use_server_rif", config.UseServerRIF),
		slog.Duration("probe_interval", config.ProbeInterval),
		slog.String("backends", backendsStr),
	)

	for i, addr := range backends {
		addr = strings.TrimSpace(addr)
		if addr == "" {
			continue
		}
		lb.AddServer(&loadbalancer.Server{
			ID:        fmt.Sprintf("server-%d", i),
			Address:   addr,
			IsHealthy: true,
		})
		logger.Info("Added backend", slog.String("id", fmt.Sprintf("server-%d", i)), slog.String("address", addr))
	}

	lb.StartProbing()

	mux := http.NewServeMux()
	mux.Handle("/", lb)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"healthy"}`))
	})
	mux.HandleFunc("/admin/algorithm", func(w http.ResponseWriter, r *http.Request) {
		algo := r.URL.Query().Get("algo")
		switch algo {
		case "prequal":
			lb.SetAlgorithm(loadbalancer.AlgorithmPrequal)
		case "rr", "roundrobin":
			lb.SetAlgorithm(loadbalancer.AlgorithmRoundRobin)
		default:
			http.Error(w, `algo must be "prequal" or "rr"`, http.StatusBadRequest)
			return
		}
		fmt.Fprintf(w, "algorithm set to %s\n", algo)
	})
	mux.HandleFunc("/admin/probe-interval", func(w http.ResponseWriter, r *http.Request) {
		v := r.URL.Query().Get("d")
		if v == "" { // GET current value (used by experiment-shock.sh to record it)
			fmt.Fprintf(w, "%s\n", lb.ProbeInterval())
			return
		}
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			http.Error(w, `d must be a positive Go duration, e.g. "250ms", "1s", "2s"`, http.StatusBadRequest)
			return
		}
		lb.SetProbeInterval(d)
		fmt.Fprintf(w, "probe interval set to %s\n", d)
	})
	mux.HandleFunc("/admin/use-server-rif", func(w http.ResponseWriter, r *http.Request) {
		v := r.URL.Query().Get("v")
		switch v {
		case "": // GET current value (recorded by experiment-shock.sh)
			fmt.Fprintf(w, "%t\n", lb.UseServerRIF())
		case "true", "1":
			lb.SetUseServerRIF(true)
			fmt.Fprintf(w, "use_server_rif set to true\n")
		case "false", "0":
			lb.SetUseServerRIF(false)
			fmt.Fprintf(w, "use_server_rif set to false\n")
		default:
			http.Error(w, `v must be "true" or "false"`, http.StatusBadRequest)
		}
	})

	server := &http.Server{
		Addr:    ":" + *port,
		Handler: mux,
	}

	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan
		logger.Info("Shutting down server...")
		shutCtx, cancel := context.WithTimeout(context.Background(), time.Second*10)
		defer cancel()
		if err := server.Shutdown(shutCtx); err != nil {
			logger.Error("Server shutdown error", slog.String("error", err.Error()))
		}
	}()

	logger.Info("Starting server on port " + *port)
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		logger.Log(ctx, LevelFatal, "Server error", slog.String("error", err.Error()))
	}
}
