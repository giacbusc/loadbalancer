"""
Prequal Load Balancer — Distributed Experiment on CloudLab

Topology (15 nodes):
  - 1 obs        — Prometheus + Grafana
  - 2 LBs        — one running Prequal, one running Round-Robin
  - 10 backends  — 4 with heavy antagonist, 3 with light, 3 clean
  - 2 loadgens   — for hey-based load generation

The antagonist is a real in-process CPU burner (goroutines spinning on
arithmetic), not a time.Sleep. This produces actual CPU contention with
the request-serving threads, faithful to the paper's experimental setup.
"""

import geni.portal as portal
import geni.rspec.pg as rspec

pc = portal.Context()
request = pc.makeRequestRSpec()

# -- Parameters ----------------------------------------------------------------
pc.defineParameter(
    "hardware_type", "Hardware type",
    portal.ParameterType.NODETYPE, "d710",
    longDescription="d710 (Utah) is a safe default. c220g5 (Wisconsin) is more modern."
)
pc.defineParameter(
    "repo_url", "Git repository URL",
    portal.ParameterType.STRING,
    "https://github.com/YOUR_USERNAME/loadbalancer.git",
)
pc.defineParameter(
    "repo_branch", "Git branch",
    portal.ParameterType.STRING, "cloudlab",
)
params = pc.bindParameters()

# -- LAN -----------------------------------------------------------------------
lan = request.LAN("expLAN")
lan.bandwidth = 1000000  # 1 Gbps

UBUNTU_IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"

def make_node(name, role, ip, extra_args=""):
    n = request.RawPC(name)
    n.hardware_type = params.hardware_type
    n.disk_image = UBUNTU_IMAGE

    iface = n.addInterface("if0")
    iface.addAddress(rspec.IPv4Address(ip, "255.255.255.0"))
    lan.addInterface(iface)

    n.addService(rspec.Execute(
        shell="bash",
        command=("sudo -H bash /local/repository/cloudlab-setup.sh "
                 + role + " "
                 + params.repo_url + " "
                 + params.repo_branch + " "
                 + extra_args
                 + " > /tmp/cloudlab-setup.log 2>&1")
    ))
    return n

# -- Topology ------------------------------------------------------------------
# IP plan on 10.10.1.0/24:
#   10.10.1.10        obs
#   10.10.1.11        lb-prequal
#   10.10.1.12        lb-rr
#   10.10.1.21..30    server-0 .. server-9
#   10.10.1.31..32    loadgen-0, loadgen-1

make_node("obs",        "obs",         "10.10.1.10")
make_node("lb-prequal", "lb-prequal",  "10.10.1.11")
make_node("lb-rr",      "lb-rr",       "10.10.1.12")

# 10 backends with heterogeneous antagonist load:
#   4 heavy (cpu_load=80)
#   3 light (cpu_load=40)
#   3 clean (cpu_load=0)
backend_specs = [
    ("server-0", 80), ("server-1", 80), ("server-2", 80), ("server-3", 80),
    ("server-4", 40), ("server-5", 40), ("server-6", 40),
    ("server-7", 0),  ("server-8", 0),  ("server-9", 0),
]
for i, (name, cpu_load) in enumerate(backend_specs):
    make_node(name, "backend", "10.10.1.{}".format(21 + i), extra_args=str(cpu_load))

make_node("loadgen-0", "loadgen", "10.10.1.31")
make_node("loadgen-1", "loadgen", "10.10.1.32")

pc.printRequestRSpec(request)
