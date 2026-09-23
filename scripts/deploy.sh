#!/usr/bin/env bash
set -euo pipefail

# kiro-remote-crew deploy — cross-stack imports enforce the order:
#   iam -> kms -> vpc -> compute -> lifecycle
# Because downstream stacks resolve their inputs via Fn::ImportValue at CREATE
# time, this script does NOT shuttle outputs between stacks; it just names each
# template and the fixed stack names its neighbours import by.

usage() {
  cat >&2 <<EOF
Usage: $0 --developer <name> [options]

Required:
  --developer <name>     Developer this box is assigned to (drives tags + Name).

Options:
  --profile <name>       AWS CLI profile.
  --region <region>      AWS region.
  --tag-prefix <p>       Tag/namespace prefix (default: co). Passed to ALL stacks.
  --instance-type <t>    EC2 instance type (default: template default m7g.2xlarge).
  --environment <e>      Environment tag value (default: demo).
  --owner <o>            Owner tag value (org/email).
  --no-schedule          Deploy lifecycle with the business-hours schedule off.
  --no-idle-stop         Deploy lifecycle with the CPU idle-stop alarm off.
  --gitlab-hosts <list>  Self-managed GitLab hosts for KiroCrew's allowlist,
                         comma-separated bare host[:port]. Defaults to
                         GITLAB_HOSTS in the repo-root .env (gitignored), so
                         org-specific hostnames never need committing.
  -h, --help             This help.
EOF
  exit "${1:-2}"
}

PROFILE=""
REGION=""
DEVELOPER=""
TAG_PREFIX="co"
INSTANCE_TYPE=""
ENVIRONMENT=""
OWNER=""
SCHEDULE_ENABLED="true"
IDLE_STOP_ENABLED="true"
GITLAB_HOSTS=""
GITLAB_HOSTS_SET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --developer)      DEVELOPER="${2:-}"; shift 2 ;;
    --profile)        PROFILE="${2:-}"; shift 2 ;;
    --region)         REGION="${2:-}"; shift 2 ;;
    --tag-prefix)     TAG_PREFIX="${2:-}"; shift 2 ;;
    --instance-type)  INSTANCE_TYPE="${2:-}"; shift 2 ;;
    --environment)    ENVIRONMENT="${2:-}"; shift 2 ;;
    --owner)          OWNER="${2:-}"; shift 2 ;;
    --no-schedule)    SCHEDULE_ENABLED="false"; shift ;;
    --no-idle-stop)   IDLE_STOP_ENABLED="false"; shift ;;
    --gitlab-hosts)   GITLAB_HOSTS="${2:-}"; GITLAB_HOSTS_SET=1; shift 2 ;;
    -h|--help)        usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 2 ;;
  esac
done

# --- Preflight ------------------------------------------------------------
if [ -z "$DEVELOPER" ]; then
  echo "ERROR: --developer is required (the box is tagged and named after it)." >&2
  usage 2
fi
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found on PATH." >&2; exit 1; }

# Fixed stack names — downstream templates import by these exact names.
IAM_STACK="${TAG_PREFIX}-kiro-remote-iam"
KMS_STACK="${TAG_PREFIX}-kiro-remote-kms"
VPC_STACK="${TAG_PREFIX}-kiro-remote-vpc"
COMPUTE_STACK="${TAG_PREFIX}-kiro-remote-compute"
LIFECYCLE_STACK="${TAG_PREFIX}-kiro-remote-lifecycle"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../infra" && pwd)"

# GitLab allowlist default from the gitignored .env. Read the one key rather
# than sourcing the file, so .env is data and never executes.
ENV_FILE="$SCRIPT_DIR/../.env"
if [ -z "$GITLAB_HOSTS_SET" ] && [ -f "$ENV_FILE" ]; then
  GITLAB_HOSTS="$(sed -n 's/^GITLAB_HOSTS=//p' "$ENV_FILE" | tail -1 | tr -d "\"' ")"
fi

# Common args threaded onto every aws call.
AWS_COMMON=()
[ -n "$PROFILE" ] && AWS_COMMON+=(--profile "$PROFILE")
[ -n "$REGION" ]  && AWS_COMMON+=(--region "$REGION")

aws "${AWS_COMMON[@]}" sts get-caller-identity >/dev/null 2>&1 \
  || { echo "ERROR: could not resolve AWS credentials (profile/region). Run 'aws sso login' or 'aws configure'." >&2; exit 1; }

# --- Deploy helper --------------------------------------------------------
deploy_stack() {
  local stack="$1" template="$2"; shift 2
  echo ">>> deploying $stack ($template)"
  aws "${AWS_COMMON[@]}" cloudformation deploy \
    --stack-name "$stack" \
    --template-file "$INFRA_DIR/$template" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    "$@" || {
      echo "ERROR: $stack failed. Surfacing recent stack events:" >&2
      aws "${AWS_COMMON[@]}" cloudformation describe-stack-events \
        --stack-name "$stack" \
        --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='UPDATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
        --output table 2>/dev/null | head -40 >&2 || true
      exit 1
    }
}

