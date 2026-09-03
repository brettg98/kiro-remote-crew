# Prerequisites

## Tools

- **AWS CLI v2**, with the **SSM Session Manager plugin** installed
  ([install guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)).
- **bash** and **git** (to clone this repo and run the scripts).

## AWS account

- An AWS account you control. **This build authors its own VPC — it never uses
  the default VPC**, so you do not need one, but you do need permission to create
  VPC/EC2/IAM/KMS/CloudWatch/Scheduler resources.
- One **admin step, once**: the permissions boundary in `infra/iam.yaml` is meant
  to be created by an admin as the first stack — it is the immutable ceiling the
  host role is capped by. `scripts/deploy.sh` deploys it idempotently, so a
  re-run is a no-op.

## Kiro

- **Any Kiro tier works.** The remote authenticates with the ordinary
  **device-code login** — you open an SSM session to the box, run the login, and
  approve the URL + code in your own browser once per fresh instance. No API key,
  no stored credential on the box.
- Kiro CLI does **not** need a Bedrock or Anthropic credential — it authenticates
  to Kiro's own managed service. The instance role is therefore scoped to SSM +
  its own EBS-volume KMS use, nothing else.
- The remote runs a **full Kiro Crew install**, not just Kiro CLI.

> Want the box to run unattended (no interactive login)? That is a `KIRO_API_KEY`
> extension you add and own yourself — see `docs/architecture.md`. It is
> described there, never wired into the shipped templates.

## Architecture / instance

- **Graviton (arm64) is the default** (`m7g.2xlarge`, 8 vCPU / 32 GB). The
  installer pulls the matching aarch64 builds. x86_64 works too — pass
  `--instance-type` with an x86 type and the AMI map follows.
- **16 GB RAM floor.** Kiro Crew uses ~10 GB with spikes; smaller boxes thrash.
  See the tier table in `docs/architecture.md`.
