# Procedure di esecuzione su CloudLab

Guida operativa per lanciare i tre esperimenti sul cluster CloudLab:

1. **Esperimento Statico classico** — load-ramp con antagonista statico (Report §4.5.1)
2. **Esperimento Dinamico A/B** — load-ramp a due passate con antagonista mobile (Report §4.5.2)
3. **Esperimento Shock** — risposta transitoria a shock correlato (Further Exploration §5)

> Tutti i comandi degli esperimenti si lanciano **da un nodo loadgen** (`loadgen-0`, `10.10.1.31`), nella cartella del repo (`/opt/loadbalancer` sui nodi CloudLab). I nodi hanno SSH senza password tra loro e raggiungono gli LB su `:8080`.

---

## 0. Preparazione del cluster (una volta sola)

### 0.1 Istanziare il profilo
1. Push del branch sul fork GitHub.
2. Su <https://www.cloudlab.us/> crea un profilo da questo repo (Source: Git Repository) e **istanzia** (topologia a 15 nodi, vedi [README-CLOUDLAB.md](README-CLOUDLAB.md)).
3. Attendi ~10 min che `cloudlab-setup.sh` finisca su tutti i nodi. Monitora con:
   ```bash
   ssh <user>@<nodo>.cloudlab.us "tail -f /tmp/cloudlab-setup.log"
   ```

### 0.2 Aggiornare il codice sui nodi
Gli script nuovi (`experiment-shock.sh`, `plot_shock.py`, `set-probe-interval.sh`) devono trovarsi sui nodi. Dopo aver fatto commit+push:
```bash
# dalla tua macchina locale
./deploy.sh            # git pull + restart container su tutti i nodi
# oppure solo i loadgen se ti servono solo gli script:
ssh <user>@loadgen-0.<...>.cloudlab.us "cd /opt/loadbalancer && git pull"
```

### 0.3 Verifica che tutto sia su
```bash
ssh <user>@loadgen-0.<...>.cloudlab.us
cd /opt/loadbalancer
curl -s http://10.10.1.11:8080/health   # Prequal LB → healthy
curl -s http://10.10.1.12:8080/health   # RR LB → healthy
for n in 21 22 23 24 25 26 27 28 29 30; do
  curl -s "http://10.10.1.$n:8080/health" >/dev/null && echo "backend .$n OK"
done
```

### 0.4 Grafana (opzionale, telemetria live)
Apri `http://<obs-public-hostname>:3001` (admin/admin), datasource Prometheus `http://10.10.1.10:9090`. Dashboard provisionata da [config/grafana/dashboards/loadbalancer.json](config/grafana/dashboards/loadbalancer.json).

---

## 1. Esperimento Statico classico

Antagonista **statico** a tre gruppi (heavy/light/clean), entrambi gli LB guidati **simultaneamente**. Riproduce la Figura 6 del paper (Report §4.5.1).

```bash
ssh <user>@loadgen-0.<...>.cloudlab.us
cd /opt/loadbalancer

# load-ramp statico, 60s per livello (9 livelli, 0.60×→1.80× saturazione)
./run-experiment.sh 60

# estrai il CSV riassuntivo (sostituisci con la cartella stampata a fine run)
./parse-results.sh /tmp/results-YYYYMMDD-HHMMSS

# genera la figura a due pannelli (tail latency log + throughput)
python3 plot_results.py /tmp/results-YYYYMMDD-HHMMSS
```

Output: `summary.csv` e `figure6_comparison.png` nella cartella `/tmp/results-...`.

> **Nota antagonista**: in modalità statica i carichi CPU dei backend sono quelli impostati al boot da `profile.py`/`cloudlab-setup.sh` (heavy=350, light=150, clean=0). Per controllarli prima del run: `./watch-backends.sh`.

---

## 2. Esperimento Dinamico A/B

Due passate separate (flotta **tutta-Prequal**, poi **tutta-RR**) → nessuna contaminazione cross-policy. Antagonista **mobile**: 2-3 backend caldi che si spostano nella flotta ogni `DURATION/6` secondi (Report §4.1.3).

