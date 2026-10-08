"""Source for docs/images/architecture.png.

Regenerate from the repo root (needs librsvg's rsvg-convert on PATH):
    uv run --with diagrams python docs/images/architecture.py

Every position is fixed by hand. A layout engine (Graphviz) clipped long labels
at group borders and left large gaps; placing things explicitly avoids both.
The `diagrams` package is used only for its copy of the official AWS icons.
"""
import base64
import subprocess
import tempfile
from html import escape
from pathlib import Path

import diagrams

ICONS = Path(diagrams.__file__).parent.parent / "resources" / "aws"
OUT = Path(__file__).with_suffix(".png")

W, H = 1720, 920
FONT = "Helvetica Neue, Helvetica, Arial, sans-serif"
INK, MUTED = "#232F3E", "#545B64"
IN, OUTB, CTRL = "#1D8102", "#E8710A", "#7D8998"

parts = []


def icon(rel, cx, cy, size=64):
    data = base64.b64encode((ICONS / rel).read_bytes()).decode()
    x, y = cx - size / 2, cy - size / 2
    parts.append(
        f'<image x="{x}" y="{y}" width="{size}" height="{size}" '
        f'href="data:image/png;base64,{data}"/>'
    )


def text(x, y, s, size=15, color=INK, anchor="middle", weight="normal"):
    # The white stroke painted under the glyphs keeps text legible where a
    # label sits across a group border or a line.
    parts.append(
        f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
        f'fill="{color}" text-anchor="{anchor}" font-weight="{weight}" '
        f'stroke="white" stroke-width="4" stroke-linejoin="round" '
        f'paint-order="stroke">{escape(s)}</text>'
    )


def node(rel, cx, cy, name, *details, backed=False):
    # Outline-style icons are transparent inside; a white disc stops the lines
    # and borders behind them showing through.
    if backed:
        parts.append(f'<circle cx="{cx}" cy="{cy}" r="34" fill="white"/>')
    icon(rel, cx, cy)
    text(cx, cy + 52, name)
    for i, d in enumerate(details):
        text(cx, cy + 70 + 17 * i, d, size=13, color=MUTED)


def group(x, y, w, h, label, stroke, fill="none", dashed=False, rel=None):
    dash = ' stroke-dasharray="8 5"' if dashed else ""
    parts.append(
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" '
        f'stroke="{stroke}" stroke-width="1.6"{dash}/>'
    )
    tx = x + 10
    if rel:
        icon(rel, x + 16, y + 16, size=32)
        tx = x + 40
    text(tx, y + 22, label, size=14, color=stroke, anchor="start", weight="bold")


def line(points, color, label=None, at=(0, 0), dashed=False, width=3.0):
    pts = " ".join(f"{x},{y}" for x, y in points)
    dash = ' stroke-dasharray="7 5"' if dashed else ""
    marker = {IN: "in", OUTB: "out", CTRL: "ctrl"}[color]
    parts.append(
        f'<polyline points="{pts}" fill="none" stroke="{color}" '
        f'stroke-width="{width}"{dash} marker-end="url(#{marker})"/>'
    )
    if label:
        lx, ly = at
        for i, s in enumerate(label.split("\n")):
            text(lx, ly + 16 * i, s, size=13, color=MUTED, anchor="start")


# Title
text(30, 48, "kiro-remote-crew", size=26, anchor="start", weight="bold")
text(30, 76, "One way in (SSM). One way out (fck-nat). Nothing listens.",
     size=15, color=MUTED, anchor="start")

# Groups, outermost first so inner fills paint on top
group(30, 100, 1390, 790, "AWS Region", "#147EBA", dashed=True)
group(290, 140, 860, 720, "VPC  10.20.0.0/16  ·  vpc.yaml", "#8C4FFF",
      rel="network/vpc.png")
group(315, 185, 810, 445, "Availability Zone a", "#147EBA", dashed=True)
group(340, 225, 420, 385, "Private subnet A  ·  10.20.128.0/20", "#00A4A6",
      fill="#E6F6F7", rel="network/private-subnet.png")
group(360, 270, 380, 320, "Security group  ·  zero ingress", "#DD3522",
      fill="#FFFFFF", dashed=True)
group(800, 225, 300, 385, "Public subnet A  ·  10.20.0.0/20", "#7AA116",
      fill="#F2F6E8", rel="network/public-subnet.png")
group(315, 655, 810, 180, "Availability Zone b  ·  wired, not live", "#147EBA",
      dashed=True)
group(340, 695, 420, 120, "Private subnet B  ·  10.20.144.0/20", "#00A4A6",
      fill="#F5FBFB", rel="network/private-subnet.png")
