# Requirements — kiro-remote-crew

## Overview

A public, self-contained reference project that lets any AWS-account owner stand
up a **Kiro Crew agent running on a remote EC2 instance** and drive it from their
own laptop. All AWS infrastructure is authored as CloudFormation (no default VPC,
no console clicking). Access to the remote is over AWS SSM Session Manager only —
no public IP, no SSH key, no open inbound ports. The deliverable is a working
solution a first-time viewer can clone and deploy end-to-end by following the
README, plus the teaching narrative for the *Let's Build* episode it accompanies.

Success = a clone-and-run experience: `scripts/deploy.sh` produces a healthy
remote gateway, `scripts/connect.sh` surfaces its dashboard on the laptop, a query
executes on the box, and `scripts/teardown.sh` removes it — with the security
posture ("IAM decides who connects, CloudTrail records it") being literally true.

## Scope boundaries

- **In scope (V1):** the three CloudFormation templates, the three orchestration
  scripts, the supporting docs, and a repeatable verification path.
- **Out of scope (V1):** SSH access of any kind, Tailscale, SSM interface VPC
  endpoints, AZ-redundant dual-NAT, multi-region, and CI/CD to deploy the stacks.
  These are named as future work in docs, not built.

---

## Requirement 1 — Author an explicit network (never a default VPC)

**User story:** As an account owner, I want the project to create its own VPC so
that the remote host runs in a network I fully control, with a documented cheap
egress path.

**Acceptance criteria:**
1. WHEN `infra/network.yaml` is deployed THE SYSTEM SHALL create a VPC, an
   Internet Gateway with attachment, one public subnet, one private subnet, and a
   public + private route table.
2. WHEN the network stack is deployed THE SYSTEM SHALL place a single fck-nat
   instance (`t4g.nano`) in the public subnet and point the private route table's
   default route at that instance's ENI.
3. THE SYSTEM SHALL NOT use the account's default VPC, and SHALL NOT assign a
   public IP to the private subnet or its workload.
4. WHEN the network stack completes THE SYSTEM SHALL export `VpcId` and the
   private `SubnetId` for `host.yaml` to consume.
5. THE SYSTEM SHALL include the AZ-redundant second-NAT resources as commented-out
   template blocks with a note explaining the tradeoff, without deploying them.

## Requirement 2 — A permissions boundary as an immutable ceiling

**User story:** As an account owner, I want the host's IAM role capped by a
boundary created separately from the role, so that even a leaked deploy credential
cannot widen what the box can do.

**Acceptance criteria:**
1. WHEN `infra/boundary.yaml` is deployed THE SYSTEM SHALL create a managed policy
   whose only effective permissions are (a) the AmazonSSMManagedInstanceCore
   action set and (b) `s3:GetObject` scoped to the launcher bootstrap bucket.
2. THE SYSTEM SHALL keep the boundary in its own template, deployable by an admin
   as a one-time step BEFORE the host stack, and referenced by `host.yaml` only by
   ARN parameter.
3. WHEN the host role is created THE SYSTEM SHALL attach the boundary ARN as the
   role's `PermissionsBoundary`, so the role's effective permissions are the
   intersection of its inline policy and the boundary.
4. IF a caller attempts to attach broader permissions to the host role THEN the
   boundary SHALL still cap the role's effective permissions to SSM + the scoped
   object read.
5. THE SYSTEM SHALL deploy the boundary idempotently — a second `deploy.sh` run
   SHALL skip boundary creation when it already exists.

## Requirement 3 — SSM-only host in a private subnet

**User story:** As an account owner, I want the Kiro Crew host to have no public
IP and no inbound rules, so that the only way to reach it is an
IAM-authorized SSM session.

**Acceptance criteria:**
1. WHEN `infra/host.yaml` is deployed THE SYSTEM SHALL launch one EC2 instance in
   the private subnet with `AssociatePublicIpAddress: false`.
2. THE SYSTEM SHALL attach a security group with **egress only** and **zero
   ingress rules**, and SHALL NOT define an `AllowSshCidr` parameter or any SSH
   ingress resource.
3. THE SYSTEM SHALL attach an instance profile whose role trusts EC2, carries the
   `AmazonSSMManagedInstanceCore` managed policy, and sets the boundary ARN as its
   permissions boundary.
4. THE SYSTEM SHALL select the AMI via `{{resolve:ssm:...}}` against an
   architecture map (arm64 by default), so no AMI ID is hard-coded.
5. WHEN the instance boots THE SYSTEM SHALL run UserData that installs a full Kiro
   Crew install plus kiro-cli and registers the gateway as a systemd unit (so it
   survives a stop/start, not just first boot).
6. THE SYSTEM SHALL expose `InstanceId` and `Region` as stack outputs.

## Requirement 4 — Fail loudly on a broken bootstrap

