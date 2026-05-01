"""
Prequal Load Balancer Distributed Experiment

Topology:
  - 2 load balancers (Prequal vs Round-Robin) on dedicated nodes
  - 4 backend servers (2 with antagonist load, 2 clean)
  - 2 load generators
  - 1 observability node (Prometheus + Grafana)

Total: 9 physical nodes connected via experiment LAN.

Instructions:
  1. Wait for "Ready" status on all nodes (~5-10 min for boot + setup).
  2. SSH into the 'experiment' node (load generator role).
  3. cd /local/repository && ./run-experiment.sh
  4. Open Grafana on the obs node: http://<obs-public-ip>:3001 (admin/admin)
"""

import geni.portal as portal
import geni.rspec.pg as rspec

pc = portal.Context()
request = pc.makeRequestRSpec()

# -- Parameters (user-configurable from the CloudLab UI) -----------------------
pc.defineParameter(
    "hardware_type",
    "Hardware type for nodes",
    portal.ParameterType.NODETYPE,
    "d710",
    longDescription="Use d710 (Utah) for general experiments, or c220g5 (Wisconsin) for newer hardware."
)
pc.defineParameter(
    "repo_url",
    "Git repository URL with the loadbalancer code",
    portal.ParameterType.STRING,
    "https://github.com/YOUR_USERNAME/loadbalancer.git",
    longDescription="Replace with your fork URL containing the modified code."
)
pc.defineParameter(
    "repo_branch",
    "Git branch to checkout",
    portal.ParameterType.STRING,
    "cloudlab",
)

params = pc.bindParameters()

# -- Single LAN linking all experiment nodes -----------------------------------
lan = request.LAN("expLAN")
lan.bandwidth = 1000000  # 1 Gbps in Kbps; 0 means "best effort, no shaping"

# Standard Ubuntu 22.04 image.
UBUNTU_IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"

# -- Helper to create a node ---------------------------------------------------
def make_node(name, role, ip):
    n = request.RawPC(name)
    n.hardware_type = params.hardware_type
    n.disk_image = UBUNTU_IMAGE

    iface = n.addInterface("if0")
    iface.addAddress(rspec.IPv4Address(ip, "255.255.255.0"))
    lan.addInterface(iface)

    # The startup script runs once at boot, with the role as argument.
    n.addService(rspec.Execute(
        shell="bash",
        command="sudo -H bash /local/repository/cloudlab-setup.sh "
                + role + " "
                + params.repo_url + " "
                + params.repo_branch
                + " > /tmp/cloudlab-setup.log 2>&1"
    ))
    return n

# -- Define topology -----------------------------------------------------------
# IP plan (all on 10.10.1.0/24 experiment LAN):
#   10.10.1.10  obs        (Prometheus + Grafana)
#   10.10.1.11  lb-prequal
#   10.10.1.12  lb-rr
#   10.10.1.21  server-0   (antagonist heavy)
#   10.10.1.22  server-1   (antagonist heavy)
#   10.10.1.23  server-2   (clean)
#   10.10.1.24  server-3   (clean)
#   10.10.1.31  loadgen-0
#   10.10.1.32  loadgen-1

make_node("obs",        "obs",         "10.10.1.10")
make_node("lb-prequal", "lb-prequal",  "10.10.1.11")
make_node("lb-rr",      "lb-rr",       "10.10.1.12")
make_node("server-0",   "server-heavy","10.10.1.21")
make_node("server-1",   "server-heavy","10.10.1.22")
make_node("server-2",   "server-clean","10.10.1.23")
make_node("server-3",   "server-clean","10.10.1.24")
make_node("loadgen-0",  "loadgen",     "10.10.1.31")
make_node("loadgen-1",  "loadgen",     "10.10.1.32")

pc.printRequestRSpec(request)
