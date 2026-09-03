# Verification

An ordered checklist to prove the build actually works. Substitute your
`--profile` / `--region` (and `--tag-prefix` if you changed it) throughout.

1. **All five stacks `CREATE_COMPLETE`.** `scripts/deploy.sh --developer <you>`
   returns cleanly. The compute stack's WaitCondition only signals when the
   gateway is healthy, so a green compute stack is the real gate — a failed
   bootstrap rolls back with the tail of the setup log as the reason.

2. **SSM sees the box.**
   ```
   aws ssm describe-instance-information \
     --filters "Key=tag:co:project,Values=kiro-remote-crew"
   ```
   `PingStatus: Online` proves boot + SSM agent + role + egress (through the
   fck-nat) in one command.

3. **Root volume is CMK-encrypted, not `aws/ebs`.**
   ```
   aws ec2 describe-volumes \
     --filters "Name=tag:co:project,Values=kiro-remote-crew" \
     --query "Volumes[].[VolumeId,Encrypted,KmsKeyId]" --output table
   ```
   `Encrypted: True` with the CMK's ARN (the `alias/co-kiro-remote-crew` key),
   not the account default `aws/ebs`.

4. **Authenticate the remote crew (configure it before you connect).** The box
   boots healthy but signed out — the gateway serves the dashboard, but the agent
   can't run until kiro-cli has a token. This step needs only a **plain SSM shell
   session**, not the port-forward:
   ```
   aws ssm start-session --target <instance-id>
   ```
   On the box, run the kiro-cli device-code login. The box has no browser, so the
   `--use-device-flow` flag is required — it prints a URL + code instead of trying
   to open one. You'll first choose your identity provider (Builder ID, Google,
   GitHub, or your Organization), then approve the URL + code in your browser:
   ```
   sudo -u ec2-user bash -l
   kiro-cli login --use-device-flow
   ``` The token is written to kiro-cli's store on the
   CMK-encrypted EBS volume, so it survives a stop/start (but not a rebuild —
   step 8). Do this first: connecting before it is done only ever shows you a
   "not signed in" page.

5. **Connect and use it — and prove the work ran on the box.**
   `scripts/connect.sh` opens the SSM port-forward: it binds a local port on your
   laptop and tunnels it to the port the Kiro Crew **gateway** on the EC2 host is
   listening on. Open `http://localhost:<local-port>/` — that is the **remote
   gateway's own web dashboard**, served from the box and proxied over the tunnel
   (not a local install). Because you authenticated in step 4, it loads signed-in
   and ready.

   Run a prompt — but the page loading over the tunnel does not by itself prove
   the agent's tools execute on EC2 rather than on your laptop (a local install
   would look identical). So ask the agent something only the box can answer:

   > Run `hostname` and fetch the instance id from IMDS: get a token with
   > `TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H
   > 'X-aws-ec2-metadata-token-ttl-seconds: 60')`, then
   > `curl -s -H "X-aws-ec2-metadata-token: $TOKEN"
   > http://169.254.169.254/latest/meta-data/instance-id`. Show me both.

   The instance-id must equal the `InstanceId` from the compute stack (and
   `hostname` is the EC2 private-DNS name, not your Mac). IMDS
   (`169.254.169.254`) is reachable only from *on* the instance — a laptop has no
   such endpoint — so a correct instance-id is unforgeable proof the tool ran on
   the remote host.

6. **Tag roster.** The `describe-instances` roster query from
   `docs/architecture.md` returns this box mapped to its developer.

7. **Stop/start and re-verify (the most-skipped check).**
   `scripts/stop.sh` then `scripts/start.sh`, then repeat steps 2 and 5. This
   catches anything that lived in one-time user-data but should have been a
   systemd unit — the gateway must come back on its own, and the device-code
   token must survive (it does; it is on the volume, so you do NOT re-run step 4).

8. **Lifecycle checks.**
   - *Idle:* leave the box quiet; after 15 min under 3% CPU the CloudWatch alarm's
     EC2 stop action fires and the instance stops. `start.sh` brings it back.
   - *Schedule:* manually invoke the SSM `AWS-StopEC2Instance` automation (or wait
     for the 5 PM ET stop) and confirm the box stops; the 8 AM schedule (or
     `start.sh`) brings it back and the gateway returns via the systemd unit.
   - *On-demand:* `stop.sh` → `start.sh` round-trips the box in ~1 min.
