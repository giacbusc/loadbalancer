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

	// currentRIFThreshold is recomputed periodically from the GLOBAL probe
	// pool (all server RIFs), and is the threshold used by HCL to classify
	// probes as hot or cold. This matches the paper's definition: "an
	// estimate of the distribution of RIF across replicas".
	currentRIFThreshold int32

	// probeIntervalNs is the current probing period in nanoseconds, mutable at
	// runtime via SetProbeInterval (used by the /admin/probe-interval endpoint
	// for the freshness sweep). The probing goroutine resets its ticker when
	// this changes.
	probeIntervalNs int64
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

// -----------------------------------------------------------------------------
// Probing
// -----------------------------------------------------------------------------

func (lb *LoadBalancer) StartProbing() {
	atomic.StoreInt64(&lb.probeIntervalNs, int64(lb.config.ProbeInterval))
	go func() {
		ticker := time.NewTicker(lb.config.ProbeInterval)
		defer ticker.Stop()
		cur := int64(lb.config.ProbeInterval)
		for range ticker.C {
			lb.probeAllServers()
			lb.recomputeGlobalThreshold()
			// Apply a runtime change to the probing period, if any.
			if n := atomic.LoadInt64(&lb.probeIntervalNs); n > 0 && n != cur {
				cur = n
				ticker.Reset(time.Duration(n))
			}
		}
	}()
}

// SetProbeInterval changes the probing period at runtime. The new value takes
// effect on the next tick (so a switch from a long to a short interval waits up
// to the old period once). Ignored if d <= 0.
func (lb *LoadBalancer) SetProbeInterval(d time.Duration) {
	if d > 0 {
		atomic.StoreInt64(&lb.probeIntervalNs, int64(d))
	}
}

// ProbeInterval returns the current (possibly runtime-overridden) probing period.
func (lb *LoadBalancer) ProbeInterval() time.Duration {
	if n := atomic.LoadInt64(&lb.probeIntervalNs); n > 0 {
		return time.Duration(n)
	}
	return lb.config.ProbeInterval
}

func (lb *LoadBalancer) probeAllServers() {
	lb.mutex.RLock()
	servers := make([]*Server, len(lb.servers))
	copy(servers, lb.servers)
	lb.mutex.RUnlock()

	var wg sync.WaitGroup
	for _, server := range servers {
		wg.Add(1)
		go func(srv *Server) {
			defer wg.Done()
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
	wg.Wait()
}

func (lb *LoadBalancer) probeServer(server *Server) *ProbeResult {
	ctx, cancel := context.WithTimeout(context.Background(), lb.config.ProbeTimeout)
	defer cancel()

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

	// --- Read server-reported signals from response headers --------------
	// Server-local RIF: how many requests this server is currently handling.
	var serverRIF int32
	if v := resp.Header.Get("X-Server-RIF"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			serverRIF = int32(n)
		}
	}

	// Server-reported recent-query latency (median of last N completed
	// queries on the backend). This is the latency signal Prequal §4
	// recommends: it reflects ACTUAL workload, not /health round-trip.
	// Unit: microseconds.
	var serverLatencyUs int64
	if v := resp.Header.Get("X-Server-Latency-P50"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			serverLatencyUs = n
		}
	}

	return &ProbeResult{
		Timestamp: time.Now(),
		RIF:       atomic.LoadInt32(&server.RIF),
		ServerRIF: serverRIF,
		Latency:   serverLatencyUs,
		IsHealthy: resp.StatusCode == http.StatusOK,
	}
}

