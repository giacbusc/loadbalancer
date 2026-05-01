# Prequal Load Balancer — CloudLab Distributed Setup

Distributed reproduction of the experiments from
**"Load is not what you should balance: Introducing Prequal"** (NSDI '24).

This branch adapts the original single-host docker-compose project to run on
a CloudLab cluster as 9 separate physical nodes:

| Role          | Nodes | IP             | Description                       |
| ------------- | ----- | -------------- | --------------------------------- |
| obs           | 1     | 10.10.1.10     | Prometheus + Grafana              |
| lb-prequal    | 1     | 10.10.1.11     | Load balancer running Prequal     |
| lb-rr         | 1     | 10.10.1.12     | Load balancer running Round-Robin |
| server-heavy  | 2     | 10.10.1.21-22  | Backends with antagonist load     |
| server-clean  | 2     | 10.10.1.23-24  | Clean backends                    |
| loadgen       | 2     | 10.10.1.31-32  | hey-based load generators         |

## What was changed vs. main

1. Load balancer reads all configuration from environment variables
   (BACKENDS list, QRIF, probe interval, algorithm, etc.).
2. Backend reports server-local RIF via `X-Server-RIF` header,
   enabling the experiment that contrasts client-local vs server-local RIF.
3. Backend exposes `POST /admin/load?cpu=N` to vary antagonist load at runtime.
4. New `profile.py` defines the CloudLab topology.
5. New `cloudlab-setup.sh` is run by each node at boot, installs Docker,
   clones the repo, and starts the appropriate container per role.
6. New `run-experiment.sh` reproduces the load-ramp from Figure 6 of the
   paper, hitting both LBs in parallel and saving hey output.
7. New `experiment-rif-source.sh` runs the original-question experiment
   comparing client-local vs server-local RIF as the HCL signal.

## How to use on CloudLab

1. Push this branch to your GitHub fork.
2. On https://www.cloudlab.us/, create an experiment profile pointing at this
   repo (Profile Source: "Git Repository", URL: your fork, branch: `cloudlab`).
3. Instantiate the profile. Wait ~10 minutes for all nodes to finish setup
   (you can tail `/tmp/cloudlab-setup.log` on each node via SSH).
4. Verify nothing is on fire:
   ```bash
   ssh <user>@lb-prequal   # then: curl localhost:8080/health
   ssh <user>@server-0     # then: curl localhost:8080/health
   ```
5. Run the main experiment from a loadgen node:
   ```bash
   ssh <user>@loadgen-0
   cd /opt/loadbalancer
   ./run-experiment.sh 60       # 60 seconds per load step
   ./parse-results.sh /tmp/results-XXXXXXXX
   ```
6. Open Grafana on the obs node:
   `http://<obs-public-hostname>:3001` (admin / admin), add Prometheus
   datasource pointing at `http://10.10.1.10:9090`.

## Run the secondary (client-local vs server-local RIF) experiment

```bash
ssh <user>@loadgen-0
cd /opt/loadbalancer
./experiment-rif-source.sh
```

Output is written to `/tmp/rif-source-YYYYMMDD-HHMMSS/`.
