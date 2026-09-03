#!/usr/bin/env bash
set -euo pipefail

# Tear down the disposable layers — lifecycle THEN compute — leaving iam, kms and
# vpc (and the fck-nat) intact so the host is cheap to recreate. Order matters:
# lifecycle imports compute's InstanceId, so compute cannot be deleted while
# lifecycle is up (the export-in-use check enforces it).

usage() {
  cat >&2 <<EOF
Usage: $0 [options]

Options:
  --profile <name>     AWS CLI profile.
  --region <region>    AWS region.
  --tag-prefix <p>     Tag/namespace prefix (default: co) — locates the stacks.
  --yes                Skip the confirmation prompt.
  -h, --help           This help.
EOF
  exit "${1:-2}"
}

PROFILE=""
REGION=""
TAG_PREFIX="co"
ASSUME_YES="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)    PROFILE="${2:-}"; shift 2 ;;
    --region)     REGION="${2:-}"; shift 2 ;;
    --tag-prefix) TAG_PREFIX="${2:-}"; shift 2 ;;
    --yes)        ASSUME_YES="true"; shift ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 2 ;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found on PATH." >&2; exit 1; }

# Verify credentials before checking stacks — without valid creds,
# describe-stacks fails silently and the script reports "not present."
aws "${AWS_COMMON[@]}" sts get-caller-identity >/dev/null 2>&1 \
  || { echo "ERROR: could not resolve AWS credentials. Run 'aws sso login' or 'assume <profile>'." >&2; exit 1; }

COMPUTE_STACK="${TAG_PREFIX}-kiro-remote-compute"
LIFECYCLE_STACK="${TAG_PREFIX}-kiro-remote-lifecycle"
IAM_STACK="${TAG_PREFIX}-kiro-remote-iam"
KMS_STACK="${TAG_PREFIX}-kiro-remote-kms"
VPC_STACK="${TAG_PREFIX}-kiro-remote-vpc"

AWS_COMMON=()
[ -n "$PROFILE" ] && AWS_COMMON+=(--profile "$PROFILE")
[ -n "$REGION" ]  && AWS_COMMON+=(--region "$REGION")

if [ "$ASSUME_YES" != "true" ]; then
  echo "This deletes: $LIFECYCLE_STACK, then $COMPUTE_STACK (and its encrypted volume)."
  echo "It KEEPS: $IAM_STACK, $KMS_STACK, $VPC_STACK (and the fck-nat)."
  printf "Proceed? [y/N] "
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac
fi

delete_stack() {
  local stack="$1"
  if ! aws "${AWS_COMMON[@]}" cloudformation describe-stacks --stack-name "$stack" >/dev/null 2>&1; then
    echo ">>> $stack not present — skipping"
    return 0
  fi
  echo ">>> deleting $stack"
  aws "${AWS_COMMON[@]}" cloudformation delete-stack --stack-name "$stack"
  echo "    waiting for DELETE_COMPLETE"
  aws "${AWS_COMMON[@]}" cloudformation wait stack-delete-complete --stack-name "$stack"
  echo "    $stack deleted"
}

# lifecycle first (it imports compute's InstanceId), then compute.
delete_stack "$LIFECYCLE_STACK"
delete_stack "$COMPUTE_STACK"

cat <<EOF

=== host torn down ===
Kept (recreate the host with scripts/deploy.sh --developer <name>):
  $IAM_STACK, $KMS_STACK, $VPC_STACK

To remove everything, delete them in reverse dependency order once no compute
stack imports from them:
  aws cloudformation delete-stack --stack-name $VPC_STACK
  aws cloudformation delete-stack --stack-name $KMS_STACK
  aws cloudformation delete-stack --stack-name $IAM_STACK
EOF
