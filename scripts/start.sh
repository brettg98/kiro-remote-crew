#!/usr/bin/env bash
set -euo pipefail

# On-demand start — un-park the box the idle alarm or schedule stopped. Waits
# for the instance to run and re-register with SSM, then prints the connect hint.

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

echo ">>> starting $INSTANCE_ID"
aws "${AWS_COMMON[@]}" ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null

echo ">>> waiting for the instance to run"
aws "${AWS_COMMON[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID"

echo ">>> waiting for SSM to re-register (up to ~2 min)"
for _ in $(seq 1 24); do
  ping="$(aws "${AWS_COMMON[@]}" ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || true)"
  [ "$ping" = "Online" ] && break
  sleep 5
done
[ "${ping:-}" = "Online" ] && echo "    SSM: Online" || echo "    SSM not yet Online — give it another moment."

echo
echo "Box is up. Connect —"
echo "  scripts/connect.sh${PROFILE:+ --profile $PROFILE}${REGION:+ --region $REGION}${TAG_PREFIX:+ --tag-prefix $TAG_PREFIX}"
