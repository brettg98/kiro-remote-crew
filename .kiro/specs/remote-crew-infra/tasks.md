# Tasks — kiro-remote-crew

## Task 1: Restructure `infra/` to the five-template layout

- [x] Delete the three stubs (`boundary.yaml`, `network.yaml`, `host.yaml`).
- [x] Create five empty-scaffold templates: `iam.yaml`, `kms.yaml`, `vpc.yaml`, `compute.yaml`, `lifecycle.yaml` — each with `AWSTemplateFormatVersion`, `Description`, and a shared `TagPrefix` parameter (default `co`, `AllowedPattern: ^[a-z][a-z0-9]{0,15}$`).
- [x] Update `README.md` "What it builds" section to reference the five new template names.

_Requirements: 1, 2, 3, 6_

**Verification:** `infra/` contains exactly the five new `.yaml` files; old stubs gone; each template has `AWSTemplateFormatVersion` and `TagPrefix`; `README.md` references the new names.

---

## Task 2: Author `infra/iam.yaml` — boundary, roles, instance profile

- [x] **PermissionsBoundary** — managed policy `${TagPrefix}-kiro-remote-boundary`. Two statements: (a) `AmazonSSMManagedInstanceCore` action set, `Resource: *`; (b) `kms:Decrypt`/`GenerateDataKey*`/`CreateGrant` gated by `kms:ViaService = ec2.${AWS::Region}.amazonaws.com`.
- [x] **InstanceRole** — trusts `ec2.amazonaws.com`; attaches `AmazonSSMManagedInstanceCore`; `PermissionsBoundary` = boundary; inline KMS statement (same condition); tagged `${TagPrefix}:project = kiro-remote-crew`. No `s3:GetObject`, no `secretsmanager:GetSecretValue`.
- [x] **InstanceProfile** — wraps the role.
- [x] **SchedulerRole** — trusts `scheduler.amazonaws.com`; scoped to `ssm:StartAutomationExecution` on `AWS-Start/StopEC2Instance` + `ec2:Start/StopInstances`.
- [x] Parameters: `TagPrefix`, `Environment` (default `demo`), `Owner`.
- [x] Exports: `BoundaryArn`, `InstanceProfileArn`, `InstanceRoleArn`, `SchedulerRoleArn`.

_Requirements: 2.1, 2.2, 2.3, 2.4, 3.3, 5.1, 5.3_

**Verification:** `aws cloudformation validate-template`; boundary has exactly two statements; no S3/Secrets Manager grants; four exports present; `TagPrefix` interpolation correct in policy name + tag keys.

---

## Task 3: Author `infra/kms.yaml` — CMK with condition-based key policy

- [x] `AWS::KMS::Key` — `EnableKeyRotation: true`, `KeySpec: SYMMETRIC_DEFAULT`. Key policy: (a) account-root admin; (b) `kms:Decrypt`/`GenerateDataKey*`/`CreateGrant` conditioned on `kms:ViaService = ec2.<region>.amazonaws.com` AND `aws:PrincipalTag/${TagPrefix}:project = kiro-remote-crew`. No role ARN — breaks the circular import.
- [x] `AWS::KMS::Alias` — `alias/${TagPrefix}-kiro-remote-crew`.
- [x] Parameters: `TagPrefix`.
- [x] Exports: `CmkArn`, `CmkAlias`.

_Requirements: 3 (EBS encryption)_

**Verification:** Template validates; key policy uses `kms:ViaService` condition, NOT a role ARN; `aws:PrincipalTag` interpolates `TagPrefix`; no imports from `iam.yaml`.

---

## Task 4: Author `infra/vpc.yaml` — multi-AZ VPC, one AZ live, fck-nat

- [x] VPC `10.20.0.0/16`, DNS support + hostnames on.
- [x] InternetGateway + VPCGatewayAttachment.
- [x] Four subnets: `PublicSubnetA` (`10.20.0.0/20`, AZ-a), `PublicSubnetB` (`10.20.16.0/20`, AZ-b), `PrivateSubnetA` (`10.20.128.0/20`, AZ-a), `PrivateSubnetB` (`10.20.144.0/20`, AZ-b).
- [x] `PublicRouteTable` with `0.0.0.0/0 → IGW`, associated to both public subnets.
- [x] `PrivateRouteTableA` with `0.0.0.0/0 → fck-nat ENI`, associated to PrivateSubnetA.
- [x] `PrivateRouteTableB` local-only (no NAT), associated to PrivateSubnetB, inline comment documenting the AZ-b extension path.
- [x] `FckNatSecurityGroup` — ingress from VPC CIDR, egress all.
- [x] `FckNatInstance` — `t4g.nano`, fck-nat AMI via SSM public parameter, `SourceDestCheck: false`, PublicSubnetA, public IP.
- [x] Exports: `VpcId`, `VpcCidr`, `PrivateSubnetAId`, `PrivateSubnetBId`, `PublicSubnetAId`, `PublicSubnetBId`.

_Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

