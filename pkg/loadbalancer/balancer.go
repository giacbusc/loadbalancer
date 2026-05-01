package loadbalancer

import (
	"context"
	"log/slog"
	"math/rand"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

type LoadBalancer struct {
	servers   []*Server
	probePool map[string]*ProbeResult
	config    *Config
	stats     *Stats
	logger    *slog.Logger
	metrics   *Metrics
	mutex     sync.RWMutex
	rrIndex   uint32
}

func NewLoadBalancer(config *Config, logger *slog.Logger) *LoadBalancer {
	if config == nil {
		config = &Config{
			ProbeInterval:    time.Second,
			ProbeTimeout:     time.Second * 2,
			HealthCheckPath:  "/health",
			SelectionChoices: 2,
			Algorithm:        AlgorithmPrequal,
			QRIF:             0.84,
		}
	}
	if config.Algorithm == "" {
		config.Algorithm = AlgorithmPrequal
	}
	if config.QRIF == 0 {
		config.QRIF = 0.84
	}

	return &LoadBalancer{
		servers:   make([]*Server, 0),
		probePool: make(map[string]*ProbeResult),
		config:    config,
		stats:     &Stats{},
		logger:    logger,
		metrics:   NewMetrics(),
	}
}

func (lb *LoadBalancer) StartProbing() {
	go func() {
		ticker := time.NewTicker(lb.config.ProbeInterval)
		defer ticker.Stop()
		for range ticker.C {
			lb.probeAllServers()
		}
	}()
}

func (lb *LoadBalancer) probeAllServers() {
	lb.mutex.RLock()
	servers := make([]*Server, len(lb.servers))
	copy(servers, lb.servers)
	lb.mutex.RUnlock()

	for _, server := range servers {
		go func(srv *Server) {
			result := lb.probeServer(srv)

			lb.mutex.Lock()
			lb.probePool[srv.ID] = result
			srv.IsHealthy = result.IsHealthy
			srv.Latency = result.Latency
			atomic.StoreInt32(&srv.ServerRIF, result.ServerRIF)
			lb.mutex.Unlock()

			algorithm := string(lb.config.Algorithm)
			if result.IsHealthy {
				lb.metrics.serverHealth.WithLabelValues(srv.ID, algorithm).Set(1)
			} else {
				lb.metrics.serverHealth.WithLabelValues(srv.ID, algorithm).Set(0)
			}
			lb.metrics.serverRIFReported.WithLabelValues(srv.ID, algorithm).Set(float64(result.ServerRIF))
		}(server)
	}
}

func (lb *LoadBalancer) probeServer(server *Server) *ProbeResult {
	ctx, cancel := context.WithTimeout(context.Background(), lb.config.ProbeTimeout)
	defer cancel()

	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, "GET",
		"http://"+server.Address+lb.config.HealthCheckPath, nil)
	if err != nil {
		return &ProbeResult{Timestamp: time.Now(), IsHealthy: false}
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return &ProbeResult{Timestamp: time.Now(), IsHealthy: false}
	}
	defer resp.Body.Close()

	duration := time.Since(start)

	// Parse server-reported RIF from header (set by backend middleware).
	var serverRIF int32
	if v := resp.Header.Get("X-Server-RIF"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			serverRIF = int32(n)
		}
	}

	return &ProbeResult{
		Timestamp: time.Now(),
		RIF:       atomic.LoadInt32(&server.RIF),
		ServerRIF: serverRIF,
		Latency:   duration.Milliseconds(),
		IsHealthy: resp.StatusCode == http.StatusOK,
	}
}

func (lb *LoadBalancer) AddServer(server *Server) {
	lb.mutex.Lock()
	defer lb.mutex.Unlock()
	lb.servers = append(lb.servers, server)
}

func (lb *LoadBalancer) SelectServer() *Server {
	if lb.config.Algorithm == AlgorithmRoundRobin {
		return lb.selectServerRR()
	}
	return lb.selectServerPrequal()
}

func (lb *LoadBalancer) selectServerRR() *Server {
	lb.mutex.RLock()
	defer lb.mutex.RUnlock()

	if len(lb.servers) == 0 {
		return nil
	}
	healthyServers := make([]*Server, 0, len(lb.servers))
	for _, server := range lb.servers {
		if server.IsHealthy {
			healthyServers = append(healthyServers, server)
		}
	}
	if len(healthyServers) == 0 {
		return nil
	}
	index := atomic.AddUint32(&lb.rrIndex, 1)
	return healthyServers[int(index-1)%len(healthyServers)]
}

