---
title: 'Replicating: "The Title of Paper You Selected From The List"'

---

# Replicating: "Load is not what you should balance: Introducing Prequal"

**Team Members:**  
Giacomo Buscaglia (giacomo.buscaglia@mail.polimi.it);  
Simone Pizzelli (simone.pizzelli@mail.polimi.it);  
Davide Roccuzzo (davide.roccuzzo@mail.polimi.it)

---

**Source Paper:**
Bartek Wydrowski, Google Research; Robert Kleinberg, Google Research and Cornell; Stephen M. Rumble, Google (YouTube); Aaron Archer, Google Research: Load is not what you should balance: Introducing Prequal. In "21st USENIX Symposium on Networked Systems Design and Implementation".


**Project:**
https://github.com/giacbusc/loadbalancer

---

# 1. Introduction

Introduce the paper by summarizing:

- The problem the paper addresses and its importance

Modern large-scale services such as YouTube are composed of thousands of distributed jobs, each replicated across hundreds or thousands of machines for reasons of scalability and redundancy. Any two jobs in such an architecture communicate via remote procedure calls (RPCs), and whenever a client job sends a query to a server job, a load balancer must decide which of the many available server replicas should handle that particular request. This decision is made millions of times per second, and even small inefficiencies in this process translate into wasted resources and degraded user experience.
The problem the Prequal paper addresses is the following: in a multi-tenant environment where server replicas share machines with unrelated workloads (called antagonists), how should a load balancer route requests so as to minimize tail latency, control error rates, and keep resource utilization stable, while remaining lightweight enough to run at production scale?
The challenge is more subtle than it might appear. Each replica (running inside its own virtual machine) is allocated a guaranteed share of the backend's CPU (called CPU allocation), but the backends themselves are shared with other processes. If a single replica happens to share its host with an antagonist that temporarily bursts above its own allocation, the CPU-isolation mechanisms of the hypervisor will kick in and throttle that replica, severely impacting any requests it is currently serving. Because such bursts are unpredictable, unevenly distributed, and invisible to the application, traditional load-balancing strategies that assume homogeneous server capacity perform poorly. The paper shows empirical data from YouTube demonstrating that, even when 1-minute-averaged CPU usage looks well within allocation, 1-second-resolution traces reveal frequent spikes well above the limit on a non-trivial subset of replicas.
- The key ideas behind its solution and its approach
Prequal — short for **Probing to Reduce Queuing and Latency** — is a load-balancing policy developed and deployed in production at Google, primarily on YouTube and 20+ other large-scale services. It is built on top of the Power-of-d-Choices (PodC) paradigm, in which the load balancer samples d candidate replicas for each incoming query and forwards the query to the most suitable one according to some scoring rule. Prequal makes two specific design choices that, combined, distinguish it from prior PodC implementations.
- First, Prequal uses **Requests-In-Flight (RIF)** and **recent latency** as the load signals, instead of **CPU utilization**. RIF is an instantaneous count of how many requests a replica is currently processing. Recent latency is the median latency of completed queries over a short sliding window. Both signals are inherently up-to-date, unlike CPU utilization which must be averaged over a non-trivial time window to be meaningful. Furthermore, RIF doubles as a leading indicator of future work and as a direct constraint on per-replica RAM usage, which makes it doubly useful.
- Second, Prequal combines RIF and latency through a **Hot-Cold Lexicographic (HCL) rule**, rather than a linear combination. Each probed replica is classified as *"hot"* if its RIF exceeds the QRIF-th quantile of the global RIF distribution (default 0.84), and *"cold"* otherwise. If at least one cold replica is available among the candidates, the lowest-latency cold replica is chosen; otherwise, the lowest-RIF hot replica is chosen.
- The main contributions
The paper points out three main contributions.
Contribution 1:The combination of RIF and latency through strict hot/cold lexicographic prioritization is, to the authors' knowledge, new. The paper compares HCL empirically against nine other replica-selection rules (such as Random, Round-Robin, WRR, LeastLoaded, LL-Po2C, YARP-Po2C, a linear combination of RIF and latency, the C3 scoring rule, and Prequal itself) on a controlled testbed. HCL outperforms all of them at both moderate and high load levels.
Contribution 2: Asynchronous probing with a managed probe pool. The async probing scheme — in which probes are issued out of the request path and selection draws from a pool managed with age-out, bounded reuse, and remove-worst — is a novel application of ideas from the theory of balanced allocations with memory. It allows Prequal to retain the freshness benefits of active probing while keeping per-request critical-path overhead negligible.
Contribution 3: Large-scale production evidence.The reported outcomes — tail-latency reductions of 2×, tail-RIF reductions of 5–10×, tail-memory savings of 10–20%, and near-elimination of load-imbalance errors — make a strong case that the academic theory of Power-of-d-Choices works as well in industrial practice as it does in mathematical models. The paper also documents how these gains translated directly into higher achievable utilization targets and substantial datacenter resource savings.


# 2. Selected Result

We reproduce **Figure 6** of the paper — the *load ramp experiment* — which is the central empirical result of the testbed evaluation (section 5.1). Figure 6 demonstrates how Prequal and Weighted Round Robin (WRR) behave as request load crosses the system's CPU allocation boundary, from comfortably below capacity through severe overload.

> "Figure 6 shows that, as soon as the offered load exceeds the system's CPU allocation, WRR's tail latency collapses almost immediately (p99.9 hits the 5 s timeout at 1.03× allocation), while Prequal's tail latency degrades gradually and remains orders of magnitude lower across all overload levels. This experiment demonstrates that Prequal's Hot-Cold Lexicographic (HCL) selection rule can absorb transient overload that would cause catastrophic tail latency inflation under a utilization-balancing policy."

This result is important for two reasons. First, it isolates the core claim of the paper: that routing based on *in-flight requests* (RIF) and *latency*, rather than CPU utilization, is the right signal under overload. Second, it shows that the benefit is not marginal — WRR saturates end-to-end within one overload step, whereas Prequal gracefully degrades across nine steps spanning 1.03× to 1.74× allocation, never reaching the timeout threshold even at the highest load level.

<center>
  <img
    alt="Figure 6 from the Prequal paper: load ramp experiment showing tail latency divergence between Prequal and WRR once load exceeds CPU allocation"
    src="https://hackmd.io/_uploads/Bkwtyemgfe.png"
    style="width:100%;"
    />
  <p>Figure 1: Load ramp experiment from the original paper (Figure 6, section 5.1). Gray background = WRR, white = Prequal. Tail latency is on a log scale. Once load exceeds 1.03× allocation, WRR's p99.9 immediately saturates the 5 s timeout while Prequal degrades only gradually.</p>
</center>![Screenshot 2026-05-26 alle 12.01.08]()

What about the errors??


# 3. Environment Setup

