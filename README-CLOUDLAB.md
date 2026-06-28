# Prequal Load Balancer — CloudLab Distributed Setup

Distributed reproduction of the experiments from
**"Load is not what you should balance: Introducing Prequal"** (NSDI '24).

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
- No sinkhole protection (error-aversion heuristic from §4)
- Probing is at fixed interval (every 1s), not per-query as in §4
- 10 servers × 2 LBs is small compared to the paper's 100×100 setup

## How to run on CloudLab

1. Push the `cloudlab` branch to your GitHub fork.
2. On https://www.cloudlab.us/, create a profile from this repo
   (Source: Git Repository, branch: `cloudlab`).
3. Instantiate. Wait ~10 minutes for all nodes to finish setup
   (tail `/tmp/cloudlab-setup.log` on a node via SSH to monitor).
4. Verify everything is up:
   ```bash
   ssh <user>@lb-prequal.<...>.cloudlab.us
   curl localhost:8080/health
   ```
5. Run the main experiment from a loadgen node:
   ```bash
   ssh <user>@loadgen-0.<...>.cloudlab.us
   cd /opt/loadbalancer
   ./experiments/run-experiment.sh 60                       # 60 seconds per load level
   ./experiments/parse-results.sh /tmp/results-XXXXXXXX     # extract CSV summary
   ```
6. Open Grafana at `http://<obs-public-hostname>:3001` (admin/admin),
   add Prometheus datasource at `http://10.10.1.10:9090`.

## Run the secondary experiment (client-local vs server-local RIF)

```bash
ssh <user>@loadgen-0.<...>.cloudlab.us
cd /opt/loadbalancer
./experiment-rif-source.sh
```

This experiment restarts the lb-prequal container twice, once with
`LB_USE_SERVER_RIF=false` and once with `=true`, and runs the same load
against both configurations. The only variable changed between runs is
the source of the RIF signal used by HCL.

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
