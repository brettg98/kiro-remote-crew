# Architecture

## The claim

No public IP, no inbound rules, no SSH key. Access is over AWS SSM Session
Manager, so **IAM decides who connects and CloudTrail records it**. Nothing
initiates into the VPC — the host has no public IP and its security group has
zero ingress rules.

## Five stacks, wired by cross-stack references

The project is five CloudFormation templates joined by `Export` /
`Fn::ImportValue` (not nested stacks). The import dependency enforces the deploy
order and blocks unsafe teardown automatically.

| Template | Holds | Depends on |
|---|---|---|
| `infra/iam.yaml` | Permissions boundary, instance role + profile, scheduler role | — (deploy first) |
| `infra/kms.yaml` | Customer-managed CMK + key policy for EBS encryption | — (independent) |
| `infra/vpc.yaml` | VPC, IGW, multi-AZ subnets (one AZ live), route tables, fck-nat | — (independent) |
| `infra/compute.yaml` | EC2 instance, security group, WaitCondition | imports iam + kms + vpc |
| `infra/lifecycle.yaml` | Business-hours schedule, idle-stop alarm | imports compute + iam |

Deploy order: **`iam → kms → vpc → compute → lifecycle`**. Teardown removes
`lifecycle` then `compute`; `iam`, `kms`, `vpc` (and the fck-nat) persist so the
box is cheap to recreate.

## Network

Explicit VPC (`10.20.0.0/16`), authored across **two AZs** so it is
production-shaped from day one — but only AZ-a is live in V1. The public subnet
holds a single **fck-nat** (`t4g.nano`, ~$3/mo) for egress; the workload lives in
a **private** subnet with no public IP and routes out through the NAT. AZ-b's
subnets are real (not commented blocks), so a later multi-AZ extension is
additive: drop a second fck-nat in `PublicSubnetB` and add a default route to
`PrivateRouteTableB`.

Egress is genuinely needed at boot (dnf/pip + a ~900-package npm build + the
~600 MB kiro-cli archive), which SSM VPC endpoints alone would not cover — so the
NAT is load-bearing, not decorative.

**fck-nat AMI.** fck-nat does not publish an SSM public parameter, so `vpc.yaml`
takes the AMI as an `AWS::EC2::Image::Id` parameter (`FckNatAmiId`) and
`deploy.sh` resolves the latest for the region before deploying — an
`aws ec2 describe-images` lookup by owner `568608671756` and name
`fck-nat-al2023-*-arm64-ebs`, newest by creation date (per
[the fck-nat docs](https://fck-nat.dev/stable/deploying/)). If fck-nat does not
publish in the target region the deploy fails early with that message rather than
mid-stack.

**Honest tradeoff:** SSM is the **only** door, and it reaches the box *through*
the fck-nat. If the NAT dies, the host goes dark. The box is disposable —
recreate the compute stack (the network stack is separate for exactly this).
Decoupling would use SSM interface VPC endpoints (~$22/mo, more than the fck-nat);
not built here, stated as future work.

## The permissions boundary

The instance role can, at most, (a) register with SSM Session Manager and (b) use
the CMK for its own EBS volume — enforced by a **permissions boundary** (a
ceiling, not a grant). It carries **no** `s3:GetObject` and **no**
`secretsmanager:GetSecretValue`: the box installs by public `git clone` and
authenticates by device-code login, so it needs neither.

The boundary is created in `infra/iam.yaml`, deployed first — deliberately by an
admin, separately from the role — so the protection can't be circular. Even a
leaked deploy credential that inlines admin onto the role is capped to the
intersection of the role's policy and the boundary.

## The CMK, and the circular-import trap

`infra/kms.yaml` provisions a customer-managed CMK (`EnableKeyRotation: true`) for
EBS root-volume encryption. The obvious design deadlocks under cross-stack
imports: the key policy would name the instance-role ARN (import from iam) while
the role would need the CMK ARN for its `kms:Decrypt` grant (import from kms) — a
circular `Fn::ImportValue`.

We break it so **neither template imports the other**:

- The **key policy** grants EBS use by *condition*, not by principal ARN: any
  principal in this account carrying `${TagPrefix}:project = kiro-remote-crew`,
  acting *through* EC2 (`kms:ViaService = ec2.<region>.amazonaws.com`), may use
  the key.
- The **instance role** carries a matching inline `kms` statement scoped to
  `Resource: *` under the same `kms:ViaService` condition.
- The **boundary** must also permit those `kms` actions under the same condition,
  or the effective-permission intersection would strip them and the volume would
  silently fail to attach.

So three places — key policy, role, boundary — must agree on the `kms:ViaService`
condition, and the instance-role tag must match the key policy's
`aws:PrincipalTag` condition. A concrete "these must line up" lesson; get one
wrong and the box fails to launch with an opaque volume-attach error. ~$1/mo.

## Auth: device-code only

After the compute stack reaches `CREATE_COMPLETE`, the gateway is healthy but not
signed in. `connect.sh` opens the SSM port-forward, the dashboard shows "not
signed in", and a second SSM session runs the kiro-cli device-code login (URL +
code, approved in your browser once). The token persists on the CMK-encrypted EBS
volume — it survives a **stop/start** but not a **rebuild** (a fresh instance
requires logging in again).

> **Production extension (described, never shipped):** to run unattended you would
> add a `KIRO_API_KEY` in Secrets Manager, grant the role a scoped
> `secretsmanager:GetSecretValue`, and read it in UserData. That is a paid-tier
> path with a stored credential and failure modes spread across Secrets Manager +
> IAM + region config — the wrong thing to hand a zero-support user, so it is
> documented here and never wired into the templates.

## Lifecycle: three opt-out controls

Everything that keeps the box from running idle lives in `infra/lifecycle.yaml`
(split out so the schedule/idle policy edits and tears down without touching the
instance). All three are opt-out; you can always take manual control.

1. **Business-hours schedule** — EventBridge Scheduler starts the box at
   `cron(0 8 ? * MON-FRI *)` and stops it at `cron(0 17 ? * MON-FRI *)`
   (America/New_York), targeting the AWS-managed SSM `AWS-Start/StopEC2Instance`
   automation via the scheduler role. The 5 PM stop is the hard backstop.
2. **CPU idle-stop** — a CloudWatch alarm on `CPUUtilization < 3%` for 3×5 min
   (15 minutes) with a native **EC2 stop action** (no Lambda, no code on the box).
   CPU is the right idle signal because Kiro Crew's real work (sub-agent
   concurrency) is CPU-bound: an idle dashboard connection barely moves CPU, while
   an active chat or running sub-agent holds the box up. Known edge: a long, quiet,
   single-threaded wait could dip under the floor — raise `IdlePeriods` if you hit
   it. A stopped box costs nothing and restarts in ~1 min, so the failure mode is
   cheap.