# --- 1. iam (boundary; idempotent — deploy re-runs are no-ops) ------------
deploy_stack "$IAM_STACK" iam.yaml \
  --parameter-overrides \
    "TagPrefix=$TAG_PREFIX" \
    ${ENVIRONMENT:+"Environment=$ENVIRONMENT"} \
    ${OWNER:+"Owner=$OWNER"}

# --- 2. kms ---------------------------------------------------------------
deploy_stack "$KMS_STACK" kms.yaml \
  --parameter-overrides "TagPrefix=$TAG_PREFIX"

# --- 3. vpc ---------------------------------------------------------------
# fck-nat publishes no SSM public parameter, so resolve the latest fck-nat AMI
# by owner + name filter (per https://fck-nat.dev/stable/deploying/) and pass it
# in. arm64 to match the t4g.nano default fck-nat instance type.
echo ">>> resolving latest fck-nat AMI (owner 568608671756, arm64)"
FCK_NAT_AMI="$(aws "${AWS_COMMON[@]}" ec2 describe-images \
  --owners 568608671756 \
  --filters "Name=name,Values=fck-nat-al2023-*-arm64-ebs" "Name=state,Values=available" \
  --query "reverse(sort_by(Images,&CreationDate))[0].ImageId" \
  --output text 2>/dev/null || true)"
if [ -z "$FCK_NAT_AMI" ] || [ "$FCK_NAT_AMI" = "None" ]; then
  echo "ERROR: no fck-nat AMI found for this region (owner 568608671756, fck-nat-al2023-*-arm64-ebs)." >&2
  echo "       fck-nat may not publish in this region. See https://fck-nat.dev/stable/deploying/." >&2
  exit 1
fi
echo "    fck-nat AMI: $FCK_NAT_AMI"
deploy_stack "$VPC_STACK" vpc.yaml \
  --parameter-overrides \
    "TagPrefix=$TAG_PREFIX" \
    "FckNatAmiId=$FCK_NAT_AMI"

# --- 4. compute (blocks on the WaitCondition; rollback surfaces the reason)
deploy_stack "$COMPUTE_STACK" compute.yaml \
  --parameter-overrides \
    "TagPrefix=$TAG_PREFIX" \
    "Developer=$DEVELOPER" \
    "IamStackName=$IAM_STACK" \
    "KmsStackName=$KMS_STACK" \
    "VpcStackName=$VPC_STACK" \
    "ScheduleEnabled=$SCHEDULE_ENABLED" \
    "GitlabHosts=$GITLAB_HOSTS" \
    ${INSTANCE_TYPE:+"InstanceType=$INSTANCE_TYPE"} \
    ${ENVIRONMENT:+"Environment=$ENVIRONMENT"} \
    ${OWNER:+"Owner=$OWNER"}

# --- 5. lifecycle ---------------------------------------------------------
deploy_stack "$LIFECYCLE_STACK" lifecycle.yaml \
  --parameter-overrides \
    "TagPrefix=$TAG_PREFIX" \
    "ComputeStackName=$COMPUTE_STACK" \
    "IamStackName=$IAM_STACK" \
    "ScheduleEnabled=$SCHEDULE_ENABLED" \
    "IdleStopEnabled=$IDLE_STOP_ENABLED"

# --- Summary --------------------------------------------------------------
INSTANCE_ID="$(aws "${AWS_COMMON[@]}" cloudformation describe-stacks \
  --stack-name "$COMPUTE_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text 2>/dev/null || true)"

echo
echo "=== kiro-remote-crew deployed ==="
echo "  developer : $DEVELOPER"
echo "  instance  : ${INSTANCE_ID:-<unknown>}"
echo "  stacks    : $IAM_STACK, $KMS_STACK, $VPC_STACK, $COMPUTE_STACK, $LIFECYCLE_STACK"
echo
echo "Next steps:"
echo
echo "  1. Sign in to kiro-cli on the box (one-time, over SSM):"
echo "     aws${PROFILE:+ --profile $PROFILE}${REGION:+ --region $REGION} ssm start-session --target ${INSTANCE_ID:-<instance-id>}"
echo "     # then on the box:"
echo "     sudo -u ec2-user bash -l"
echo "     kiro-cli login --use-device-flow   # choose your provider, then approve the URL + code"
echo "     exit; exit"
echo
echo "  2. Connect (SSM port-forward to the dashboard):"
echo "     scripts/connect.sh${PROFILE:+ --profile $PROFILE}${REGION:+ --region $REGION}${TAG_PREFIX:+ --tag-prefix $TAG_PREFIX}"
echo
echo "  See docs/verification.md for the full checklist."