// recomputeGlobalThreshold computes the QRIF-th quantile across ALL servers'
// recent RIF values, and stores it in lb.currentRIFThreshold. This is the
// "global" view that HCL uses to classify candidates as hot or cold,
// matching §4 of the paper.
func (lb *LoadBalancer) recomputeGlobalThreshold() {
	lb.mutex.RLock()
	defer lb.mutex.RUnlock()

	if len(lb.servers) == 0 {
		return
	}
	values := make([]int32, 0, len(lb.servers))
	for _, s := range lb.servers {
		if !s.IsHealthy {
			continue
		}
		values = append(values, lb.rifFor(s))
	}
	if len(values) == 0 {
		return
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	idx := int(float64(len(values)-1) * lb.config.QRIF)
	if idx >= len(values) {
		idx = len(values) - 1
	}
	atomic.StoreInt32(&lb.currentRIFThreshold, values[idx])
}

// -----------------------------------------------------------------------------
// Server registration
// -----------------------------------------------------------------------------

func (lb *LoadBalancer) AddServer(server *Server) {
	lb.mutex.Lock()
	defer lb.mutex.Unlock()
	lb.servers = append(lb.servers, server)
}

// -----------------------------------------------------------------------------
// Replica selection
// -----------------------------------------------------------------------------

func (lb *LoadBalancer) SetAlgorithm(algo Algorithm) {
	lb.mutex.Lock()
	lb.config.Algorithm = algo
	lb.mutex.Unlock()
	lb.logger.Info("algorithm switched", slog.String("to", string(algo)))
}

func (lb *LoadBalancer) SelectServer() *Server {
	lb.mutex.RLock()
	algo := lb.config.Algorithm
	lb.mutex.RUnlock()
	if algo == AlgorithmRoundRobin {
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
	healthy := make([]*Server, 0, len(lb.servers))
	for _, s := range lb.servers {
		if s.IsHealthy {
			healthy = append(healthy, s)
		}
	}
	if len(healthy) == 0 {
		return nil
	}
	index := atomic.AddUint32(&lb.rrIndex, 1)
	return healthy[int(index-1)%len(healthy)]
}

// sampleWithoutReplacement picks d distinct indices uniformly at random
// from [0, n), using a partial Fisher-Yates shuffle. O(d) time, O(n) space
// only when d is close to n; for d << n we use a small map of swapped indices.
//
// This matches the paper's specification: "Probe destinations are sampled
// uniformly at random WITHOUT replacement from the set of available replicas."
func sampleWithoutReplacement(n, d int) []int {
	if d > n {
		d = n
	}
	// Use a map to track which indices have been swapped, avoiding O(n)
	// allocation when d is small.
	swap := make(map[int]int, d)
	out := make([]int, d)
	for i := 0; i < d; i++ {
		j := i + rand.Intn(n-i) // pick from [i, n)
		// Conceptually: swap indices i and j in a virtual array, then
		// take the element at i. The map records non-default values.
		ji, ok := swap[j]
		if !ok {
			ji = j
		}
		ii, ok := swap[i]
		if !ok {
			ii = i
		}
		swap[j] = ii
		out[i] = ji
	}
	return out
}

func (lb *LoadBalancer) selectServerPrequal() *Server {
	lb.mutex.RLock()
	defer lb.mutex.RUnlock()

	if len(lb.servers) == 0 {
		return nil
	}

	healthy := make([]*Server, 0, len(lb.servers))
	for _, s := range lb.servers {
		if s.IsHealthy {
			healthy = append(healthy, s)
		}
	}
	if len(healthy) == 0 {
		return nil
	}

	// Sample d candidate INDICES without replacement from healthy pool only.
	n := len(healthy)
	d := lb.config.SelectionChoices
	if d > n {
		d = n
	}
	indices := sampleWithoutReplacement(n, d)
	candidates := make([]*Server, 0, d)
	for _, i := range indices {
		candidates = append(candidates, healthy[i])
	}

	return lb.selectBestCandidate(candidates)
}

func (lb *LoadBalancer) rifFor(s *Server) int32 {
	if lb.config.UseServerRIF {
		return atomic.LoadInt32(&s.ServerRIF)
	}
	return atomic.LoadInt32(&s.RIF)
}

// selectBestCandidate applies the Hot-Cold Lexicographic (HCL) rule:
//  1. Use the GLOBAL RIF threshold (computed in recomputeGlobalThreshold).
//  2. If at least one candidate is below threshold, return the cold candidate
//     with the lowest latency.
//  3. Otherwise, return the hot candidate with the lowest RIF.
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

	// Use the GLOBAL threshold, not a local-to-the-candidates one.
	threshold := atomic.LoadInt32(&lb.currentRIFThreshold)

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

// -----------------------------------------------------------------------------
// HTTP serving
// -----------------------------------------------------------------------------

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