3. **On-demand** — `scripts/start.sh` / `scripts/stop.sh` park and un-park the box
   in one command. `start.sh` waits for the instance to run and re-register with
   SSM before printing the connect hint.

Opt out per-mechanism (`--no-schedule`, `--no-idle-stop`), or don't deploy
`lifecycle.yaml` at all — the cleanest opt-out.

## Tagging

Customer-prefixed lowercase keys. The prefix is a **`TagPrefix` parameter**
(default `co`, `AllowedPattern ^[a-z][a-z0-9]{0,15}$`) present in **all five**
templates — so a fork can retag to its own namespace, and, critically, so the CMK
key-policy condition and the instance-role tag stay in lockstep. `TagPrefix` is a
parameter (not a cross-stack import) because a stack tag must be known at each
stack's own deploy time; `deploy.sh` passes the same `--tag-prefix` to all five.

`Developer` is a **required** parameter on `compute.yaml` — deploy fails without
it — and drives both `${TagPrefix}:developer` and the `Name` tag
(`kiro-remote-crew-<Developer>`). The `Name` key stays capitalized and unprefixed
because it is the AWS-reserved console label. Roster query (default prefix):

```
aws ec2 describe-instances \
  --filters "Name=tag:co:project,Values=kiro-remote-crew" \
  --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='co:developer']|[0].Value,State.Name]" \
  --output table
```

→ every box, its assigned developer, and running/stopped state in one command.

## Instance tiers

| tier | type | vCPU/GB | ~$/mo 24×7 | ~$/mo weekday stop-start |
|------|------|---------|-----------|--------------------------|
| light | t4g.xlarge | 4/16 | ~96 | ~23 |
| balanced | m7g.2xlarge | 8/32 | ~235 | **~57** |
| power | m7g.4xlarge | 16/64 | ~470 | ~114 |

16 GB floor: Kiro Crew uses ~10 GB with spikes. Tiers ladder by vCPU because
sub-agent concurrency is CPU-bound. `m7g.2xlarge` on a weekday stop/start schedule
(the default) lands around **$57/mo**, plus ~$3/mo for the fck-nat and ~$1/mo for
the CMK.