**Verification:** Template validates; 4 subnets in 2 AZs with distinct `/20` CIDRs; fck-nat has `SourceDestCheck: false`; PrivateRouteTableA → fck-nat ENI; PrivateRouteTableB has no default route; six exports.

---

## Task 5: Author `infra/compute.yaml` — instance, SG, WaitCondition

- [x] Parameters: `InstanceType` (default `m7g.2xlarge`), `Architecture` (arm64), `VolumeSizeGb` (60), `DashboardPort` (5476), `TagPrefix`, `Developer` (required, no default), `Environment`, `Owner`, `KirocrewRepo`/`KirocrewRef`. No `AllowSshCidr`, no `AssociatePublicIp` param.
- [x] Imports: `InstanceProfileArn`, `InstanceRoleArn` (iam), `CmkArn` (kms), `VpcId`, `PrivateSubnetAId` (vpc).
- [x] `InstanceSecurityGroup` — egress-all, zero ingress.
- [x] `Instance` — SSM-resolved AL2023 AMI via `ArchToAmiParam` mapping; `AssociatePublicIpAddress: false`; IMDSv2 required, hop limit 1; gp3 root encrypted with imported CMK; UserData: SELinux-reboot suppression, swap, SHA-pinned Node 22, musl kiro-cli, `git clone` install, dashboard build, systemd unit, health poll, `fail()` reporting. Tags: `Name = kiro-remote-crew-${Developer}` (capitalized, not prefixed), `${TagPrefix}:developer`, `${TagPrefix}:project`, etc.
- [x] `WaitHandle` + `WaitCondition` — `Count: 1`, `Timeout: 1500`.
- [x] Exports: `InstanceId`, `DashboardPort`.

_Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 4.1, 4.2, 4.3, 5.1, 5.2_

**Verification:** Template validates; no SSH param or ingress; `AssociatePublicIpAddress: false`; root volume uses imported CMK; IMDSv2 enforced; WaitCondition timeout 1500; UserData uses `git clone` not S3; `Name` tag capitalized and unprefixed; `Developer` has no default; `InstanceId` exported.

---

## Task 6: Author `infra/lifecycle.yaml` — schedule + idle auto-stop

- [x] Imports: `InstanceId` (compute), `SchedulerRoleArn` (iam).
- [x] Parameters: `TagPrefix`, `ScheduleEnabled` (default `true`), `StartCron`, `StopCron`, `ScheduleTimezone` (default `America/New_York`), `IdleStopEnabled` (default `true`), `IdleCpuThreshold` (default `3`), `IdlePeriods` (default `3`).
- [x] Conditions: `HasSchedule` (ScheduleEnabled=true), `HasIdleStop` (IdleStopEnabled=true).
- [x] `StartSchedule` + `StopSchedule` — `AWS::Scheduler::Schedule` targeting SSM `AWS-StartEC2Instance`/`StopEC2Instance` with imported InstanceId and scheduler role. Conditioned on `HasSchedule`.
- [x] `IdleAlarm` — `AWS::CloudWatch::Alarm` on `CPUUtilization < threshold` for `IdlePeriods × 5 min`, alarm action `arn:aws:automate:${AWS::Region}:ec2:stop`. Conditioned on `HasIdleStop`.

_Requirements: 6 (lifecycle)_

**Verification:** Template validates; schedules conditioned on `HasSchedule`; alarm conditioned on `HasIdleStop`; alarm action is native `ec2:stop` ARN (no Lambda); schedule targets reference SSM automation documents; imports resolve to correct export names.

---

## Task 7: Implement `scripts/deploy.sh`

- [x] Replace the stub. `set -euo pipefail`; accept `--profile`, `--region`, `--developer` (required — fail early), `--tag-prefix` (default `co`), `--instance-type`, `--environment`, `--owner`, `--no-schedule`, `--no-idle-stop`.
- [x] Preflight: check `aws` CLI + caller identity.
- [x] Deploy order: `iam → kms → vpc → compute → lifecycle`, each via `aws cloudformation deploy --no-fail-on-empty-changeset`. Pass `TagPrefix` + tagging params to all; `Developer` to compute; schedule/idle flags to lifecycle.
- [x] Surface WaitCondition failure reason from compute if rollback.
- [x] Print success summary with instance ID + `connect.sh` hint.

_Requirements: 6.1, 6.2, 6.5, 6.6_

**Verification:** `shellcheck` passes; `--developer` omission fails early with actionable message; `--profile`/`--region` passed through to every `aws` call; deploy order correct; no `exit 1` placeholder.

---

## Task 8: Implement `scripts/connect.sh`

- [x] Replace the stub. Resolve `InstanceId` from compute stack outputs.
- [x] `aws ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartPortForwardingSession --parameters portNumber=$DASHBOARD_PORT,localPortNumber=$LOCAL_PORT`.
- [x] Accept `--profile`, `--region`, `--local-port` (default 5476).
- [x] Preflight: SSM Session Manager plugin installed.

_Requirements: 6.3_

