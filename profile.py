"""
Prequal Load Balancer - Distributed Experiment on CloudLab - BRANCH

FIXED for m510 (8 cores per node): antagonist intensity raised so that
"heavy" servers are dramatically slower than "clean" ones, recreating the
paper's scenario of contended vs. uncontended replicas.

Topology (15 nodes):
  - 1 obs        : Prometheus + Grafana
  - 2 LBs        : Prequal and Round-Robin
  - 10 backends  : 4 heavy (7 burners) + 3 light (3 burners) + 3 clean
  - 2 loadgens

cpu_load -> burners mapping in backend (applyCPULoad): n = load/50
  cpu_load=350 -> 7 burners -> saturates 7 of 8 cores  (server ~7x slower)
  cpu_load=150 -> 3 burners -> saturates 3 of 8 cores
  cpu_load=0   -> 0 burners -> clean
"""

import geni.portal as portal
import geni.rspec.pg as rspec

pc = portal.Context()
request = pc.makeRequestRSpec()

pc.defineParameter(
    "hardware_type", "Hardware type",
    portal.ParameterType.NODETYPE, "m510",
    longDescription="m510 (Utah) has good availability and 8 cores per node."
)
pc.defineParameter(
    "repo_url", "Git repository URL",
    portal.ParameterType.STRING,
    "https://github.com/giacbusc/loadbalancer.git",
)
pc.defineParameter(
    "repo_branch", "Git branch",
    portal.ParameterType.STRING, "main",
)
params = pc.bindParameters()

lan = request.LAN("expLAN")
lan.bandwidth = 1000000

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

make_node("obs",        "obs",         "10.10.1.10")
make_node("lb-prequal", "lb-prequal",  "10.10.1.11")
make_node("lb-rr",      "lb-rr",       "10.10.1.12")

# STRONG antagonists for m510 (8 cores).
backend_specs = [
    ("server-0", 350), ("server-1", 350), ("server-2", 350), ("server-3", 350),
    ("server-4", 150), ("server-5", 150), ("server-6", 150),
    ("server-7", 0),   ("server-8", 0),   ("server-9", 0),
]
for i, (name, cpu_load) in enumerate(backend_specs):
    make_node(name, "backend", "10.10.1.{}".format(21 + i), extra_args=str(cpu_load))

make_node("loadgen-0", "loadgen", "10.10.1.31")
make_node("loadgen-1", "loadgen", "10.10.1.32")

pc.printRequestRSpec(request)
