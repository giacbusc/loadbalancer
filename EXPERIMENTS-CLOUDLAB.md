# CloudLab execution procedures

Operational guide for running the three experiments on CloudLab:

1. **Static classic experiment** — load ramp with static antagonist (Report 4.5.1)
2. **Dynamic A/B experiment** — two-pass load ramp with mobile antagonist (Report 4.5.2)
3. **Shock experiment** — transient response to a correlated shock (Further Exploration 5)

> All experiment commands are run **from a loadgen node** (`loadgen-0`), in the repo directory (`/opt/loadbalancer` on the CloudLab nodes). The nodes have passwordless SSH between them and reach the LBs on `:8080`.

---

## 0. Cluster preparation

### 0.1 Instantiate the profile
1. Push the branch to your GitHub fork.
2. On <https://www.cloudlab.us/> create a profile from this repo and **instantiate** it (15-node topology, see [README-CLOUDLAB.md](README-CLOUDLAB.md)).
3. Wait about 10 min for `cloudlab-setup.sh` to finish on all nodes.

### 0.2 Verify everything is up
```bash
ssh <user>@loadgen-0.<...>.cloudlab.us
cd /opt/loadbalancer
curl -s http://10.10.1.11:8080/health   # Prequal LB → healthy
curl -s http://10.10.1.12:8080/health   # RR LB → healthy
for n in 21 22 23 24 25 26 27 28 29 30; do
  curl -s "http://10.10.1.$n:8080/health" >/dev/null && echo "backend .$n OK"
done
```

### 0.3 Check `hey` (load generator)
The experiments drive load with [`hey`](https://github.com/rakyll/hey), which
`cloudlab-setup.sh` already installs on the loadgen nodes. Verify it is on the
`PATH`:
```bash
hey --version
```
If it is missing, install it from apt:
```bash
sudo apt install hey
```

### 0.4 Grafana (optional, live telemetry)
Open `http://<obs-public-hostname>:3001` (admin/admin), Prometheus datasource `http://10.10.1.10:9090`. Dashboard provisioned from [config/grafana/dashboards/loadbalancer.json](config/grafana/dashboards/loadbalancer.json).

---

## 1. Static classic experiment

**Static** antagonist in three groups (heavy/light/clean), both LBs driven **simultaneously**. Reproduces Figure 6 of the paper (Report 4.5.1).

```bash
ssh <user>@loadgen-0.<...>.cloudlab.us
cd /opt/loadbalancer

# static load ramp, 60s per level (9 levels, 0.60×→1.80× saturation)
./experiments/run-experiment.sh 60

# extract the summary CSV (replace with the folder printed at the end of the run)
./experiments/parse-results.sh /tmp/results-YYYYMMDD-HHMMSS

# generate the two-panel figure (tail latency log + throughput)
python3 analysis/plot_results.py /tmp/results-YYYYMMDD-HHMMSS
```

Output: `summary.csv` and `figure6_comparison.png` in the `/tmp/results-...` folder.

> **Antagonist note**: in static mode the backend CPU loads are the ones set at boot by `profile.py`/`cloudlab-setup.sh` (heavy=350, light=150, clean=0). To check them before the run: `./experiments/watch-backends.sh`.

---

## 2. Dynamic A/B experiment

Two separate passes (**all-Prequal** fleet, then **all-RR**), no cross-policy contamination. **Mobile** antagonist: 2-3 hot backends that move across the fleet every `DURATION/6` seconds (Report 4.1.3).

### 2.1 (Optional) visual check of the antagonist cycle
In two terminals on `loadgen-0`:
```bash
# terminal 1
./experiments/dynamic-antagonist.sh
# terminal 2 — watch the 2-3 hot ones move
./experiments/watch-backends.sh
# then stop terminal 1 (Ctrl+C) before launching the experiment
```

### 2.2 Run
```bash
cd /opt/loadbalancer

# dynamic A/B, 60s per level (the antagonist cycle restarts on its own)
./experiments/experiment-ab.sh 60 dynamic

# parse + plot (the folder is /tmp/results-ab-...)
./experiments/parse-results.sh /tmp/results-ab-YYYYMMDD-HHMMSS
python3 analysis/plot_results.py /tmp/results-ab-YYYYMMDD-HHMMSS
```

Output: `summary.csv` and `figure6_comparison.png` (canonical LB = `.11`; the output of `.12` ends up in `_lb2/` and is ignored by the parser).

> For the **static A/B** variant (same two-pass concept, three-group antagonist): `./experiments/experiment-ab.sh 60 static`.

---

## 3. Shock experiment (Further Exploration report section 5)

**Transient** response to a **correlated** shock: constant load, and in a square wave `NHOT` backends out of 10 are hit at the same time. Measures Prequal's vs RR's **reaction** and **recovery** via `hey -o csv` + ensemble averaging. Goes **beyond the paper**, which only measures steady state.

### 3.1 Base run
```bash
ssh <user>@loadgen-0.<...>.cloudlab.us
cd /opt/loadbalancer

# 180s per pass, 6/10 backends hit per shock (default HOT=8s, COOL=12s)
./experiments/experiment-shock.sh 180 6
```

The script already does internal parsing and calls `analysis/plot_shock.py` at the end of the run. Output in the `/tmp/results-shock-..._NHOT6/` folder:
- `prequal.csv`, `rr.csv` — per-request latency
- `*_edges.log` — timestamps of the shock ON/OFF edges
- `shock_response.png` — p99(t) curve Prequal vs RR with peak and recovery time

### 3.2 "No escape" sweep (fraction of fleet hit)
Finds the point where the cold majority disappears and Prequal's advantage vanishes:
```bash
for n in 2 4 6 8; do
  ./experiments/experiment-shock.sh 180 $n
done
```
Each run prints `p99 peak` and `recovery` to the console for both policies → tabulate as `NHOT` varies for the "advantage vs hot fraction" curve.

### 3.3 Signal freshness sweep (probe interval)
The probe interval is fixed at boot (`LB_PROBE_INTERVAL`, [cloudlab-setup.sh:98](cloudlab-setup.sh#L98)). To change it you **don't need to tear down the cluster**: just recreate the LB containers with [set-probe-interval.sh](set-probe-interval.sh):
```bash
for iv in 250ms 1s 2s; do
  ./set-probe-interval.sh "$iv"     # recreates lb on .11 and .12, waits for healthy
  ./experiments/experiment-shock.sh 180 6
done
```
Check the active value:
```bash
ssh 10.10.1.11 "sudo docker logs lb 2>&1 | grep -i probe_interval"
```

### 3.4 Tunable parameters (env / arguments)
| What | How | Default |
|---|---|---|
| Duration per pass | 1st argument | 180 s |
| Backends hit (NHOT) | 2nd argument | 6 |
| Base load | `BASE_LEVEL=` | 1.00× sat. |
| Shock ON / OFF duration | `HOT=` / `COOL=` | 8 / 12 s |
| Warmup before 1st shock | `WARMUP=` | 12 s |
| Antagonist intensity | `SHOCK_LOAD=` | 350 |

Example: `BASE_LEVEL=1.10 HOT=6 COOL=14 ./experiments/experiment-shock.sh 240 6`

> If the ensemble is noisy (few cycles), increase the duration: with `HOT=8/COOL=12` you need ~180-240 s for 8-11 cycles.

---

## 4. Retrieve the figures locally
```bash
# from your machine
scp -r <user>@loadgen-0.<...>.cloudlab.us:/tmp/results-shock-*_NHOT6 .
```