**Verification:** `shellcheck` passes; uses `AWS-StartPortForwardingSession`; resolves instance ID from stack outputs; no `exit 1` placeholder.

---

## Task 9: Create `scripts/start.sh` and `scripts/stop.sh`

- [x] **`start.sh`** — resolve InstanceId from compute stack, `aws ec2 start-instances`, wait for `instance-running` + SSM registration, print `connect.sh` hint.
- [x] **`stop.sh`** — resolve InstanceId, `aws ec2 stop-instances`, wait for `instance-stopped`.
- [x] Both accept `--profile`, `--region`; preflight `aws`; `chmod +x`.

_Requirements: 6 (lifecycle on-demand)_

**Verification:** `shellcheck` passes on both; instance ID from stack outputs; `start.sh` waits for running state; both executable.

---

## Task 10: Implement `scripts/teardown.sh`

- [x] Replace the stub. Delete `lifecycle` stack first, wait `DELETE_COMPLETE`. Delete `compute` stack second, wait `DELETE_COMPLETE`.
- [x] Print that iam/kms/vpc survive + how to delete manually.
- [x] Accept `--profile`, `--region`, `--yes` (skip confirmation).
- [x] Prompt for confirmation by default.

_Requirements: 6.4, 6.6_

**Verification:** `shellcheck` passes; deletes lifecycle then compute (order matters); does NOT delete iam/kms/vpc; prints full-cleanup guidance; no `exit 1` placeholder.

---

## Task 11: Rewrite `docs/prerequisites.md`

- [x] Tools: AWS CLI v2, SSM Session Manager plugin, bash, git.
- [x] "This build authors its own VPC — no default VPC needed."
- [x] Device-code login as the auth path — no API key required.
- [x] Remove stale `KIRO_API_KEY` prerequisite language.
- [x] Graviton/arm64 default, 16 GB RAM floor.

_Requirements: 7.1, 5.2_

**Verification:** No `KIRO_API_KEY` as a prerequisite; device-code login documented; all tools listed; "no default VPC."

---

## Task 12: Rewrite `docs/architecture.md`

- [x] Five-template layout with deploy-order diagram.
- [x] Network: multi-AZ VPC, one AZ live, fck-nat, SSM-only tradeoff.
- [x] Permissions boundary: two-statement ceiling, circular-protection rationale.
- [x] CMK: condition-based key policy, why it breaks the circular import.
- [x] Lifecycle: three mechanisms, failure modes, "stopped box costs nothing."
- [x] Instance tier table with stop/start weekday pricing.
- [x] `KIRO_API_KEY` — described as optional production extension, never wired.
- [x] Tagging strategy with `TagPrefix` parameterization.

_Requirements: 7.2, 5.5_

**Verification:** Five templates described; `KIRO_API_KEY` is "described, never wired"; tier table includes stop/start pricing; CMK circular-import explanation present; all three lifecycle mechanisms covered.

---

## Task 13: Rewrite `docs/verification.md`

- [x] Ordered checklist: (1) five stacks `CREATE_COMPLETE`; (2) `describe-instance-information`; (3) `describe-volumes` — encrypted with CMK not `aws/ebs`; (4) `connect.sh` — dashboard loads; (5) device-code login via SSM; (6) run a query on the box; (7) tag roster query; (8) stop/start re-verify steps 2, 4, 6; (9) lifecycle checks — idle alarm, `start.sh` recovery, schedule invocation.

_Requirements: 7.3, 4.3_

**Verification:** Includes CMK check, stop/start re-verify, tag roster, lifecycle checks.

---

## Task 14: Update `README.md` for the final state

- [x] Quickstart: `deploy.sh --developer <you>` → `connect.sh` → `teardown.sh`.
- [x] "What it builds" — five stacks with one-line descriptions.
- [x] Cost: balanced `m7g.2xlarge` ~$57/mo weekday stop-start, fck-nat ~$3/mo, CMK ~$1/mo.
- [x] Security claim: zero inbound, no SSH, IAM + CloudTrail.
- [x] Links to prerequisite, architecture, verification docs.

_Requirements: 7.4, 7.5_

**Verification:** Quickstart shows `--developer`; five stacks listed; cost includes CMK + fck-nat; no TODO/placeholder markers.

---

## Task 15: Final audit — no placeholders, cross-template consistency

- [x] Grep all files for `TODO`, `FIXME`, `PLACEHOLDER`, `exit 1`.
- [x] Verify every `Export` name used in an `Fn::ImportValue` exists in the source template.
- [x] Verify `TagPrefix` parameter in all five templates with identical definition.
- [x] `shellcheck` on all scripts.
- [x] `chmod +x` on all scripts.
- [x] Confirm zero instances of `AllowSshCidr`, `s3:GetObject`, `secretsmanager:GetSecretValue`.

_Requirements: 7.5, 2.1, 3.2, 5.1, 5.3_

**Verification:** Zero placeholder matches; all export/import names align; `TagPrefix` consistent; `shellcheck` clean; all scripts executable; no SSH or secret-store references.
