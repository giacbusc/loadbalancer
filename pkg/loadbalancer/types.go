package loadbalancer

import (
	"sync"
	"time"
)

type Server struct {
	ID        string
	Address   string
	RIF       int32 // client-local RIF (this LB's view)
	ServerRIF int32 // server-local RIF (reported by server in probe response header)
	Latency   int64
	IsHealthy bool
	LastProbe time.Time
}

type ProbeResult struct {
	Timestamp time.Time
	RIF       int32 // client-local RIF at probe time
	ServerRIF int32 // server-local RIF reported by the backend
	Latency   int64
	IsHealthy bool
}

type Algorithm string

const (
	AlgorithmPrequal    Algorithm = "prequal"
	AlgorithmRoundRobin Algorithm = "roundrobin"
)

type Config struct {
	ProbeInterval    time.Duration
	ProbeTimeout     time.Duration
	HealthCheckPath  string
	SelectionChoices int
	Algorithm        Algorithm
	QRIF             float64
	// UseServerRIF: if true, HCL ranks based on server-reported RIF
	// (read from X-Server-RIF response header); if false, uses client-local RIF.
	UseServerRIF bool
}

type Stats struct {
	TotalRequests      uint64
	SuccessfulRequests uint64
	FailedRequests     uint64
	AverageLatency     float64
	mutex              sync.RWMutex
}
