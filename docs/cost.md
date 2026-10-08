# Cost

The bill has two parts. Some resources bill every hour whether you use the box
or not. The crew instance bills only while it runs.

Prices are on-demand, USD, for **ca-central-1**, taken from the AWS Price List
API in October 2026. Other regions differ, so re-price before you rely on these.

## Fixed: billed every hour

These keep billing while the crew box is stopped. Stopping the box removes the
instance charge and nothing else.

| item | rate | $/mo |
|------|------|------|
| fck-nat instance (`t4g.nano`) | $0.0046/h | 3.36 |
| fck-nat Elastic IP (public IPv4) | $0.005/h | 3.65 |
| crew root volume (60 GB gp3) | $0.088/GB-mo | 5.28 |
| fck-nat root volume (4 GB gp3, from the AMI) | $0.088/GB-mo | 0.35 |
| KMS key for EBS encryption | $1/key-mo, +$1 per rotation, capped at 2 | 1.00 → 3.00 |
| **total** | | **13.64 → 15.64** |

The KMS key has automatic rotation on (`kms.yaml`). Each of the first two
yearly rotations adds $1/mo, so the key costs $1 in year 1, $2 in year 2 and $3
from year 3. KMS request charges are fractions of a cent.

The gp3 volumes use the free baseline (3,000 IOPS, 125 MiB/s), so there is no
IOPS or throughput charge. A larger `VolumeSizeGb` adds $0.088 per GB-month.

## Variable: the crew instance

**instance cost = hourly rate × hours running**

| type | rate | light (~87 h) | schedule ceiling (~196 h) | always on (730 h) |
|------|------|---------------|---------------------------|-------------------|
| `t4g.xlarge` | $0.1472/h | 12.81 | 28.81 | 107.46 |
| `m7g.2xlarge` (default) | $0.3638/h | 31.65 | 71.21 | 265.57 |
| `m7g.4xlarge` | $0.7277/h | 63.31 | 142.45 | 531.22 |

- **Light** is about 4 hours a day on weekdays, with the idle-stop alarm
  catching the rest. It is an illustration, not a measurement. Your hours depend
  on how long your agents actually work.
- **Schedule ceiling** is the `lifecycle.yaml` default: 08:00–17:00
  America/New_York, Monday to Friday, never idle. That is 9 h × 21.75 weekdays.
  The schedule also runs on public holidays.
- **Always on** is 730 hours, with the lifecycle stack not deployed.

## Total for the default build

Fixed (year 1) plus an `m7g.2xlarge`:

| usage | $/mo |
|-------|------|
| light | ~45 |
| schedule ceiling | ~85 |
| always on | ~279 |

## Not included

- **Data transfer out to the internet**: $0.09/GB after the AWS free tier. Git
  pulls, package installs and model calls are mostly inbound and small. A heavy
  outbound workload could notice it.
- **CloudWatch and EventBridge Scheduler**: one alarm and two schedules, within
  the free tiers for a single box.

## Choices this build makes on cost

| alternative | $/mo | built instead |
|-------------|------|---------------|
| managed NAT Gateway | 36.50 + $0.05/GB processed | fck-nat + Elastic IP, 7.01 + its volume |
| SSM interface endpoints (`ssm`, `ssmmessages`, `ec2messages`) | 8.03 each per AZ, ~24 for one AZ | SSM through the fck-nat |
