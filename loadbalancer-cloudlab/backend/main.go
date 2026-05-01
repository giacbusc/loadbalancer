package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

// Global server-local RIF: the count of requests currently being served by
// THIS backend, summed across all clients. This is the "server-local RIF"
// signal the Prequal paper recommends.
var serverRIF int32

// cpuLoad simulates antagonist contention via an extra delay.
// Mutated at runtime via /admin/load?cpu=N (for the dynamic-antagonist experiment).
var cpuLoad int32

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	serverID := os.Getenv("SERVER_ID")
	if serverID == "" {
		serverID = "unknown"
	}
	if loadStr := os.Getenv("CPU_LOAD"); loadStr != "" {
		if v, err := strconv.Atoi(loadStr); err == nil {
			atomic.StoreInt32(&cpuLoad, int32(v))
		}
	}

	// Main work endpoint.
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&serverRIF, 1)
		defer atomic.AddInt32(&serverRIF, -1)

		start := time.Now()

		// Simulated CPU work: SHA256 hashing.
		work := 1000 + rand.Intn(500)
		for i := 0; i < work; i++ {
			h := sha256.Sum256([]byte(fmt.Sprintf("%d-%d", time.Now().UnixNano(), i)))
			_ = hex.EncodeToString(h[:])
		}

		// Simulated antagonist contention: extra sleep proportional to cpuLoad.
		load := atomic.LoadInt32(&cpuLoad)
		if load > 0 {
			baseDelay := 10 * time.Millisecond
			additional := time.Duration(float64(load)/100.0*30) * time.Millisecond
			variance := time.Duration(rand.Intn(5)) * time.Millisecond
			time.Sleep(baseDelay + additional + variance)
		}

		duration := time.Since(start)
		w.Header().Set("Content-Type", "text/html")
		w.Header().Set("X-Served-By", serverID)
		w.Header().Set("X-Server-RIF", strconv.Itoa(int(atomic.LoadInt32(&serverRIF))))
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "<html><body><h1>%s</h1><p>%v</p></body></html>", serverID, duration)
	})

	// Health/probe endpoint: returns RIF in header so the LB can read server-local RIF.
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		// IMPORTANT: do NOT add antagonist sleep here, otherwise probes are skewed.
		// The probe latency should reflect minimal pure round-trip + tiny processing.
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Server-RIF", strconv.Itoa(int(atomic.LoadInt32(&serverRIF))))
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"status":"healthy","server_id":"%s","rif":%d,"cpu_load":%d}`,
			serverID, atomic.LoadInt32(&serverRIF), atomic.LoadInt32(&cpuLoad))
	})

	// Admin endpoint to change antagonist load at runtime.
	// Usage: POST /admin/load?cpu=80
	http.HandleFunc("/admin/load", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("cpu")
		if q == "" {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprintf(w, "missing cpu parameter\n")
			return
		}
		v, err := strconv.Atoi(q)
		if err != nil || v < 0 || v > 200 {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprintf(w, "invalid cpu value\n")
			return
		}
		atomic.StoreInt32(&cpuLoad, int32(v))
		log.Printf("[%s] cpu_load updated to %d", serverID, v)
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "ok cpu_load=%d\n", v)
	})

	// Stats endpoint for debugging.
	http.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "server_id=%s rif=%d cpu_load=%d\n",
			serverID, atomic.LoadInt32(&serverRIF), atomic.LoadInt32(&cpuLoad))
	})

	log.Printf("Server %s starting on port %s (CPU load: %d%%)", serverID, port, atomic.LoadInt32(&cpuLoad))
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}