### 2.1 Prerequisito: LB con `USE_SERVER_RIF=true`
L'A/B presuppone RIF server-local (evita l'effetto gregge multi-LB). Al boot è `false`, quindi ricrea i container LB col valore giusto:
```bash
USE_SERVER_RIF=true ./set-probe-interval.sh 250ms
```
(riusa lo script dello sweep solo per ricreare gli LB con l'env corretta; 250ms = valore deployato).

### 2.2 (Opzionale) verifica visiva del ciclo antagonista
In due terminali su `loadgen-0`:
```bash
# terminale 1
./dynamic-antagonist.sh
# terminale 2 — guarda i 2-3 caldi spostarsi
./watch-backends.sh
# poi ferma il terminale 1 (Ctrl+C) prima di lanciare l'esperimento
```

### 2.3 Run
```bash
cd /opt/loadbalancer

# A/B dinamico, 60s per livello (il ciclo antagonista riparte da solo)
./experiment-ab.sh 60 dynamic

# parse + plot (la cartella è /tmp/results-ab-...)
./parse-results.sh /tmp/results-ab-YYYYMMDD-HHMMSS
python3 plot_results.py /tmp/results-ab-YYYYMMDD-HHMMSS
```

Output: `summary.csv` e `figure6_comparison.png` (LB canonico = `.11`; l'output di `.12` finisce in `_lb2/` ed è ignorato dal parser).

> Per la variante **statica A/B** (stesso harness a due passate, antagonista a tre gruppi): `./experiment-ab.sh 60 static`.

---

## 3. Esperimento Shock (Further Exploration §5)

Risposta **transitoria** a uno shock **correlato**: carico costante, e a onda quadra si colpiscono `NHOT` backend su 10 contemporaneamente. Misura **reazione** e **recupero** di Prequal vs RR via `hey -o csv` + ensemble averaging. Va **oltre il paper** (che misura solo a regime).

### 3.1 Run base
```bash
ssh <user>@loadgen-0.<...>.cloudlab.us
cd /opt/loadbalancer

# 180s per passata, 6/10 backend colpiti per shock (default HOT=8s, COOL=12s)
./experiment-shock.sh 180 6
```
Lo script fa già parse interno e chiama `plot_shock.py` a fine run. Output nella cartella `/tmp/results-shock-..._NHOT6/`:
- `prequal.csv`, `rr.csv` — latenza per-richiesta
- `*_edges.log` — istanti dei fronti shock ON/OFF
- `shock_response.png` — curva p99(t) Prequal vs RR con picco e tempo di recupero

### 3.2 Sweep "no escape" (frazione di flotta colpita)
Trova il punto in cui sparisce la maggioranza fredda e il vantaggio di Prequal svanisce:
```bash
for n in 2 4 6 8; do
  ./experiment-shock.sh 180 $n
done
```
Ogni run stampa a console `picco p99` e `recupero` per entrambe le policy → tabula al variare di `NHOT` per la curva "vantaggio vs frazione calda".

### 3.3 Sweep di freschezza del segnale (probe interval)
Il probe interval è fissato al boot (`LB_PROBE_INTERVAL`, [cloudlab-setup.sh:98](cloudlab-setup.sh#L98)). Per cambiarlo **non serve buttare giù il cluster**: ricrea solo i container LB con [set-probe-interval.sh](set-probe-interval.sh):
```bash
for iv in 250ms 1s 2s; do
  ./set-probe-interval.sh "$iv"     # ricrea lb su .11 e .12, attende healthy
  ./experiment-shock.sh 180 6
done
```
Verifica il valore attivo:
```bash
ssh 10.10.1.11 "sudo docker logs lb 2>&1 | grep -i probe_interval"
```

### 3.4 Parametri tunabili (env / argomenti)
| Cosa | Come | Default |
|---|---|---|
| Durata per passata | 1° argomento | 180 s |
| Backend colpiti (NHOT) | 2° argomento | 6 |
| Carico base | `BASE_LEVEL=` | 1.00× sat. |
| Durata shock ON / OFF | `HOT=` / `COOL=` | 8 / 12 s |
| Warmup prima del 1° shock | `WARMUP=` | 12 s |
| Intensità antagonista | `SHOCK_LOAD=` | 350 |

Esempio: `BASE_LEVEL=1.10 HOT=6 COOL=14 ./experiment-shock.sh 240 6`

> Se l'ensemble è rumoroso (pochi cicli), aumenta la durata: con `HOT=8/COOL=12` servono ~180-240 s per 8-11 cicli.

---

## 4. Recuperare le figure in locale
```bash
# dalla tua macchina
scp -r <user>@loadgen-0.<...>.cloudlab.us:/tmp/results-shock-*_NHOT6 .
```
Se `plot_*.py` non gira sul nodo (mancano pandas/matplotlib), copia i risultati e plotta in locale (qui c'è `.venv-plot/`):
```bash
.venv-plot/bin/python plot_shock.py ./results-shock-..._NHOT6
.venv-plot/bin/python plot_results.py ./results-ab-...
```

---

## 5. Promemoria / errori comuni
- **`hey -o csv`**: conferma i nomi colonna sulla build del cluster con `hey -o csv -n 3 http://10.10.1.11:8080 | head -1` (il plotter usa `response-time` e `offset`).
- **`USE_SERVER_RIF`**: `true` per gli A/B e lo shock (multi-LB Prequal), `false` solo se vuoi il setup originale single-policy.
- **`sudo docker`**: su CloudLab docker richiede di solito sudo; `set-probe-interval.sh` lo usa di default (override con `DOCKER=docker`).
- **Container stabili**: nessun `lb`/`backend` deve riavviarsi durante un run (resetterebbe RIF e finestra latenza). Controlla con `sudo docker ps`.
- **Pulizia stato**: tra run pesanti, un `./set-probe-interval.sh 250ms` ricrea gli LB puliti; i backend tornano clean a fine `experiment-shock.sh` (trap di cleanup).
