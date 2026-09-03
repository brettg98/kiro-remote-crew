#!/usr/bin/env bash
set -euo pipefail

# On-demand stop — park the box. A stopped box costs nothing (you still pay for
# the EBS volume) and restarts in ~1 min via start.sh.

usage() {
  cat >&2 <<EOF
Usage: $0 [options]

Options:
  --profile <name>     AWS CLI profile.
  --region <region>    AWS region.
  --tag-prefix <p>     Tag/namespace prefix (default: co) — locates the stacks.
  -h, --help           This help.
EOF
  exit "${1:-2}"
}

PROFILE=""
REGION=""
TAG_PREFIX="co"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)    PROFILE="${2:-}"; shift 2 ;;
    --region)     REGION="${2:-}"; shift 2 ;;
    --tag-prefix) TAG_PREFIX="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 2 ;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found on PATH." >&2; exit 1; }

aws "${AWS_COMMON[@]}" sts get-caller-identity >/dev/null 2>&1 \
  || { echo "ERROR: could not resolve AWS credentials. Run 'aws sso login' or 'assume <profile>'." >&2; exit 1; }

COMPUTE_STACK="${TAG_PREFIX}-kiro-remote-compute"

AWS_COMMON=()
[ -n "$PROFILE" ] && AWS_COMMON+=(--profile "$PROFILE")
[ -n "$REGION" ]  && AWS_COMMON+=(--region "$REGION")

INSTANCE_ID="$(aws "${AWS_COMMON[@]}" cloudformation describe-stacks \
  --stack-name "$COMPUTE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text 2>/dev/null || true)"
[ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ] \
  || { echo "ERROR: could not resolve InstanceId from stack '$COMPUTE_STACK'." >&2; exit 1; }

echo ">>> stopping $INSTANCE_ID"
aws "${AWS_COMMON[@]}" ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null

echo ">>> waiting for the instance to stop"
aws "${AWS_COMMON[@]}" ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
echo "    stopped. Bring it back with scripts/start.sh."