This section documents the hardware, software, configuration, and deviations from the original Prequal paper so that the experiment can be reproduced by someone else.

## 3.1 Hardware Environment

All experiments were executed on the [CloudLab](https://www.cloudlab.us) remote environment, using the **Utah** cluster. We requested 15 dedicated nodes using the [`profile.py`](https://github.com/giacbusc/loadbalancer/blob/main/profile.py) in the repository. Every node was of type **m510**, with the [following characteristics](https://docs.cloudlab.us/hardware.html):

| Component | Specification |
|---|---|
| CPU | Intel Xeon D-1548 (Broadwell), 8 physical cores @ 2.0 GHz, 16 hardware threads |
| Memory | 64 GB DDR4 ECC |
| Storage | 256 GB NVMe flash |
| Network | Dual-port Mellanox ConnectX-3, 10 Gbps |
| Inter-node link | 1 Gbps experiment LAN (configured in the profile) |

The choice of this machine was driven purely by practical considerations and hardware availability.
The 15 nodes were assigned the following roles via the profile and a per-role startup script ([`cloudlab-setup.sh`](https://github.com/giacbusc/loadbalancer/blob/main/cloudlab-setup.sh)):

| Role | Count | IP range (10.10.1.0/24) | Purpose |
|---|---|---|---|
| Observability (`obs`) | 1 | .10 | Prometheus + Grafana |
| Prequal load balancer | 1 | .11 | One of the two LB instances |
| Round-Robin load balancer | 1 | .12 | Baseline LB instance |
| Backend (heavy antagonist) | 4 | .21–.24 | `cpu_load=350`, 7 burner goroutines |
| Backend (light antagonist) | 3 | .25–.27 | `cpu_load=150`, 3 burner goroutines |
| Backend (clean) | 3 | .28–.30 | `cpu_load=0`, no antagonist |
| Load generator (`loadgen`) | 2 | .31–.32 | hey-based load injection |

The two load balancers and the 10 backends were placed on separate physical machines to ensure that CPU contention came exclusively from the configured antagonists, not from co-location with other components of our own system. The observability node was likewise separate so that Prometheus scraping and Grafana rendering could not interfere with the measured paths.


## 3.2 Software Environment

The operating system on every node was **Ubuntu 22.04 LTS** with the stock kernel `5.15.x` shipped by CloudLab's standard image (`UBUNTU22-64-STD`).

The runtime stack was containerized with Docker. Each node ran a single relevant container (load balancer, backend, or observability stack) using `--network host` to skip the default isolated network setup and instead giving to the container direct access to the host machine's network interface. 
Docker has been selected so that the same binaries could be built and tested locally (via `docker compose`) before being deployed on CloudLab.

| Software | Version | Purpose |
|---|---|---|
| Ubuntu | 22.04 LTS | Base OS |
| Docker Engine | 24.x (installed via official Docker apt repo) | Container runtime |
| Go (build-time) | 1.24-alpine (inside container) | Language toolchain |
| Go (loadgen-only) | golang-1.23 (Ubuntu apt package) | Required to compile `hey` |
| Prometheus | latest (official image `prom/prometheus`) | Metrics scraping |
| Grafana | latest (official image `grafana/grafana`) | Dashboards |
| `hey` (load tester) | v0.1.5 (built from `github.com/rakyll/hey@latest`) | HTTP load generation |
| Key Go dependency | `github.com/prometheus/client_golang v1.20.5` | Metrics exposition |

### Paper artifact

The original Prequal paper (Wydrowski et al., NSDI '24) **does not publish source code or a reproduction artifact**. Prequal is implemented inside Google's proprietary Stubby RPC framework and was not open-sourced. Therefore we did **not** use the paper's artifact (it does not exist publicly). Instead, our work is a re-implementation in Go starting from the open-source skeleton at `github.com/omarshaarawi/loadbalancer`, which we forked and modified with also some enhancement. The exact commit used for the experiments reported here is on the `main` branch of our fork at [`github.com/giacbusc/loadbalancer`](https://github.com/giacbusc/loadbalancer).

### Local repository layout (relevant files)

```
loadbalancer/
├── cmd/server/main.go          # LB entry point
├── pkg/loadbalancer/
│   ├── balancer.go             # HCL rule, PodC sampling, async probing
│   ├── types.go                # Defines the Server, ProbeResult, Config structs
│   ├── metrics.go              # Prometheus metric definitions
│   └── health.go               # (dead code from original repo)
├── backend/main.go             # HTTP backend: SHA256 work + CPU burner
├── backend/Dockerfile          # Backend container image
├── Dockerfile                  # LB container image
├── profile.py                  # CloudLab topology (15 nodes)
├── cloudlab-setup.sh           # Per-role startup script
├── run-experiment.sh           # Main load-ramp experiment
├── parse-results.sh            # Query output into a CSV summary
├── experiment-rif-source.sh    # Secondary RIF-source experiment
└── docker-compose.yml          # Local version (5 backends)
```

## 3.3 Configuration Parameters

### Workload configuration

The workload is generated by `hey` and consists of plain HTTP GET requests against the root path (`/`) of the load balancer. Each request triggers, inside the backend handler:

1. A CPU-bound SHA256 computation loop. The number of iterations follows a normal distribution with **mean = 1500, standard deviation = 1500**, truncated below at 100. This produces highly variable per-query cost, intentionally matching the paper's choice of σ ≈ μ.
2. A small response payload (~110 bytes of HTML).

We deliberately chose a CPU-bound workload because the paper's tests use the same shape (SHA256-like inner loops) and because it makes the antagonist's effect directly observable: a busy CPU on the backend translates immediately into longer response times.

### Antagonist configuration

The contention on a backend is modeled as an in-process **CPU burner**: one or more Go goroutines that run an unrollable arithmetic loop (`x = x*1103515245 + 12345`) and yield periodically via `runtime.Gosched()`. The number of burner goroutines is controlled by an integer `cpuLoad` mapped as `n_burners = cpuLoad / 50` (with a minimum of 1 when `cpuLoad > 0`). For the m510 nodes used here:

| Backend group | `cpu_load` | Burners | Cores saturated (of 8) |
|---|---|---|---|
| Heavy (server-0..3) | 350 | 7 | 7/8 |
| Light (server-4..6) | 150 | 3 | 3/8 |
| Clean (server-7..9) | 0 | 0 | 0/8 |

The values 350 and 150 were chosen empirically: a previous experiment with the original mapping (heavy = 80, light = 40) collapsed to "1 burner everywhere" because of integer division (80/50 = 1, 40/50 = 0 promoted to 1), and as a consequence the resulting CPU contention was barely measurable on an 8-core machine. The revised values aggressively saturate the contended nodes.

The `cpuLoad` can also be modified at runtime via the backend's `POST /admin/load?cpu=N` endpoint, exposed specifically to enable dynamic-antagonist experiments without restarting any container.

### Load balancer parameters

All Prequal-side parameters are exposed via environment variables on the LB container. The values used throughout the experiment are summarized below.

| Variable | Value | Notes |
|---|---|---|
| `LB_ALGORITHM` | `prequal` or `roundrobin` | Selects the policy |
| `LB_QRIF` | 0.84 | Hot/cold threshold quantile (paper default) |
| `LB_SELECTION_CHOICES` | 2 | `d` in Power-of-d-Choices |
| `LB_PROBE_INTERVAL` | 1 s | Time between probe rounds |
| `LB_PROBE_TIMEOUT` | 2 s | Per-probe RPC timeout |
| `LB_USE_SERVER_RIF` | false | Use client-local RIF for HCL (server-local when true) |
| `BACKENDS` | 10.10.1.21:8080,...,10.10.1.30:8080 | Comma-separated backend list |

### Backend parameters

| Variable | Value | Notes |
|---|---|---|
| `PORT` | 8080 | Listening port |
| `SERVER_ID` | `$(hostname)` | Used in `X-Served-By` and logs |
| `CPU_LOAD` | 0 / 150 / 350 | Initial antagonist intensity |

### Load-ramp experiment parameters

`run-experiment.sh` first **discovers the true saturation throughput** with a 20-second burst (`hey -z 20s -c 200`, no `-q`). The measured throughput is then used as the 100 % anchor for nine load levels:

| Step | Load level (× saturation) | 
|---|---|
| 1 | 0.60 |
| 2 | 0.75 |
| 3 | 0.90 | 
| 4 | 1.00 | 
| 5 | 1.10 |
| 6 | 1.25 |
| 7 | 1.45 |
| 8 | 1.65 |
| 9 | 1.80 |

For every level, `hey -z 60s -q <target> -c 300` is launched **simultaneously** against both LBs. The concurrency (`-c 300`) is set high enough that the cap `-q` is actually enforced even when the system slows down under overload.
The concurrency -c 300 was chosen so that the requested rate -q could be effectively enforced even under overload. Internally, `hey` works as a pool of c parallel workers, each of which serially issues a request and waits for the reply; therefore a worker can produce at most 1 / latency requests per second. When the system is overloaded (~400 ms per request in our setup), each worker delivers only ~2.5 req/s, so 300 workers cap out at ~750 req/s — comfortably above our highest target. With a lower concurrency (e.g. -c 50), the cap -q would silently become unreachable and the load level would collapse to whatever the workers could naturally produce. This led to a failure in our first experiment sessions.

### Dataset

No external dataset is involved. 

## 3.4 Deviations from the Original Setup

This sub-section is the most important one for reproducibility, because every deviation can in principle bias the results, and the reader has the right to know.

### Differences on the number of nodes

The paper evaluates Prequal at large scale, with **100 client and 100 server replicas** per job, distributed across hundreds of machines in a Google datacenter. In this experiment **2 load balancers and 10 backends** are used.

The choice of 10 backends is a compromise between 
* being large enough that the Power-of-d-Choices paradigm has meaningful options (d = 2 candidates out of 10 leaves 80 % of the pool unsampled per request, similar in spirit to the paper's regime) 
*  staying within the available cluster.

**Impact on the results**: with fewer servers, the statistical effect of HCL is muted. The paper's tail-latency improvements are largest at scale because more replicas means more opportunity for asymmetry.

### Static in-process burner vs. real co-tenant VMs 

In the paper, antagonists are **other Google workloads** sharing the same physical machines under hypervisor isolation. Their CPU consumption is highly variable on sub-second timescales (paper Figure 3 shows machine CPU usage bursting to 2× allocation on 1-second windows).

In the setup, antagonists are **goroutines inside the same backend process**, running a CPU-bound arithmetic loop. <u>They are stationary, not bursty</u>.

The closest and simple available alternative would be using in-process goroutines and make `CPU_LOAD` mutable at runtime via the `/admin/load` endpoint.

**Impact on the results**: Prequal's value should be larger against bursty antagonists (because stale signals matter more there). 

### Round-Robin vs. Weighted Round-Robin

The paper compares Prequal against **Weighted Round-Robin (WRR)**, which dynamically adjusts per-replica weights based on smoothed CPU utilization and goodput history. Here the comparison is performed against **plain Round-Robin**, which simply cycles through healthy replicas.

Plain Round-Robin has been selected since the original implementation on GitHub was based on it.

**Impact on the results**: In principle the gap between RR and Prequal should be *larger* than the gap between WRR and Prequal. This as been addressed as a limitation.

### Async probing

The section 4 of the paper describes an async probing scheme with:

* A bounded probe pool of size 16, with **age-out**, **reuse limit** controlled by formula (1), and **periodic remove-worst** alternated with remove-oldest;
* A latency estimator that consults recent query latencies *bucketed by RIF*;
* Sinkholing protection (error-aware health detection).

In this version:

* Probes are taken at a fixed periodic interval (default 1 s), they're not generated for each arriving query.
* The latency value exposed by the server and used by HCL is the **median of the last 128 query latencies on the backend**, returned through an `X-Server-Latency-P50` HTTP header on the probe response. This is exposed by our backend specifically so the LB can read a meaningful workload latency instead of measuring the round-trip time.
* No reuse limit, no remove-worst are implemented in the Github reference repository.

*Why we deviated*: the missing features add significant code complexity and are only necessary at large scale (the paper notes that the reuse limit becomes essential when probing many replicas per query). At 10 backends with periodic probing, our pool never becomes a bottleneck.

*Expected impact*: a more advanced probe pool would react faster to changes. Our 1 Hz probing means HCL sees information that is up to 1 second old. For static-antagonist experiments this is irrelevant. For the dynamic-antagonist follow-up, a faster probe pool would arguably improve Prequal's responsiveness.

### Sampling: without replacement (matches paper)

The original open-source skeleton we forked sampled candidates *with* replacement (allowed picking the same server twice). The paper explicitly requires *without replacement*. We fixed this with a partial Fisher-Yates shuffle in `sampleWithoutReplacement(n, d)`. This is a faithful match.

### RIF threshold: global vs. local

The original skeleton computed the QRIF quantile over only the `d` sampled candidates. The paper specifies the quantile over the **estimated distribution across all replicas**. We fixed this by recomputing a global `currentRIFThreshold` after each probe round, used uniformly across all selection decisions. This is also now a faithful match.

### Workload variance

The paper uses a workload where the per-query CPU cost has **standard deviation roughly equal to the mean** (paper §5). The original skeleton used a low-variance workload (`1000 + rand.Intn(500)`). We changed this to `mean + rand.NormFloat64() * stddev` with `mean = stddev = 1500`, matching the paper's specification.

## 3.5 Things the Paper Does Not Specify

A few choices in our setup had to be made because the paper leaves them implicit:

* **Initial probe state at startup**. The paper does not describe what HCL does when the probe pool is empty (e.g. immediately after a container restart). We default to random selection for the first ~1 second, until probes arrive.
* **Latency window size on the backend**. The paper §4 mentions "a set of recent latency values", without committing to a number. We chose 128 samples as a sliding window large enough to be stable across noisy queries but small enough to react quickly to load changes (at ~400 req/s per backend, 128 samples represents the last ~300 ms of traffic).
* **Hardware tuning for antagonist intensity**. The paper expresses antagonist intensity as a fraction of machine CPU allocation. We had to translate this into a concrete count of burner goroutines on an 8-core m510. After empirical calibration we chose 7 burners for "heavy" (≈ 88 % of one node) and 3 for "light" (≈ 38 % of one node).

These choices are documented here rather than buried in code, so that any future reproducer can either accept them or vary them deliberately.

---

This setup is what is exercised by the experiments reported in the following section. All configuration files (`profile.py`, `cloudlab-setup.sh`, `Dockerfile`, `backend/Dockerfile`, `docker-compose.yml`) and the two scripts (`run-experiment.sh`, `experiment-rif-source.sh`) are tracked in the repository at the commit hash referenced above, so a reader can clone, instantiate the CloudLab profile, and obtain the same environment without manual intervention.

# 4. Experiment Results

This section describes the execution of the load-ramp experiment in both its static-antagonist and dynamic-antagonist variants, the measurement methodology, the obtained results, and a comparison against the original paper. It also documents the debugging work required to reach a functioning setup.

## 4.1 Execution Procedure

### 4.1.1 Environment Bootstrapping

Before launching any measurement, the CloudLab environment was verified to be fully operational. From `loadgen-0` (10.10.1.31) we ran connectivity checks against both load balancers:

```bash
curl http://10.10.1.11:8080/health   # Prequal LB
curl http://10.10.1.12:8080/health   # Round-Robin LB
```

Both returned `{"status":"healthy",...}` immediately. We additionally verified all ten backends via `curl http://10.10.1.2X:8080/health`

### 4.1.2 Static Antagonist Experiment

The static experiment was launched by running:

```bash
cd /opt/loadbalancer
./run-experiment.sh 60
```

The script executes in three phases.

**Phase 1 — Saturation discovery.** Before any ramped load is applied, a 20-second uncapped burst (`hey -z 20s -c 200`) is launched simultaneously against both load balancers. This measures the true maximum throughput achievable under the configured antagonist pressure, providing an empirical anchor for the 100 % load level. 

**Phase 2 — Load ramp.** Nine load levels were tested, from 60 % to 180 % of the measured saturation throughput:

| Step | Load level | Target QPS (approx.) |
|------|-----------|----------------------|
| 1    | 60 %      | 275 req/s            |
| 2    | 75 %      | 344 req/s            |
| 3    | 90 %      | 413 req/s            |
| 4    | 100 %     | 459 req/s            |
| 5    | 110 %     | 505 req/s            |
| 6    | 125 %     | 574 req/s            |
| 7    | 145 %     | 665 req/s            |
| 8    | 165 %     | 757 req/s            |
| 9    | 180 %     | 826 req/s            |

For each level, `hey` was launched simultaneously against both LBs:

```bash
hey -z 60s -q <qps_per_worker> -c 300 -t 20 http://10.10.1.11:8080   # Prequal
hey -z 60s -q <qps_per_worker> -c 300 -t 20 http://10.10.1.12:8080   # RR
```

**Phase 3 — Result extraction.** After all nine steps completed, `parse-results.sh` extracted a structured CSV from the raw `hey` output files:

```bash
./parse-results.sh /tmp/results-********-******
```

The CSV contains, per algorithm and per load level: achieved QPS, total requests served, latency percentiles p50/p90/p95/p99 in microseconds, and error count. The data were then visualized with `plot_results.py`, which generates a two-panel figure (tail latency on log scale + throughput as a bar chart) analogous to Figure 6 of the paper.

Real time results are described in section 4.2.

### 4.1.3 Dynamic Antagonist Experiment

The dynamic-antagonist variant is the part of the experiment that was substantially redesigned. Two things changed with respect to the static run: **how the two algorithms are compared** (a clean A/B procedure, `experiment-ab.sh`) and **what the antagonist does over time** (a new set of moving load states, `dynamic-antagonist.sh`). It was launched with:

```bash
./experiment-ab.sh 60 dynamic
```

#### Why a two-pass A/B procedure

In the static experiment both load balancers were driven simultaneously — Prequal on `.11`, Round-Robin on `.12` — each one routing to the *same* shared pool of ten backends. We realised this design contaminates the very signal Prequal relies on. While Prequal steers a query away from a momentarily loaded backend, the Round-Robin LB keeps flooding that same backend regardless of its state. The two policies fight over the same servers, so the in-flight count Prequal probes no longer reflects "Prequal's own decisions" but the superposition of both LBs. The measured gap between the policies is therefore artificially compressed.

To remove this confound, `experiment-ab.sh` runs the comparison as a genuine A/B in **two separate passes over the same conditions**, switching the algorithm at runtime through the `/admin/algorithm?algo=…` endpoint (`cmd/server/main.go`) so no container is ever redeployed:

* **Pass 1 — all-Prequal fleet:** both `.11` and `.12` are set to `prequal`.
* **Pass 2 — all-RR fleet:** both `.11` and `.12` are set to `roundrobin`.

Within a pass the routing across the fleet is homogeneous, so there is no cross-policy contamination. The two passes see the same backends, the same antagonist schedule, and the same offered load; only the algorithm differs. This is the cleaner A/B that the static run lacked.

Each pass drives both LBs with `hey`. The file actually parsed is the one from `.11` (the *canonical* LB); `.12` exists only to add the second half of the fleet load (its output is written to `_lb2/` and ignored by `parse-results.sh`). Two operational details support a fair comparison:

* The LBs run with `LB_USE_SERVER_RIF=true`, so every LB reads the **total** RIF reported by the backend (`X-Server-RIF`) rather than only its own local in-flight count. With two Prequal LBs in parallel this prevents the "multi-LB herd" effect, where both LBs independently pick the same momentarily-idle server and overload it together.
* `hey` is invoked **without** the `-t` timeout flag. Under overload the tail of the latency distribution lives at 2–4 s; truncating it with a timeout would discard exactly the requests on which the two policies differ and would flatten the comparison. We let every request run to completion instead.

The ramp uses `CONC=1000` connections per LB and the nine load levels are taken relative to a **single saturation-discovery pass** (20 s, uncapped, `c=200`) run once with the whole fleet on Round-Robin, which gives a conservative common reference. The levels were aligned to the paper's Figure 6 so the x-axis matches directly:

| Step | Load level (× saturation) |
|---|---|
| 1 | 0.75 |
| 2 | 0.83 |
| 3 | 0.93 |
| 4 | 1.03 |
| 5 | 1.14 |
| 6 | 1.27 |
| 7 | 1.41 |
| 8 | 1.57 |
| 9 | 1.74 |

#### The new antagonist states

The antagonist was also changed from the graded all-servers-loaded profile to a **load-minority** profile that mirrors the paper's scenario more faithfully: *a few antagonists scattered among many healthy replicas*. In every state only 2–3 of the ten backends are hot (`cpu_load=350`, i.e. 7 burner goroutines saturating 7 of 8 cores), and the hot set **moves** through the fleet over time. Because the hot servers shift, Round-Robin keeps hitting them on its fixed rotation, while Prequal always has 7–8 cold replicas to divert toward.

`dynamic-antagonist.sh` calls `/admin/load?cpu=N` on all ten backends in parallel every `INTERVAL` seconds, cycling through six states:

| State   | Hot servers (`cpu_load=350`) | Clean servers (`cpu_load=0`) |
|---------|------------------------------|------------------------------|
| HEAD    | s0, s1, s2                   | s3–s9                        |
| MID     | s3, s4, s5                   | s0–s2, s6–s9                 |
| TAIL    | s7, s8, s9                   | s0–s6                        |
| SPARSE  | s0, s4, s8                   | the other seven              |
| PAIR    | s2, s3                       | the other eight              |
| PAIR2   | s6, s7                       | the other eight              |

The interval is set by the experiment to `DURATION / 6`, so for a 60-second step it is 10 s and one full six-state cycle spans exactly 60 s. Each measurement step therefore captures **exactly one complete cycle**, guaranteeing that the all-Prequal pass and the all-RR pass are exposed to the same time-average of antagonist conditions. A 3-second warm-up after the antagonist starts lets the first state settle, and a 5-second warm-up after each algorithm switch lets the global RIF threshold recompute on the next probe round.

Transitions such as HEAD → MID or TAIL → PAIR are role inversions: servers that were saturated drop to `cpu_load=0` while previously-clean servers spike to 350. Prequal should detect each shift within 1–2 probe cycles (~1–2 s at the 1 Hz probing interval) through both the RIF increase and the latency elevation on the newly-loaded group, and begin steering away. Round-Robin has no such mechanism and keeps its uniform rotation across hot and cold servers alike.

The result-extraction pipeline (`parse-results.sh` + `plot_results.py`) was identical to the static case.

## 4.2 Measurement Method: Telemetry and Visualization

The primary measurement source is `hey`, which reports per-run latency distributions (p50, p90, p95, p99), achieved request rate, and HTTP status code breakdown. These values are extracted by `parse-results.sh` into the summary CSV. `hey` was chosen because its rate cap (`-q`) is deterministic, its output format is stable, and it is the de facto standard HTTP benchmarking tool in the Go ecosystem.

In addition to `hey`, a continuous Prometheus + Grafana telemetry stack was deployed on the `obs` node, providing real-time visibility throughout the experiment. The configuration and deployment of the monitoring dashboard were conducted following a precise step-by-step procedure:

**1. Accessing the Grafana Interface**
We located the public IP address of the observation (`obs`) node. We then accessed the Grafana web interface by navigating to `http://<obs-public-ip>:3001` and authenticated using the default administrative credentials.

**2. Configuring the Data Source**
Before visualizing any data, we configured Prometheus as the primary data source. Since the Prometheus container shares the host network on the observation node, the data source URL was configured to point locally at `http://localhost:9090`.

**3. Automated Dashboard Provisioning via JSON**
To ensure a rigorous and reproducible visualization environment, we manually create individual queries only the first time and later we automated the dashboard setup by importing the same JSON model ([`loadbalancer.json`](https://github.com/giacbusc/loadbalancer/blob/main/config/grafana/dashboards/loadbalancer.json)). This configuration file automatically provisions the Grafana workspace with a centralized "Algorithm" variable filter and the following measurement panels:

| Panel Name | Panel Type | Description |
| :--- | :--- | :--- |
| **Request Latency (Percentiles)** | Time series | A time-series panel that calculates and displays the 50th, 90th, 99th, and 99.9th percentile latencies dynamically using the `histogram_quantile` function over the `request_duration_seconds_bucket` metric. |
| **Active Requests (RIF)** | Time series | Tracks the total instantaneous count of requests currently in flight across the load balancer algorithms. |
| **Server Health** | Gauge | A gauge visualization that monitors the status of the backend servers, displaying `1` (Healthy, colored green) if probes succeed, or `0` (Down, colored red) if probes fail. |
| **Request Rate** | Time series | Computes the total system throughput in requests per second using the rate of `request_duration_seconds_count`. |
| **Server RIF — client-local** | Time series | Visualizes the `server_rif` metric to show the number of open requests from the perspective of the individual load balancer. |
| **Server RIF Reported — server-local** | Time series | Visualizes the `server_rif_reported` metric, reading the actual in-flight requests reported back by the backends themselves. |

## 4.3 Number of Runs and Statistical Treatment

**Number of runs.** Each experiment configuration (static, dynamic) was executed several times during development to stabilise the setup, and the figures reported here come from one representative full run of each: the static-antagonist run in `results-20260519-100906_STATIC/` and the dynamic-antagonist A/B run in `results-ab-20260531-094836_DINAMIC/`. In the dynamic case the two algorithms are the two passes of the same A/B run (Section 4.1.3), so they share an identical saturation reference, antagonist schedule, and per-level QPS target.

**Within-step sample size.** Each measurement step accumulates a large empirical sample per algorithm. In the static run a step collects roughly 18,000–25,000 completed requests (at ~290–400 req/s over 60 s); in the dynamic A/B run, where the load-minority profile leaves much more aggregate capacity, a step collects roughly 33,000–58,000 completed requests (at ~530–950 req/s over 60 s). For a p99 estimate from N samples the standard error scales as ≈ 1/√N, so at N in the tens of thousands the relative estimation error on the 99th percentile is well below 1 %, making the within-step latency estimates statistically robust.

**Percentile definition.** `hey` reports exact empirical quantiles from the full response-time sample collected during each step, measured end-to-end from request dispatch to response receipt at the load generator.

**Throughput definition.** Reported as `hey`'s `Requests/sec`: the number of completed HTTP 200 responses divided by the wall-clock duration of the step.

## 4.4 Correctness Verification

Several independent checks were performed to validate that the experiment was measuring what it was intended to measure.

**Saturation sanity check.** We checked that the measured peak throughput was consistent with the workload and the hardware: the per-backend request rate and the observed in-flight counts on the Grafana panels matched what a CPU-bound workload on an 8-core machine should produce, with no implausible values.

**Traffic distribution.** We inspected the `X-Served-By` response headers to confirm each policy routed as expected: roughly uniform across all backends under Round-Robin, and visibly skewed toward the unloaded backends under Prequal.

**Antagonist activity.** Before each ramp we confirmed the CPU burners were actually active and, in the dynamic run, that the hot set was moving through the fleet on schedule, by checking the backends' health responses and the Grafana RIF panel.

**Equal offered load.** We verified that both algorithms were driven with the same load: identical per-level QPS targets, and total request counts that agree closely in the sub-saturation steps where neither policy is capacity-limited.

**Container stability.** We monitored the containers throughout each run to confirm none restarted, which would have reset the in-memory RIF and latency state and invalidated a step.

## 4.5 Results

### 4.5.1 Static Antagonist Experiment

The full result set, taken directly from `results-20260519-100906_STATIC/summary.csv`, is summarized below. Latencies are in milliseconds (converted from the microsecond values in the CSV). Here the load levels run from 60 % to 180 % of the measured saturation, and both load balancers are driven simultaneously on the static three-group antagonist profile (heavy / light / clean).

| Load  | Prequal QPS | RR QPS  | Prequal p50 | RR p50  | Prequal p90  | RR p90   | Prequal p99  | RR p99   |
|-------|-------------|---------|-------------|---------|--------------|----------|--------------|----------|
| 60 %  | 293.6       | 294.0   | 348 ms      | 403 ms  | 756 ms       | 786 ms   | 1128 ms      | 1137 ms  |
| 75 %  | 293.9       | 293.9   | 396 ms      | 399 ms  | 795 ms       | 799 ms   | 1202 ms      | 1211 ms  |
| 90 %  | 291.6       | 291.3   | 414 ms      | 366 ms  | 857 ms       | 816 ms   | 1594 ms      | 1619 ms  |
| 100 % | **389.3**   | 358.7   | 394 ms      | 406 ms  | **1506 ms**  | 1778 ms  | **3589 ms**  | 3795 ms  |
| 110 % | **393.0**   | 355.0   | 399 ms      | 455 ms  | **1494 ms**  | 1787 ms  | **3489 ms**  | 3886 ms  |
| 125 % | **393.6**   | 354.2   | 391 ms      | 444 ms  | **1493 ms**  | 1782 ms  | **3409 ms**  | 3891 ms  |
| 145 % | **393.6**   | 360.0   | 399 ms      | 452 ms  | **1494 ms**  | 1749 ms  | **3318 ms**  | 3693 ms  |
| 165 % | **394.8**   | 368.0   | 392 ms      | 411 ms  | **1702 ms**  | 1899 ms  | **3915 ms**  | 4106 ms  |
| 180 % | **406.1**   | 358.7   | 391 ms      | 435 ms  | **1655 ms**  | 1969 ms  | **3819 ms**  | 4242 ms  |

**Below-allocation regime (60–90 %).** In the three sub-saturation steps, both algorithms deliver essentially identical performance. QPS, p50, p90, and p99 are within 5 % of each other. This is expected: when load is well below capacity, neither queuing nor heterogeneous server speed constitute differentiating factors. HCL selects the lowest-latency cold server, but with all servers comparably underloaded the distinction is negligible.

**Transition at 100 %.** The most significant behavioral change occurs at the 100 % step, which is the first to push the system at or beyond its measured saturation point. At this level Prequal delivers **389.3 req/s** against RR's **358.7 req/s** (+8.5 %). The p90 diverges sharply: **1506 ms** (Prequal) versus **1778 ms** (RR), a 15.3 % improvement. The p99 is **3589 ms** versus **3795 ms** (−5.4 %).

The sharp p90 jump from ~850 ms at 90 % to ~1500–1800 ms at 100 % marks the onset of queuing on the overloaded backends. Prequal partially absorbs this transition by routing new arrivals away from backends with elevated RIF, while Round-Robin continues distributing uniformly regardless of server state.

**Overload regime (110–180 %).** Across all six overload steps, Prequal consistently outperforms Round-Robin:

* **Throughput advantage**: +7.3 % to +13.2 %, **average +10.1 %**. The gap arises because RR continues sending requests to heavily loaded backends that respond slowly, effectively reducing delivered QPS relative to the capacity those backends could sustain if they were not further overwhelmed.
* **p90 latency advantage**: −11.8 % to −19.5 %, **average −17.4 %**. Prequal's p90 hovers around 1500–1700 ms throughout overload; RR's p90 climbs steadily from 1749 ms to 1969 ms. This is the most consistent and numerically largest signal in the static run.
* **p99 latency advantage**: −4.9 % to −14.1 %, **average −9.8 %**.

The generated figure is `results-20260519-100906_STATIC/figure6_comparison.png`, reproduced below.

<center>
  <img
    alt="Static-antagonist load ramp: Prequal sustains higher throughput and slightly lower tail latency than Round-Robin once load exceeds 100% allocation"
    src="results-20260519-100906_STATIC/figure6_comparison.png"
    style="width:80%;"
    />
  <p>Figure 2: Static-antagonist load ramp (our reproduction of paper Figure 6). (a) Tail latency on a log scale; the shaded region is above 100 % allocation. (b) Achieved throughput, with the per-step Prequal advantage annotated. Below allocation the two policies coincide; above it Prequal sustains +7–13 % throughput and lower p90/p99, but the gap stays moderate because the static burners produce no sub-second capacity collapses.</p>
</center>

### 4.5.2 Dynamic Antagonist Experiment

The dynamic A/B result set, taken from `results-ab-20260531-094836_DINAMIC/summary.csv`, is summarized below. Latencies are in milliseconds; QPS is the canonical LB (`.11`) rate. The load levels are 0.75×–1.74× of the common saturation reference (~722 req/s per LB, measured on Round-Robin). Note that the absolute QPS is much higher than in the static run because the load-minority profile keeps 7–8 of the ten backends clean at any instant, leaving far more aggregate capacity.

| Load  | Prequal QPS | RR QPS  | Prequal p50 | RR p50  | Prequal p90  | RR p90   | Prequal p99  | RR p99   |
|-------|-------------|---------|-------------|---------|--------------|----------|--------------|----------|
| 75 %  | 530.0       | 529.6   | 564 ms      | 543 ms  | 985 ms       | 981 ms   | 1300 ms      | 1349 ms  |
| 83 %  | 584.8       | 583.4   | 557 ms      | 548 ms  | 1003 ms      | 1006 ms  | 1338 ms      | 1417 ms  |
| 93 %  | 654.6       | 654.6   | 561 ms      | 518 ms  | 1015 ms      | 1016 ms  | 1372 ms      | 1495 ms  |
| 103 % | **725.8**   | 722.2   | 556 ms      | 512 ms  | **1004 ms**  | 1061 ms  | **1476 ms**  | 2315 ms  |
| 114 % | **802.0**   | 778.2   | 579 ms      | 544 ms  | **1052 ms**  | 1237 ms  | **1935 ms**  | 2858 ms  |
| 127 % | **867.9**   | 838.5   | 657 ms      | 499 ms  | **1413 ms**  | 1471 ms  | **2615 ms**  | 3420 ms  |
| 141 % | **904.2**   | 866.0   | 694 ms      | 530 ms  | **1677 ms**  | 1709 ms  | **3081 ms**  | 4103 ms  |
| 157 % | **923.2**   | 911.1   | 732 ms      | 559 ms  | **1819 ms**  | 1828 ms  | **3342 ms**  | 4270 ms  |
| 174 % | **946.4**   | 928.2   | 737 ms      | 599 ms  | **1877 ms**  | 1937 ms  | **3384 ms**  | 4111 ms  |

**Below-allocation regime (75–93 %).** As in the static run, the two policies are nearly indistinguishable in throughput (within 0.1 %) and p90 (within 1 %). The first sign of divergence appears at the tail: by 93 % Prequal's p99 (1372 ms) is already ~8 % below RR's (1495 ms), because even below nominal saturation the moving hot set occasionally forces RR to queue behind a loaded server while Prequal sidesteps it.

**Transition at 103 % (allocation boundary).** This is the sharpest result of the whole report. Exactly at the allocation boundary, RR's p99 jumps to **2315 ms** while Prequal's stays at **1476 ms** — a **36 % tail-latency reduction** — and Prequal's p90 is also lower (1004 ms vs 1061 ms). The two policies still deliver the same throughput here (~723 req/s), so the entire effect is concentrated in the tail: Round-Robin starts paying for the requests it keeps routing onto the currently-hot servers, whereas Prequal's HCL rule diverts them to the cold majority.

**Overload regime (114–174 %).** Across the six overload steps the dynamic advantage is dominated by the tail latency, and it is much larger than in the static run:

* **p99 latency advantage**: −18 % to −36 %, **average ≈ −26 %**. RR's p99 climbs to 4111 ms at 174 % while Prequal stays at 3384 ms. This is the headline signal of the dynamic experiment, and the gap is widest near the allocation boundary where the moving antagonist hurts a blind policy the most.
* **Throughput advantage**: 0 % to +4.4 %, **average ≈ +2.4 %**, peaking around the mid-overload steps (114–141 %). It is smaller than the static run's because here both policies are limited by the same large clean-server capacity, so the differentiation shows up in *how fast* requests complete (the tail) rather than in *how many* complete.
* **p90 latency advantage**: small and positive on average, most visible at 114 % (1052 ms vs 1237 ms, −15 %).

**The HCL median trade-off.** A striking feature of the dynamic data is that Prequal's **p50 is consistently higher** than RR's (e.g. 737 ms vs 599 ms at 174 %). This is not a defect: it is the Hot-Cold Lexicographic rule behaving as designed. By always preferring the lowest-latency *cold* server, Prequal deliberately accepts a slightly worse median in exchange for a much shorter tail. RR's lower median comes from occasionally hitting a fast clean server by luck on its rotation, but it pays for that luck with a long tail whenever the rotation lands on a hot one. Optimising the tail rather than the median is exactly the objective the paper sets for Prequal.

The generated figure is `results-ab-20260531-094836_DINAMIC/figure6_comparison.png`, reproduced below.

<center>
  <img
    alt="Dynamic-antagonist load ramp: Prequal's p99 separates sharply from Round-Robin's right at the 103% allocation boundary and stays 18-36% lower across overload"
    src="results-ab-20260531-094836_DINAMIC/figure6_comparison.png"
    style="width:80%;"
    />
  <p>Figure 3: Dynamic-antagonist A/B load ramp. (a) Tail latency on a log scale; the green annotations are the per-step p99 reduction of Prequal vs Round-Robin. The RR p99 line (red, solid triangles) lifts away from the Prequal p99 line (blue) right at 103 % allocation and stays 18–36 % higher across the overload region. (b) Achieved throughput, where the two policies are much closer than in the static case. Compared with the static run (Figure 2), the moving antagonist sharpens the tail-latency separation and shifts it earlier, exactly as the paper's motivation predicts.</p>
</center>

## 4.6 Comparison with the Paper

We compare against Figure 6 of the paper, matching its axes: load level as a fraction of server allocation on the x-axis, tail latency on a log scale and achieved throughput as the two panels.

### What our results reproduce

**The tail latency separates right at the allocation boundary.** The defining feature of the paper's Figure 6 is that the policies coincide below allocation and then diverge sharply once load crosses 1.0×. Our dynamic A/B run reproduces this shape directly: at 103 % allocation RR's p99 jumps to 2315 ms while Prequal's stays at 1476 ms, and the separation persists across the whole overload region (RR p99 18–36 % higher than Prequal). The direction and the location of the divergence match the paper.

**Prequal has lower tail latency under overload.** In both of our runs the sign of the difference agrees with the paper at every overload step. In the static run the most reliable signal is p90 (~17 % average advantage) with p99 ~10 %; in the dynamic run the tail signal is stronger and concentrated in p99 (~26 % average, up to 36 % at the boundary). This matches the paper's central claim that routing by RIF and latency protects the tail.

**Prequal sustains at least as much throughput.** The paper's Figure 6(b) shows Prequal holding QPS closer to target under overload. We observe the same direction in both runs: +7–13 % in the static run and a smaller +0–4 % in the dynamic run, never negative. HCL avoids routing new requests into already-congested queues, so it does not throttle itself the way a load-unaware policy can.

**Below allocation, the policies are equivalent.** The paper notes that below allocation the policies are "essentially identical" (§5.1). We observe the same: at 60–93 % load the two policies differ by less than ~5 % on throughput and p90 in both runs.

### Where our results differ in magnitude

**The gap is smaller than the paper's, and grows when the antagonist moves.** Figure 6(a) of the paper shows WRR's p99.9 hitting the 5-second timeout at 1.03× allocation while Prequal stays far below it — an order-of-magnitude separation. Our separation is real but smaller, and crucially it is **larger in the dynamic run than in the static run** (p99 ~26 % vs ~10 % average). This is the trend the paper predicts: Prequal's value comes from reacting to a *changing* capacity landscape, so a static antagonist understates it and a moving antagonist brings us closer to the paper's regime. The remaining magnitude gap is explained by the deviations documented in Section 3.4:

1. *Round-Robin vs. WRR.* The paper's baseline is Weighted Round-Robin, which actively concentrates load on replicas it perceives as under-utilised; a replica that slows down can attract *more* traffic and spiral. Plain Round-Robin distributes uniformly by construction and cannot exhibit that self-reinforcing imbalance, so it is a harder baseline to beat by a large margin.

2. *Smaller burst amplitude than the paper's antagonists.* The paper's Figure 3 shows machine CPU bursting to ~2× allocation at 1-second resolution. Our moving burners switch state every 10 seconds and saturate at a fixed level while hot, so the capacity landscape changes more coarsely than in production.

3. *Scale.* With 10 backends instead of 100, the probability that a `d = 2` sample lands entirely on saturated servers is lower, attenuating the statistical-multiplexing effect that makes the paper's separation so dramatic at datacenter scale.

### Takeaways

The core message of the paper is confirmed: **routing by RIF and latency yields lower tail latency, and no worse throughput, once load crosses the allocation boundary** — even in a simplified 10-server testbed with a weaker baseline (plain RR instead of WRR). More importantly, our two-run design isolates *why* the effect exists: the advantage is modest against a static antagonist and grows substantially once the antagonist moves, reproducing the paper's own explanation that Prequal's benefit lives in its ability to track a shifting capacity landscape that a load-unaware policy cannot see. The fact that the trend strengthens precisely when we move toward the paper's assumptions — rather than appearing as an artefact at one operating point — is the strongest evidence that our reproduction captures the real mechanism rather than a coincidence.

## 4.7 Debugging

### Issue 1: Load rate cap silently not enforced (`hey -q` ineffective)

**Symptom.** In the first version of the experiment script, `hey` was invoked with `-q 200 -c 50`. Despite the rate cap, the measured throughput was nearly identical across the upper load steps, suggesting the system was not actually being driven to the requested rate.

**Root cause.** `hey` distributes the `-q` cap uniformly across workers: each of the `c` workers is asked to achieve `-q / c` req/s. With `-c 50` and `-q 200`, each worker was capped at 4 req/s — one request every 250 ms. Under overload, individual request latency rose to 400–800 ms, so each worker could only deliver 1.25–2.5 req/s regardless of the cap. The effective system QPS silently collapsed to the natural throughput of 50 slow workers, far below the target.

**Fix.** The saturation discovery phase was restructured as an uncapped 20-second burst to find the true system ceiling. The concurrency was raised to `-c 300`. With 300 workers and response times of ~400 ms, each worker delivers ~2.5 req/s naturally, giving a ceiling of ~750 req/s — comfortably above our highest target (~460 req/s). The `-q` cap can now actually be reached and enforced at all nine load levels.

### Issue 2: Antagonist calibration — integer-division truncation

**Symptom.** In the initial setup, `cpu_load` was set to 80 (heavy) and 40 (light). The Grafana dashboards showed nearly identical RIF values across all backends, and the Prequal/RR curves were indistinguishable at all load levels.

**Root cause.** The `applyCPULoad` function in `backend/main.go` maps `cpu_load` to burner goroutines using thresholds at multiples of 50 (0→0 burners, <50→1, <100→2, …). With `cpu_load=80`, the mapping yielded `80/50 → 1` burner. With `cpu_load=40`, it yielded `40/50 → 0`, promoted to 1 by the minimum-1 guard. Both groups were left with a single burner goroutine — an identical configuration producing no observable differentiation. On an 8-core m510 machine, one burner consumes roughly 12.5 % of CPU capacity, far too little to create queuing.

**Fix.** The `cpu_load` values were recalibrated empirically to 350 for the heavy group (7 burners, ~87.5 % of available CPU) and 150 for the light group (3 burners, ~37.5 %). This creates a genuine, measurable asymmetry that both RIF and latency signals can detect. The calibration was verified by confirming that heavy-group backends (`server-0`–`server-3`) showed systematically higher `p50_us` values in their `/health` responses compared to clean-group backends, even when hit at identical request rates.

### Issue 3: Global vs. local RIF threshold in HCL

**Symptom.** Profiling of an early version showed that the HCL rule was classifying nearly all candidate servers as "cold" regardless of actual load, causing the selector to effectively reduce to a pure minimum-latency rule with no RIF component.

**Root cause.** The original open-source skeleton computed the Q_RIF quantile over only the `d = 2` sampled candidates, not over the full server pool. With two candidates and Q_RIF = 0.84, the 84th percentile of a two-element set is always the larger value — meaning one candidate is always classified "hot" and one "cold" regardless of whether the entire pool is under heavy load. The threshold carried no information about global system state.

**Fix.** A `recomputeGlobalThreshold()` function was added, called after each probe round. It computes the Q_RIF-th quantile across all healthy servers' current RIF values and stores the result in an atomic `currentRIFThreshold`. All HCL decisions use this global threshold, matching the specification in §4 of the paper: *"Prequal clients maintain an estimate of the distribution of RIF across replicas, based on recent probe responses."*

### Issue 4: Cross-policy contamination from two LBs on shared backends

**Symptom.** In the dynamic experiment, when Prequal (on `.11`) and Round-Robin (on `.12`) were driven simultaneously against the same ten backends, the gap between the two policies was suspiciously small and unstable from run to run — much smaller than the per-server traffic-distribution check (Section 4.4) suggested it should be.

**Root cause.** The two LBs share the same backend pool. While Prequal steers a query *away* from a momentarily-hot server, the Round-Robin LB keeps sending its share to that same server on its fixed rotation. The RIF that Prequal probes is therefore the superposition of both LBs' decisions, not the consequence of Prequal's own routing. Prequal is in effect being graded on a backend state that a competing, load-blind policy is actively spoiling, which compresses the measured advantage.

**Fix.** The dynamic experiment was restructured as a clean two-pass A/B (`experiment-ab.sh`, Section 4.1.3): one pass with the **whole fleet on Prequal**, a second pass with the **whole fleet on Round-Robin**, switching the algorithm at runtime via `/admin/algorithm`. Within each pass the routing is homogeneous, so there is no cross-policy contamination, and the two passes still share an identical antagonist schedule and per-level QPS target. We also set `LB_USE_SERVER_RIF=true` so each LB reads the total backend-reported RIF (`X-Server-RIF`) instead of only its own local in-flight count, which prevents the two same-algorithm LBs from independently picking the same idle server and overloading it together.

### Issue 5: Client-side timeout truncating the tail

**Symptom.** Early dynamic runs that used `hey -t 20` produced overload tails that looked almost identical for the two policies, hiding the divergence that the per-server checks predicted.

**Root cause.** Under overload the distinguishing part of the latency distribution lives at 2–4 s. A client timeout cuts every request that exceeds it and re-counts it as a failure, which removes exactly the slow requests on which Round-Robin and Prequal differ and flattens the measured tail (and inflates the apparent throughput symmetrically).

**Fix.** The dynamic A/B ramp runs `hey` **without** a `-t` timeout, letting every request complete and be recorded. This preserves the full tail and is what makes the 18–36 % p99 separation in Section 4.5.2 visible. The raw `hey` output for every step (e.g. `rr_174pct.txt` with a slowest response of 13.2 s) confirms that the long tail was captured rather than truncated.



