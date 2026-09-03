#!/usr/bin/env bash
set -euo pipefail

# Open an SSM port-forward from this laptop to the remote Kiro Crew dashboard.
# No SSH key, no inbound port — uses ssm:StartSession only. IAM decides who
# connects; CloudTrail records it.

usage() {
  cat >&2 <<EOF
Usage: $0 [options]

Options:
  --profile <name>     AWS CLI profile.
  --region <region>    AWS region.
  --tag-prefix <p>     Tag/namespace prefix (default: co) — locates the stacks.
  --local-port <n>     Local port to forward from (default: the remote port).
  -h, --help           This help.
EOF
  exit "${1:-2}"
}

PROFILE=""
REGION=""
TAG_PREFIX="co"
LOCAL_PORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)    PROFILE="${2:-}"; shift 2 ;;
    --region)     REGION="${2:-}"; shift 2 ;;
    --tag-prefix) TAG_PREFIX="${2:-}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 2 ;;
  esac
done

# --- Preflight ------------------------------------------------------------
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found on PATH." >&2; exit 1; }

aws "${AWS_COMMON[@]}" sts get-caller-identity >/dev/null 2>&1 \
  || { echo "ERROR: could not resolve AWS credentials. Run 'aws sso login' or 'assume <profile>'." >&2; exit 1; }

if ! aws ssm start-session help >/dev/null 2>&1 && ! command -v session-manager-plugin >/dev/null 2>&1; then
  echo "ERROR: the SSM Session Manager plugin is not installed." >&2
  echo "  See: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
  exit 1
fi

COMPUTE_STACK="${TAG_PREFIX}-kiro-remote-compute"

AWS_COMMON=()
[ -n "$PROFILE" ] && AWS_COMMON+=(--profile "$PROFILE")
[ -n "$REGION" ]  && AWS_COMMON+=(--region "$REGION")

# --- Resolve target + port from the compute stack outputs -----------------
INSTANCE_ID="$(aws "${AWS_COMMON[@]}" cloudformation describe-stacks \
  --stack-name "$COMPUTE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text 2>/dev/null || true)"
[ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ] \
  || { echo "ERROR: could not resolve InstanceId from stack '$COMPUTE_STACK'. Is it deployed?" >&2; exit 1; }

REMOTE_PORT="$(aws "${AWS_COMMON[@]}" cloudformation describe-stacks \
  --stack-name "$COMPUTE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='DashboardPort'].OutputValue" \
  --output text 2>/dev/null || true)"
[ -n "$REMOTE_PORT" ] && [ "$REMOTE_PORT" != "None" ] || REMOTE_PORT="5476"

[ -n "$LOCAL_PORT" ] || LOCAL_PORT="$REMOTE_PORT"

echo ">>> forwarding localhost:$LOCAL_PORT -> $INSTANCE_ID:$REMOTE_PORT (SSM)"
echo "    open http://localhost:$LOCAL_PORT/ once the session is up. Ctrl-C to close."

exec aws "${AWS_COMMON[@]}" ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "portNumber=$REMOTE_PORT,localPortNumber=$LOCAL_PORT"