func (lb *LoadBalancer) selectServerPrequal() *Server {
	lb.mutex.RLock()
	defer lb.mutex.RUnlock()

	if len(lb.servers) == 0 {
		return nil
	}

	// Sample d candidates with replacement (simplification of the paper's
	// "without replacement", acceptable when n_servers >> d).
	n := len(lb.servers)
	d := lb.config.SelectionChoices
	if d > n {
		d = n
	}
	candidates := make([]*Server, 0, d)
	for i := 0; i < d; i++ {
		candidates = append(candidates, lb.servers[rand.Intn(n)])
	}

	return lb.selectBestCandidate(candidates)
}

// rifFor returns the RIF value used for HCL classification.
// If UseServerRIF is enabled, returns the server-reported RIF;
// otherwise returns the client-local RIF.
func (lb *LoadBalancer) rifFor(s *Server) int32 {
	if lb.config.UseServerRIF {
		return atomic.LoadInt32(&s.ServerRIF)
	}
	return atomic.LoadInt32(&s.RIF)
}

func (lb *LoadBalancer) selectBestCandidate(candidates []*Server) *Server {
	healthy := make([]*Server, 0, len(candidates))
	for _, s := range candidates {
		if s.IsHealthy {
			healthy = append(healthy, s)
		}
	}
	if len(healthy) == 0 {
		return nil
	}

	threshold := lb.calculateRIFThreshold(healthy)

	var cold, hot []*Server
	for _, s := range healthy {
		if lb.rifFor(s) > threshold {
			hot = append(hot, s)
		} else {
			cold = append(cold, s)
		}
	}

	if len(cold) > 0 {
		return lb.selectLowestLatency(cold)
	}
	return lb.selectLowestRIF(hot)
}

func (lb *LoadBalancer) calculateRIFThreshold(servers []*Server) int32 {
	if len(servers) == 0 {
		return 0
	}
	values := make([]int32, len(servers))
	for i, s := range servers {
		values[i] = lb.rifFor(s)
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	idx := int(float64(len(values)-1) * lb.config.QRIF)
	if idx >= len(values) {
		idx = len(values) - 1
	}
	return values[idx]
}

func (lb *LoadBalancer) selectLowestLatency(servers []*Server) *Server {
	if len(servers) == 0 {
		return nil
	}
	best := servers[0]
	for _, s := range servers[1:] {
		if s.Latency < best.Latency {
			best = s
		}
	}
	return best
}

func (lb *LoadBalancer) selectLowestRIF(servers []*Server) *Server {
	if len(servers) == 0 {
		return nil
	}
	best := servers[0]
	bestRIF := lb.rifFor(best)
	for _, s := range servers[1:] {
		if r := lb.rifFor(s); r < bestRIF {
			bestRIF = r
			best = s
		}
	}
	return best
}

func (lb *LoadBalancer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	atomic.AddUint64(&lb.stats.TotalRequests, 1)

	server := lb.SelectServer()
	if server == nil {
		atomic.AddUint64(&lb.stats.FailedRequests, 1)
		http.Error(w, "No available servers", http.StatusServiceUnavailable)
		return
	}

	start := time.Now()
	lb.forwardRequest(server, w, r)
	duration := time.Since(start)

	algorithm := string(lb.config.Algorithm)
	lb.metrics.requestDuration.WithLabelValues(algorithm).Observe(duration.Seconds())
	atomic.AddUint64(&lb.stats.SuccessfulRequests, 1)
}

func (lb *LoadBalancer) forwardRequest(server *Server, w http.ResponseWriter, r *http.Request) {
	algorithm := string(lb.config.Algorithm)
	atomic.AddInt32(&server.RIF, 1)
	lb.metrics.activeRequests.WithLabelValues(algorithm).Inc()

	defer func() {
		atomic.AddInt32(&server.RIF, -1)
		lb.metrics.activeRequests.WithLabelValues(algorithm).Dec()
		currentRIF := atomic.LoadInt32(&server.RIF)
		lb.metrics.serverRIF.WithLabelValues(server.ID, algorithm).Set(float64(currentRIF))
	}()

	targetURL, _ := url.Parse("http://" + server.Address)
	proxy := httputil.NewSingleHostReverseProxy(targetURL)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		lb.logger.Error("Proxy error", slog.String("error", err.Error()))
		atomic.AddUint64(&lb.stats.FailedRequests, 1)
		http.Error(w, "Service unavailable", http.StatusServiceUnavailable)
	}
	proxy.ServeHTTP(w, r)
}