group(800, 695, 300, 120, "Public subnet B  ·  10.20.16.0/20", "#7AA116",
      fill="#F9FBF4", rel="network/public-subnet.png")
text(550, 775, "no resources", size=13, color=MUTED)
text(950, 775, "no resources", size=13, color=MUTED)
group(55, 505, 190, 355, "lifecycle.yaml", "#545B64", dashed=True)

# Edges first, so icons and labels sit on top of them
line([(1548, 166), (1324, 196)], IN, "start-session (HTTPS)", (1360, 158))
# SSM to host runs above AZ a's subnets and drops in right of every group
# label, so it crosses no text.
line([(1256, 200), (700, 200), (700, 334), (486, 334)], IN,
     "session, over the channel the agent opened", (790, 218))
line([(482, 350), (914, 350)], OUTB)
line([(986, 350), (1114, 350)], OUTB, "all egress,\nincl. SSM agent", (998, 310))
line([(1170, 326), (1252, 222)], OUTB, "SSM agent channel,\nopened outbound",
     (1222, 296))
line([(1184, 358), (1544, 414)], OUTB)
line([(182, 236), (416, 334)], CTRL, "instance profile", (196, 222),
     dashed=True, width=1.6)
line([(182, 406), (416, 486)], CTRL, "encrypts", (196, 398), dashed=True,
     width=1.6)
# The two lifecycle lines climb the gap between the AZ and subnet borders so
# they reach the host from the left instead of crossing its labels.
line([(182, 580), (322, 580), (322, 346), (414, 346)], CTRL, "start / stop",
     (196, 570), dashed=True, width=1.6)
line([(182, 740), (332, 740), (332, 362), (414, 362)], CTRL, "stop when idle",
     (196, 730), dashed=True, width=1.6)

# Nodes
node("security/identity-and-access-management-iam-role.png", 150, 230,
     "Instance role", "capped by a permissions", "boundary  ·  iam.yaml")
node("security/key-management-service.png", 150, 400, "KMS key", "kms.yaml")
node("integration/eventbridge-scheduler.png", 150, 580, "Scheduler",
     "start 08:00 ET", "stop 17:00 ET, Mon–Fri")
node("management/cloudwatch-alarm.png", 150, 740, "Idle alarm",
     "CPU < 3% for 15 min")
node("compute/ec2-instance.png", 450, 350, "Kiro Crew host", "m7g.2xlarge",
     "no public IP  ·  IMDSv2")
node("storage/elastic-block-store-ebs-volume.png", 450, 490, "Root volume",
     "60 GB gp3, encrypted")
node("compute/ec2-instance.png", 950, 350, "fck-nat",
     "EC2 t4g.nano + Elastic IP")
node("network/internet-gateway.png", 1150, 350, "Internet gateway", backed=True)
node("management/systems-manager.png", 1290, 200, "SSM", "Session Manager")
node("general/client.png", 1580, 160, "Developer laptop", "connect.sh")
node("general/internet-alt1.png", 1580, 420, "Internet",
     "packages  ·  git  ·  Kiro")

# Legend
lx, ly = 1450, 700
text(lx, ly, "Legend", size=14, anchor="start", weight="bold")
for i, (color, s, dashed) in enumerate([
    (IN, "the only way in", False),
    (OUTB, "the only way out", False),
    (CTRL, "control, not traffic", True),
]):
    y = ly + 28 + 26 * i
    dash = ' stroke-dasharray="7 5"' if dashed else ""
    parts.append(f'<line x1="{lx}" y1="{y - 5}" x2="{lx + 40}" y2="{y - 5}" '
                 f'stroke="{color}" stroke-width="3"{dash}/>')
    text(lx + 52, y, s, size=13, color=MUTED, anchor="start")
for i, s in enumerate([
    "Sessions ride back over the",
    "channel the SSM agent opened.",
    "Nothing connects inward.",
]):
    text(lx, ly + 120 + 17 * i, s, size=13, color=MUTED, anchor="start")


def marker(name, color):
    return (f'<marker id="{name}" viewBox="0 0 10 10" refX="9" refY="5" '
            f'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
            f'<path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>')


svg = (
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
    f'viewBox="0 0 {W} {H}"><defs>{marker("in", IN)}{marker("out", OUTB)}'
    f'{marker("ctrl", CTRL)}</defs>'
    f'<rect width="{W}" height="{H}" fill="white"/>{"".join(parts)}</svg>'
)

with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
    f.write(svg)
subprocess.run(["rsvg-convert", "--zoom", "1.5", "-o", str(OUT), f.name],
               check=True)
print(OUT)
