# Prequal Load Balancer — CloudLab Distributed Setup

Distributed reproduction of the experiments from
**"Load is not what you should balance: Introducing Prequal"** (NSDI '24).

This is a 15-node CloudLab deployment that runs Prequal and Round-Robin
side by side on real, separate machines under real CPU contention, so the
two policies can be compared under identical load.

## Topology (15 nodes)

| Role         | Count | IPs                | Purpose                                      |
| ------------ | ----- | ------------------ | -------------------------------------------- |
| obs          | 1     | 10.10.1.10         | Prometheus + Grafana                         |
| lb-prequal   | 1     | 10.10.1.11         | Load balancer running Prequal                |
| lb-rr        | 1     | 10.10.1.12         | Load balancer running Round-Robin            |
| backend      | 10    | 10.10.1.21..30     | 4 heavy + 3 light + 3 clean antagonist load  |
| loadgen      | 2     | 10.10.1.31..32     | hey-based load generators                    |

## What's faithful to the paper (and what isn't)

Faithful:
- **Power of d Choices** with d=2 by default
- **HCL replica selection rule** with QRIF threshold (default 0.84)
- **Sampling without replacement** (partial Fisher-Yates shuffle)
- **Global RIF threshold** (computed across all servers, recomputed every probe round)
- **Server-reported recent-query latency** (median of last 128 completed queries)
- **Server-local RIF** signal (read from `X-Server-RIF` header on probe responses)
- **Real CPU contention** via in-process burner goroutines (not `time.Sleep`)
- **High-variance query cost** (SHA256 work with stddev = mean)

Still simplified vs. the paper:
- No "probe pool with reuse limit / age-out / remove-worst" mechanism
- No sinkhole protection (error-aversion heuristic from section 4)
- Probing is at fixed interval (every 1s), not per-query as in section 4
- 10 servers × 2 LBs is small compared to the paper's 100×100 setup

## The experiments

The deployment ships with three experiments, each targeting a different
question about how Prequal behaves relative to Round-Robin. They are
described conceptually below; the exact commands to run them are in
**[EXPERIMENTS-CLOUDLAB.md](EXPERIMENTS-CLOUDLAB.md)**.

### 1. Static classic (Report 4.5.1)

The reference experiment. The antagonist load on the backends is **fixed**
into three groups (heavy / light / clean) and stays put for the whole run.
Both load balancers are driven **simultaneously** with the same load ramp,
sweeping from under-saturation to over-saturation (0.60×→1.80× of capacity
across 9 levels).

This reproduces **Figure 6** of the paper: it shows how tail latency and
throughput of the two policies diverge as the fleet is pushed past
saturation, with a stable, known distribution of slow machines.

### 2. Dynamic A/B (Report 4.5.2)

Same load ramp, but the contention is no longer static. A **mobile
antagonist** keeps 2–3 backends hot and relocates them across the fleet
every `DURATION/6` seconds, so the set of slow machines is a moving target
that the balancer cannot learn once and exploit forever.

To keep the comparison clean it runs as a true **A/B**: two separate
passes, one with the fleet routed **entirely through Prequal** and one
**entirely through Round-Robin**, with no cross-policy contamination. This
isolates how quickly each policy's signal tracks contention that shifts
underneath it. A static variant of the same two-pass design is also
available.

### 3. Correlated shock (Further Exploration report section 5)

Goes **beyond the paper**, which only measures steady state. Under a
**constant** base load, a square-wave shock hits `NHOT` of the 10 backends
**at the same time**, then releases them, repeatedly. The experiment
captures the **transient**: how high the p99 spikes when the shock lands
(reaction) and how long each policy takes to return to baseline
(recovery), averaged over many shock cycles.

Two sweeps explore the edges of this behavior:
- **Fraction of fleet shocked** (`NHOT` from 2→8): finds the point where
  the cold majority disappears and Prequal's advantage vanishes — there is
  nowhere left to route to.
- **Signal freshness** (probe interval, e.g. 250ms / 1s / 2s): shows how
  the staleness of Prequal's probe signal trades off against its ability to
  react to a sudden shock.

## Tunable parameters (env vars on the lb container)

| Variable                | Default | Description                              |
|-------------------------|---------|------------------------------------------|
| LB_ALGORITHM            | prequal | `prequal` or `roundrobin`                |
| LB_QRIF                 | 0.84    | RIF quantile threshold for HCL           |
| LB_SELECTION_CHOICES    | 2       | d in Power of d Choices                  |
| LB_PROBE_INTERVAL       | 1s      | how often to probe each backend          |
| LB_PROBE_TIMEOUT        | 2s      | probe RPC timeout                        |
| LB_USE_SERVER_RIF       | false   | use server-local RIF instead of client-local |
| BACKENDS                | (none)  | comma-separated `host:port` list         |

## Tunable parameters (env vars on backend containers)

| Variable | Default | Description                                |
|----------|---------|--------------------------------------------|
| PORT     | 8080    | listen port                                |
| SERVER_ID| unknown | identifier reported in `X-Served-By`       |
| CPU_LOAD | 0       | antagonist intensity (0..400). 50 ≈ 1 burner |

The backend exposes `POST /admin/load?cpu=N` to mutate `CPU_LOAD` at runtime.

## Running the experiments

Cluster provisioning, health checks, and the exact commands for each of the
three experiments (plus the parameter sweeps and how to pull the figures
back locally) are in **[EXPERIMENTS-CLOUDLAB.md](EXPERIMENTS-CLOUDLAB.md)**.

## Credits

This project started as a fork of Omar Shaarawi's
[loadbalancer](https://github.com/omarshaarawi/loadbalancer), which provided
the initial Prequal / Round-Robin implementation. The CloudLab distributed
setup, the antagonist model, and the three experiments described above were
built on top of it.
