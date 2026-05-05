package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// -----------------------------------------------------------------------------
// Global state
// -----------------------------------------------------------------------------

// serverRIF: total number of requests this backend is currently processing.
// Atomically updated. This is the "server-local RIF" signal.
var serverRIF int32

// cpuLoad: antagonist intensity, 0..200. Mutated at runtime via /admin/load.
//
//	0   = no antagonist
//	60  = moderate contention
//	100 = a full CPU core consumed by the antagonist
var cpuLoad int32

// -----------------------------------------------------------------------------
// CPU burner (real antagonist, not time.Sleep)
// -----------------------------------------------------------------------------

// The CPU burner is a goroutine pool that spins doing useless arithmetic to
// consume CPU cycles. It dynamically scales to match the current cpuLoad value.
//
// Compared to time.Sleep, this approach actually creates measurable CPU
// contention: it competes with the request-serving goroutines for the same
// physical cores. CPU monitoring tools will correctly show high CPU usage,
// and request-handling goroutines will be slower because of context-switching
// and reduced CPU availability.

var (
	burnerStop      []chan struct{}
	burnerStopMutex sync.Mutex
)

// startCPUBurners launches `n` goroutines that spin until told to stop.
// Each goroutine pegs roughly one logical CPU.
func startCPUBurners(n int) {
	burnerStopMutex.Lock()
	defer burnerStopMutex.Unlock()

	for i := 0; i < n; i++ {
		stop := make(chan struct{})
		burnerStop = append(burnerStop, stop)
		go func() {
			x := uint64(1)
			for {
				select {
				case <-stop:
					return
				default:
					// Tight loop with non-trivial arithmetic the compiler
					// cannot optimize away. Periodically yield to let the
					// scheduler interleave other goroutines.
					for i := 0; i < 1_000_000; i++ {
						x = x*1103515245 + 12345
					}
					_ = x
					runtime.Gosched()
				}
			}
		}()
	}
}

// stopAllBurners signals every running burner to exit.
func stopAllBurners() {
	burnerStopMutex.Lock()
	defer burnerStopMutex.Unlock()
	for _, ch := range burnerStop {
		close(ch)
	}
	burnerStop = nil
}

// applyCPULoad reconciles the number of running burners with the requested
// load level. We map cpuLoad (0..200) to a number of CPU-bound goroutines:
//
//	load=0   -> 0 burners (clean)
//	load=50  -> 1 burner (~half a core average across the system)
//	load=100 -> 2 burners
//	load=200 -> 4 burners
func applyCPULoad(load int32) {
	stopAllBurners()
	if load <= 0 {
		return
	}
	// Roughly: 1 burner per 50 units of load.
	n := int(load) / 50
	if n < 1 && load > 0 {
		n = 1
	}
	startCPUBurners(n)
}

// -----------------------------------------------------------------------------
// Sliding window of recent query latencies
// -----------------------------------------------------------------------------

// latencyWindow holds the last `capacity` query latencies (in milliseconds).
// We expose the median of this window as the server's "current latency"
// signal, which the LB reads from a probe response header.
//
// This is the approach the Prequal paper recommends in §4: "When a query
// finishes, we record its latency... we consult a set of recent latency
// values... and report the median."

type latencyWindow struct {
	mu       sync.Mutex
	values   []int64
	capacity int
	cursor   int
	filled   bool
}

func newLatencyWindow(capacity int) *latencyWindow {
	return &latencyWindow{
		values:   make([]int64, capacity),
		capacity: capacity,
	}
}

func (w *latencyWindow) record(latencyMs int64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.values[w.cursor] = latencyMs
	w.cursor = (w.cursor + 1) % w.capacity
	if w.cursor == 0 {
		w.filled = true
	}
}

// median returns the p50 of the values currently in the window.
// Returns 0 if the window is still empty.
func (w *latencyWindow) median() int64 {
	w.mu.Lock()
	defer w.mu.Unlock()

	end := w.cursor
	if w.filled {
		end = w.capacity
	}
	if end == 0 {
		return 0
	}
	tmp := make([]int64, end)
	copy(tmp, w.values[:end])
	sort.Slice(tmp, func(i, j int) bool { return tmp[i] < tmp[j] })
	return tmp[end/2]
}

var window = newLatencyWindow(128)

// -----------------------------------------------------------------------------
// HTTP handlers
// -----------------------------------------------------------------------------

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
			applyCPULoad(int32(v))
		}
	}

	// --- /  --- main work endpoint ---------------------------------------
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&serverRIF, 1)
		defer atomic.AddInt32(&serverRIF, -1)

		start := time.Now()

		// CPU work: SHA256 hashing, with variance roughly equal to the mean
		// (matching the paper's workload distribution).
		mean := 1500
		stddev := 1500
		work := mean + int(rand.NormFloat64()*float64(stddev))
		if work < 100 {
			work = 100
		}
		for i := 0; i < work; i++ {
			h := sha256.Sum256([]byte(fmt.Sprintf("%d-%d", time.Now().UnixNano(), i)))
			_ = hex.EncodeToString(h[:])
		}

		duration := time.Since(start)
		window.record(duration.Milliseconds())

		w.Header().Set("Content-Type", "text/html")
		w.Header().Set("X-Served-By", serverID)
		w.Header().Set("X-Server-RIF", strconv.Itoa(int(atomic.LoadInt32(&serverRIF))))
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "<html><body><h1>%s</h1><p>%v</p></body></html>", serverID, duration)
	})

	// --- /health  --- probe endpoint -------------------------------------
	// Exposes both server-local RIF and the recent-query median latency, so
	// the LB can read accurate signals without measuring the probe RTT.
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Server-RIF", strconv.Itoa(int(atomic.LoadInt32(&serverRIF))))
		w.Header().Set("X-Server-Latency-P50", strconv.FormatInt(window.median(), 10))
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"status":"healthy","server_id":"%s","rif":%d,"cpu_load":%d,"p50_ms":%d}`,
			serverID,
			atomic.LoadInt32(&serverRIF),
			atomic.LoadInt32(&cpuLoad),
			window.median(),
		)
	})

	// --- /admin/load  --- mutate antagonist at runtime --------------------
	http.HandleFunc("/admin/load", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("cpu")
		if q == "" {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprintf(w, "missing cpu parameter\n")
			return
		}
		v, err := strconv.Atoi(q)
		if err != nil || v < 0 || v > 400 {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprintf(w, "invalid cpu value (0..400)\n")
			return
		}
		atomic.StoreInt32(&cpuLoad, int32(v))
		applyCPULoad(int32(v))
		log.Printf("[%s] cpu_load updated to %d (burners=%d)", serverID, v, v/50)
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "ok cpu_load=%d\n", v)
	})

	// --- /stats  --- human-readable debug --------------------------------
	http.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "server_id=%s rif=%d cpu_load=%d p50_ms=%d\n",
			serverID,
			atomic.LoadInt32(&serverRIF),
			atomic.LoadInt32(&cpuLoad),
			window.median(),
		)
	})

	log.Printf("Server %s starting on :%s (CPU load: %d%%, GOMAXPROCS=%d)",
		serverID, port, atomic.LoadInt32(&cpuLoad), runtime.GOMAXPROCS(0))
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}
