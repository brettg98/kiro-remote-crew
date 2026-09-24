# Connecting from your local Kiro Crew

`scripts/connect.sh` opens a one-off port-forward in your terminal. If you run
Kiro Crew on your laptop too, you can instead add the box as a **remote
instance**, and your local dashboard embeds the remote one. Over SSM, your local
gateway opens the tunnel itself by running
`aws ssm start-session --profile <aws_profile>` in the background.

## The instance settings

Add the box as a remote instance with connection method **SSM**. Your local Kiro
Crew stores it in `~/.kiro/crew/instances.json` with these fields:

| Field | Value |
|---|---|
| `connection_method` | `ssm` |
| `ssm_target` | the instance id (`deploy.sh` prints it at the end) |
| `aws_profile` | the AWS CLI profile that can `ssm:StartSession` on the box |
| `aws_region` | the region you deployed to |
| `ssm_run_as` | `ec2-user` (the user the remote gateway runs as) |

Your laptop also needs the AWS CLI and the Session Manager plugin, the same as
`connect.sh` (see [`prerequisites.md`](prerequisites.md)).

## When the tunnel says your credentials expired

```
AWS credentials missing or expired (refresh them, e.g. `aws sso login --profile <name>`):
aws: [ERROR]: Error when retrieving token from sso: Token has expired and refresh failed
```

Your SSO login for `aws_profile` has expired. The local gateway calls the AWS CLI
directly, so it reads the CLI's own SSO cache (`~/.aws/sso/cache`). Refresh that:

```bash
aws sso login --profile <aws_profile>
```

If your profiles share an `sso_session`, `aws sso login --sso-session <name>`
refreshes all of them at once. Then reconnect the instance in Kiro Crew.

**If you use [Granted](https://granted.dev):** `assume <profile>` does not fix
this. Granted keeps its own token cache, separate from the AWS CLI's, so your
terminal works while the gateway still sees an expired token. (Observed on this
build's setup, not taken from Granted's documentation.) Use `aws sso login` for
the gateway, and expect to repeat it whenever your SSO session expires.
