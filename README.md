# kiro-remote-crew

Run [Kiro Crew](https://kiro.dev) on a remote AWS EC2 instance and drive it from
your laptop — the agent work executes on the box, not on your Mac. No public IP,
no SSH key, no open inbound ports: access is over AWS SSM Session Manager, so IAM
decides who connects and CloudTrail records it.

Companion build for the *Let's Build* video. Recorded walkthrough, hand-built so
you can see how the remote mechanism actually works, then the one-command version.

## What it builds

Five CloudFormation stacks, wired by cross-stack `Export` / `Fn::ImportValue`
(not nested stacks — the import dependency enforces deploy order automatically):

- **`infra/iam.yaml`** — the permissions boundary (an immutable ceiling, created
  by an admin as the first stack), the instance role + profile capped by it, and
  the scheduler role `lifecycle.yaml` uses. Two effective grants only: SSM
  Session Manager and EBS-volume KMS use — no S3, no Secrets Manager.
- **`infra/kms.yaml`** — a customer-managed CMK for EBS root-volume encryption.
  Its key policy grants use by `kms:ViaService` **condition** rather than by
  naming the role ARN, so it never imports from `iam.yaml` (breaking what would
  otherwise be a circular cross-stack dependency).
- **`infra/vpc.yaml`** — an explicit VPC (never the default) authored across two
  AZs with only AZ-a live, and a single [fck-nat](https://fck-nat.dev) instance
  (~$3/mo vs ~$32/mo for a managed NAT Gateway) for private egress.
- **`infra/compute.yaml`** — the EC2 host in the **private** subnet (no public
  IP, egress-only security group, IMDSv2 enforced, CMK-encrypted root), reached
  only over SSM. A WaitCondition fails the stack loudly with the setup-log tail
  if bootstrap breaks.
- **`infra/lifecycle.yaml`** — auto-shutdown, all opt-out: a business-hours
  start/stop schedule, a CloudWatch CPU idle-stop alarm, and the on-demand
  `start.sh`/`stop.sh` scripts. Deploy last (it imports the instance id); simply
  not deploying it is the cleanest opt-out.

Deploy order — `iam → kms → vpc → compute → lifecycle` — is enforced by the
cross-stack imports.

## Quickstart

See [`docs/prerequisites.md`](docs/prerequisites.md), then:

```bash
scripts/deploy.sh --developer alice   # iam -> kms -> vpc -> compute -> lifecycle
scripts/connect.sh                     # SSM port-forward from your laptop
scripts/stop.sh                        # park the box (or let the schedule/idle alarm)
scripts/start.sh                       # un-park it (~1 min)
scripts/teardown.sh                    # remove lifecycle + compute (iam/kms/vpc survive)
```

`--developer` is required — it tags and names the box so a fleet is one
`describe-instances` query away. All scripts accept `--profile`, `--region`, and
`--tag-prefix`. After `deploy.sh`, do the one-time device-code login on the box
(see [`docs/verification.md`](docs/verification.md)).

Running Kiro Crew on your laptop as well? Add the box as a remote instance
instead of using `connect.sh`: see
[`docs/local-kiro-crew.md`](docs/local-kiro-crew.md), including the SSO-expiry
error that `assume` does not fix.

## Cost

A balanced box (`m7g.2xlarge`, 8 vCPU / 32 GB) with stop/start on weekdays is
roughly **$57/month**, plus ~**$3/mo** for the fck-nat and ~**$1/mo** for the CMK.
See [`docs/architecture.md`](docs/architecture.md) for the full tier table and the
security/lifecycle rationale.

## License

MIT — see [LICENSE](LICENSE).