**User story:** As an account owner, I want a failed bootstrap to fail the stack
with the reason attached, so that I never get a "green" stack hiding a dead
gateway.

**Acceptance criteria:**
1. THE SYSTEM SHALL include a WaitHandle + WaitCondition that only signals success
   once the Kiro Crew gateway reports healthy.
2. IF bootstrap fails or times out THEN the stack SHALL roll back and surface the
   tail of the setup log as the failure reason.
3. THE SYSTEM SHALL treat stack `CREATE_COMPLETE` as the single health gate — a
   completed host stack means a reachable, healthy gateway.

## Requirement 5 — Manual device-code authentication to Kiro's service

**User story:** As an account owner, I want the remote to authenticate to Kiro
with the same device-code login I'd do on any machine, driven once over SSM, so
that setup works on any Kiro tier and the box holds no stored credential.

**Rationale:** This is a zero-support public project. The device-code path works
on the free tier, stores no secret, and fails legibly ("not logged in → run the
login again") — so a stranger can self-serve it. An unattended `KIRO_API_KEY`
path is deliberately NOT wired into the templates: it requires a paid tier, adds a
credential on the repo's happy path, and spreads its failure modes across
Secrets Manager + IAM + region config, which is the worst thing to hand a user
with no one to ask.

**Acceptance criteria:**
1. THE SYSTEM SHALL NOT require or grant `bedrock:InvokeModel` or any
   Anthropic/model-provider credential to the host — Kiro CLI authenticates to
   Kiro's managed service.
2. THE SYSTEM SHALL make device-code login the single documented and wired auth
   path: the user opens an SSM session to the host, runs the login, and completes
   the URL + code in their own browser once per fresh instance.
3. THE SYSTEM SHALL NOT provision a Secrets Manager secret, and the host role
   SHALL NOT be granted `secretsmanager:GetSecretValue` — no credential plumbing
   exists in `boundary.yaml` or `host.yaml`.
4. THE README and `docs/verification.md` SHALL state that the device-code token
   survives a **reboot** but not a **rebuild** (a fresh instance requires logging
   in again), and place the login step explicitly in the connect/verify flow.
5. THE `docs/architecture.md` SHALL describe `KIRO_API_KEY` (Secrets Manager +
   scoped `GetSecretValue`) as an optional "how you'd make this unattended in
   production" extension the user would add and own themselves — described only,
   never wired into the shipped templates.

## Requirement 6 — One-command deploy, connect, teardown

**User story:** As an account owner, I want three scripts that orchestrate the
lifecycle, so that I can go from clone to a working remote crew and back without
memorizing CloudFormation commands.

**Acceptance criteria:**
1. WHEN a user runs `scripts/deploy.sh` THE SYSTEM SHALL deploy in order —
   boundary (skipped if present) → network → host — passing the network stack's
   `VpcId`/`SubnetId` and the boundary ARN into `host.yaml`.
2. THE SYSTEM SHALL accept `--profile` and `--region` (or documented environment
   variables) on all three scripts and pass them through to every AWS call.
3. WHEN a user runs `scripts/connect.sh` THE SYSTEM SHALL open an SSM
   port-forward from the laptop to the remote dashboard port, using only
   `ssm:StartSession` (no SSH, no inbound port).
4. WHEN a user runs `scripts/teardown.sh` THE SYSTEM SHALL delete the **host**
   stack only, leaving the network stack (and its fck-nat) intact so the host is
   disposable and cheap to recreate.
5. IF a required tool or credential is missing (AWS CLI, SSM Session Manager
   plugin, valid profile) THEN a script SHALL fail early with an actionable
   message rather than a partial deploy.
6. THE SYSTEM SHALL replace every stub script's `exit 1` placeholder with a real,
   idempotent implementation.

## Requirement 7 — Documentation a first-time viewer can follow

**User story:** As a first-time viewer, I want prerequisites, architecture, and a
verification checklist, so that I understand what I'm building and can prove it
works.

**Acceptance criteria:**
1. THE `docs/prerequisites.md` SHALL list every tool, permission, and Kiro tier
   requirement, and SHALL state that the build authors its own VPC.
2. THE `docs/architecture.md` SHALL explain the network, the permissions boundary,
   the SSM-only tradeoff (NAT is the single door), and the instance tier table
   with the 16 GB RAM floor rationale.
3. THE `docs/verification.md` SHALL give an ordered checklist ending in a
   **stop/start-then-reverify** step that catches the user-data-vs-systemd split.
4. THE `README.md` SHALL present the quickstart (`deploy` → `connect` →
   `teardown`), a cost summary, and the honest security claim ("zero inbound, no
   SSH key; IAM decides who connects and CloudTrail records it").
5. THE SYSTEM SHALL contain no placeholders or TODO markers in any shipped
   template, script, or doc once complete.
