"""Source for docs/images/architecture.png.

Regenerate from the repo root (needs Graphviz):
    uv run --with diagrams python docs/images/architecture.py
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import Cloudwatch, SystemsManager
from diagrams.aws.network import InternetGateway
from diagrams.aws.security import IAMRole, KMS
from diagrams.aws.storage import EBS
from diagrams.generic.blank import Blank
from diagrams.onprem.client import User
from diagrams.onprem.network import Internet

OUT = Path(__file__).with_suffix("")

# Curved splines: the default orthogonal routing misplaces edge labels.
graph_attr = {
    "fontsize": "24",
    "labelloc": "t",
    "pad": "0.5",
    "nodesep": "0.6",
    "ranksep": "1.2",
    "splines": "spline",
}
EMPTY = {"fontsize": "11", "fontcolor": "gray50", "height": "0.4", "width": "1.6"}
IN = {"color": "darkgreen", "penwidth": "2"}
OUTBOUND = {"color": "darkorange", "penwidth": "2"}
CONTROL = {"color": "gray40", "style": "dashed"}

with Diagram(
    "kiro-remote-crew",
    filename=str(OUT),
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    laptop = User("Developer laptop\nconnect.sh\n(SSM port-forward :5476)")
    internet = Internet("Internet\npackages, git, Kiro")

    with Cluster("AWS region"):
        ssm = SystemsManager("SSM\nSession Manager")
        kms = KMS("KMS key\n(kms.yaml)")
        role = IAMRole("Instance role\ncapped by boundary\n(iam.yaml)")

        with Cluster("lifecycle.yaml"):
            schedule = Eventbridge("Scheduler\nstart 08:00 / stop 17:00 ET\nMon-Fri")
            alarm = Cloudwatch("Idle alarm\nCPU < 3% for 15 min\n-> stop")

        with Cluster("VPC 10.20.0.0/16 (vpc.yaml)"):
            igw = InternetGateway("Internet gateway")

            with Cluster("AZ a"):
                with Cluster("Private subnet A  10.20.128.0/20  (compute.yaml)"):
                    with Cluster("SG: zero ingress, no public IP, IMDSv2"):
                        box = EC2("Kiro Crew host\nm7g.2xlarge")
                        disk = EBS("60 GB gp3 root")
                with Cluster("Public subnet A  10.20.0.0/20"):
                    nat = EC2("fck-nat t4g.nano\n+ Elastic IP")

            with Cluster("AZ b (wired, not live)"):
                # Graphviz drops an empty cluster, so each holds a blank node.
                with Cluster("Private subnet B  10.20.144.0/20"):
                    Blank("empty", **EMPTY)
                with Cluster("Public subnet B  10.20.16.0/20"):
                    Blank("empty", **EMPTY)

    # The only way in: the developer opens a session through SSM. The host
    # never accepts an inbound connection; its SSM agent dialled out first.
    laptop >> Edge(label="start-session (HTTPS)", **IN) >> ssm
    ssm >> Edge(label="session over the\nagent's own channel", **IN) >> box

    # The only way out, shared by everything including the SSM agent.
    box >> Edge(**OUTBOUND) >> nat
    nat >> Edge(label="all egress,\nincl. SSM agent", **OUTBOUND) >> igw
    igw >> Edge(**OUTBOUND) >> internet
    igw >> Edge(label="SSM agent channel", **OUTBOUND) >> ssm

    box - Edge(**CONTROL) - disk
    kms >> Edge(label="encrypts", **CONTROL) >> disk
    role >> Edge(label="instance profile", **CONTROL) >> box
    schedule >> Edge(**CONTROL) >> box
    alarm >> Edge(**CONTROL) >> box
