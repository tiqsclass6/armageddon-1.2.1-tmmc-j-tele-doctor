#!/usr/bin/env bash
# Armageddon 1.2.1 full teardown.
#
# Empties versioned syslog buckets (Tokyo + Osaka replica), then destroys
# every resource in the Terraform state. Does not delete the remote S3
# backend object armageddon-class6.tfstate.
#
# Run from any directory:
#   bash scripts/4-teardown-lab.sh
#
# Non-interactive:
#   bash scripts/4-teardown-lab.sh --yes
#
# Optional:
#   --skip-empty-buckets
#   --remove-terraform-cache
#   --purge-session
#

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "ERROR: Do not source this script."
  echo "Run it with: bash scripts/4-teardown-lab.sh"
  return 1
fi

set -Eeuo pipefail

# ==============================================================================
# Terminal colors and presentation helpers
# ==============================================================================

COLOR_OUTPUT="${COLOR_OUTPUT:-auto}"
USE_COLOR=false

case "${COLOR_OUTPUT}" in
  always)
    USE_COLOR=true
    ;;
  never)
    USE_COLOR=false
    ;;
  auto)
    if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && ( -t 1 || -t 2 ) ]]; then
      USE_COLOR=true
    fi
    ;;
  *)
    printf 'ERROR: COLOR_OUTPUT must be auto, always, or never.\n' >&2
    exit 2
    ;;
esac

if $USE_COLOR; then
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'
  CYAN=$'\033[0;36m'
  BRIGHT_BLUE=$'\033[1;34m'
  BRIGHT_MAGENTA=$'\033[1;35m'
  BRIGHT_CYAN=$'\033[1;36m'
  WHITE=$'\033[1;37m'
else
  RESET=''
  BOLD=''
  DIM=''
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  MAGENTA=''
  CYAN=''
  BRIGHT_BLUE=''
  BRIGHT_MAGENTA=''
  BRIGHT_CYAN=''
  WHITE=''
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="${TEARDOWN_ARTIFACT_DIR:-${REPO_ROOT}/teardown-artifacts/${TIMESTAMP}}"
TEARDOWN_LOG="${ARTIFACT_DIR}/4-teardown-lab.log"

AUTO_APPROVE=false
SKIP_EMPTY_BUCKETS=false
REMOVE_TERRAFORM_CACHE=false
PURGE_SESSION=false

usage() {
  cat <<'EOF'
Usage:
  bash scripts/4-teardown-lab.sh [options]

Options:
  --yes                    Skip the typed destruction confirmation.
  --skip-empty-buckets     Do not empty syslog S3 buckets first (destroy may fail
                           on versioned objects).
  --purge-session          Remove .lab-session.env after a successful destroy.
  --remove-terraform-cache Remove terraform/.terraform after a successful destroy.
  -h, --help               Show this help.

This script must be executed, not sourced.

The remote Terraform state object is not deleted:
  s3://armageddon-tiqs-state-files/armageddon-class6.tfstate
EOF
}

while (($# > 0)); do
  case "$1" in
    --yes)
      AUTO_APPROVE=true
      ;;
    --skip-empty-buckets)
      SKIP_EMPTY_BUCKETS=true
      ;;
    --purge-session)
      PURGE_SESSION=true
      ;;
    --remove-terraform-cache)
      REMOVE_TERRAFORM_CACHE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '%bERROR: Unknown option: %s%b\n' "$RED" "$1" "$RESET" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

mkdir -p "$ARTIFACT_DIR"

strip_ansi() {
  LC_ALL=C sed -E $'s/\033\\[[0-9;]*[mK]//g'
}

if $USE_COLOR; then
  exec > >(tee >(strip_ansi >> "$TEARDOWN_LOG")) 2>&1
else
  exec > >(tee -a "$TEARDOWN_LOG") 2>&1
fi

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

emit() {
  local color="$1"
  local level="$2"
  shift 2

  printf '%b[%s] %-9s %s%b\n' \
    "$color" \
    "$(timestamp_utc)" \
    "[${level}]" \
    "$*" \
    "$RESET"
}

log() {
  emit "$CYAN" "INFO" "$*"
}

success() {
  emit "$GREEN" "OK" "$*"
}

warn() {
  emit "$YELLOW" "WARNING" "$*"
}

error() {
  emit "$RED" "ERROR" "$*"
}

danger() {
  emit "$RED" "DANGER" "$*"
}

die() {
  error "$*"
  exit 1
}

section_with_color() {
  local color="$1"
  shift

  printf '\n%b%s%b\n' "${color}${BOLD}" \
    '================================================================' "$RESET"
  printf '%b%s%b\n' "${color}${BOLD}" "$*" "$RESET"
  printf '%b%s%b\n' "${color}${BOLD}" \
    '================================================================' "$RESET"
}

section() {
  section_with_color "$BRIGHT_CYAN" "$*"
}

danger_section() {
  section_with_color "$RED" "$*"
}

success_section() {
  section_with_color "$GREEN" "$*"
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 ||
    die "Required command not found: $command_name"
}

to_native_path() {
  local path="$1"

  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$path"
  else
    printf '%s' "$path"
  fi
}

configure_python() {
  PYTHON_BIN=""

  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  else
    die "Required command not found: python (or python3)"
  fi
}

purge_previous_artifacts() {
  local base_dir="$1"
  local keep_dir="${2:-}"
  local entry=""

  [[ -d "$base_dir" ]] || return 0

  for entry in "$base_dir"/*/; do
    [[ -d "$entry" ]] || continue
    entry="${entry%/}"

    if [[ -n "$keep_dir" && "$entry" == "$keep_dir" ]]; then
      continue
    fi

    rm -rf "$entry"
  done
}

list_state_buckets() {
  local show_json="$1"

  "$PYTHON_BIN" - "$show_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists() or path.stat().st_size == 0:
    raise SystemExit(0)

data = json.loads(path.read_text(encoding="utf-8"))
resources = data.get("values", {}).get("root_module", {}).get("resources", [])

for resource in resources:
    if resource.get("type") != "aws_s3_bucket":
        continue
    values = resource.get("values") or {}
    bucket = values.get("bucket") or ""
    region = values.get("region") or ""
    name = resource.get("name") or ""
    if bucket:
        print(f"{name}\t{bucket}\t{region}")
PY
}

empty_versioned_bucket() {
  local bucket="$1"
  local region="$2"
  local versions_file="${ARTIFACT_DIR}/s3-${bucket}-versions.json"
  local delete_file="${ARTIFACT_DIR}/s3-${bucket}-delete.json"
  local object_count=""

  [[ -n "$bucket" ]] || return 0

  if [[ -z "$region" || "$region" == "None" ]]; then
    region="$(
      aws s3api get-bucket-location \
        --bucket "$bucket" \
        --query LocationConstraint \
        --output text \
        --no-cli-pager 2>/dev/null || true
    )"
    region="${region//$'\r'/}"
    if [[ -z "$region" || "$region" == "None" ]]; then
      region="us-east-1"
    fi
  fi

  if ! aws s3api head-bucket --bucket "$bucket" --region "$region" --no-cli-pager >/dev/null 2>&1; then
    warn "Bucket not found (already gone?): ${bucket}"
    return 0
  fi

  log "Emptying versioned bucket s3://${bucket} (${region})"
  aws s3 rm "s3://${bucket}" --recursive --region "$region" --no-cli-pager || true

  aws s3api list-object-versions \
    --bucket "$bucket" \
    --region "$region" \
    --output json \
    --no-cli-pager > "$versions_file" || true

  object_count="$(
    "$PYTHON_BIN" - "$versions_file" "$delete_file" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
if not src.exists() or src.stat().st_size == 0:
    dst.write_text(json.dumps({"Objects": [], "Quiet": True}), encoding="utf-8")
    print(0)
    raise SystemExit(0)

payload = json.loads(src.read_text(encoding="utf-8"))
objects = []
for item in payload.get("Versions") or []:
    objects.append({"Key": item["Key"], "VersionId": item["VersionId"]})
for item in payload.get("DeleteMarkers") or []:
    objects.append({"Key": item["Key"], "VersionId": item["VersionId"]})
dst.write_text(json.dumps({"Objects": objects, "Quiet": True}), encoding="utf-8")
print(len(objects))
PY
  )"
  object_count="${object_count//$'\r'/}"

  if [[ "${object_count:-0}" == "0" ]]; then
    log "Bucket ${bucket} has no object versions left."
    return 0
  fi

  log "Deleting ${object_count} object version(s)/delete marker(s) from ${bucket}."

  "$PYTHON_BIN" - "$delete_file" "$bucket" "$region" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
bucket = sys.argv[2]
region = sys.argv[3]
objects = payload.get("Objects") or []
batch_size = 1000

for start in range(0, len(objects), batch_size):
    batch = {"Objects": objects[start:start + batch_size], "Quiet": True}
    batch_path = Path(sys.argv[1]).with_name(f"{bucket}-delete-batch-{start}.json")
    batch_path.write_text(json.dumps(batch), encoding="utf-8")
    delete_uri = batch_path.resolve().as_posix()
    subprocess.run(
        [
            "aws",
            "s3api",
            "delete-objects",
            "--bucket",
            bucket,
            "--region",
            region,
            "--delete",
            f"file://{delete_uri}",
            "--no-cli-pager",
        ],
        check=False,
    )
PY

  success "Emptied s3://${bucket}"
}

cleanup() {
  local rc=$?

  if (( rc != 0 )); then
    warn "Teardown stopped with exit code $rc."
    warn "Review: $TEARDOWN_LOG"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

section "Armageddon 1.2.1  |  4-teardown-lab.sh"
log "Repository root: $REPO_ROOT"
log "Evidence and logs: $ARTIFACT_DIR"
log "Phases: 01-08"

section "01/08 Prerequisite versions"
require_command aws
require_command terraform
require_command tee
configure_python

export AWS_PAGER=""
export AWS_CLI_FILE_ENCODING="UTF-8"
export AWS_CLI_OUTPUT_ENCODING="UTF-8"
chcp.com 65001 >/dev/null 2>&1 || true

aws --version
terraform version
"$PYTHON_BIN" --version
aws sts get-caller-identity --no-cli-pager

[[ -d "$TF_DIR" ]] || die "Terraform directory not found: $TF_DIR"
cd "$TF_DIR"

section "02/08 Terraform init"
terraform init -reconfigure
success "terraform init completed"

section "03/08 Snapshot state and outputs"
terraform output -json > "${ARTIFACT_DIR}/terraform-outputs.json" 2>/dev/null || true
terraform output > "${ARTIFACT_DIR}/terraform-outputs.txt" 2>/dev/null || true
terraform state list > "${ARTIFACT_DIR}/terraform-state-before.txt" 2>/dev/null || true
terraform show -json > "${ARTIFACT_DIR}/terraform-show.json" 2>/dev/null || true

STATE_RESOURCES="$(terraform state list 2>/dev/null || true)"
if [[ -z "$STATE_RESOURCES" ]]; then
  warn "Terraform state contains no managed resources."
  warn "There may be nothing to destroy."
else
  log "State currently tracks $(printf '%s\n' "$STATE_RESOURCES" | grep -c . || true) resource(s)."
fi

section "04/08 Empty versioned syslog buckets"
if $SKIP_EMPTY_BUCKETS; then
  warn "Skipped bucket empty (--skip-empty-buckets). terraform destroy may fail on versioned objects."
else
  bucket_rows="$(list_state_buckets "${ARTIFACT_DIR}/terraform-show.json" || true)"
  if [[ -z "$bucket_rows" ]]; then
    warn "No aws_s3_bucket resources found in state; trying name prefixes."
    syslog_guess="$(
      aws s3api list-buckets \
        --query "Buckets[?starts_with(Name, 'syslog-bucket-')].Name | [0]" \
        --output text \
        --no-cli-pager
    )"
    dest_guess="$(
      aws s3api list-buckets \
        --query "Buckets[?starts_with(Name, 'destination-')].Name | [0]" \
        --output text \
        --no-cli-pager
    )"
    syslog_guess="${syslog_guess//$'\r'/}"
    dest_guess="${dest_guess//$'\r'/}"
    bucket_rows=""
    [[ -n "$syslog_guess" && "$syslog_guess" != "None" ]] &&
      bucket_rows=$'SyslogBucket\t'"${syslog_guess}"$'\tap-northeast-1'
    [[ -n "$dest_guess" && "$dest_guess" != "None" ]] &&
      bucket_rows+=$'\ndestination\t'"${dest_guess}"$'\tap-northeast-3'
  fi

  if [[ -z "${bucket_rows//[$'\n']/}" ]]; then
    warn "No syslog buckets discovered."
  else
    printf '%s\n' "$bucket_rows" > "${ARTIFACT_DIR}/s3-buckets.txt"
    while IFS=$'\t' read -r bucket_name bucket_id bucket_region; do
      [[ -n "$bucket_id" ]] || continue
      log "State bucket ${bucket_name}: ${bucket_id} (${bucket_region:-unknown})"
      empty_versioned_bucket "$bucket_id" "$bucket_region"
    done <<< "$bucket_rows"
  fi
fi

danger_section "05/08 Terraform destroy plan"
DESTROY_PLAN="${ARTIFACT_DIR}/destroy.tfplan"
DESTROY_PLAN_NATIVE="$(to_native_path "$DESTROY_PLAN")"
terraform plan -destroy -out="$DESTROY_PLAN_NATIVE"
terraform show -no-color "$DESTROY_PLAN_NATIVE" \
  > "${ARTIFACT_DIR}/terraform-destroy-plan.txt"
success "Destroy plan saved to ${ARTIFACT_DIR}/terraform-destroy-plan.txt"

section "06/08 Confirmation"
if ! $AUTO_APPROVE; then
  echo
  danger "This destroys the Armageddon 1.2.1 AWS stack in all seven app regions plus Osaka."
  warn "NAT gateways, TGWs, ALBs, Aurora, SIEM, and syslog buckets will be deleted."
  warn "Remote S3 Terraform state will be kept."
  printf '%b%s%b\n' "$YELLOW" \
    "Review ${ARTIFACT_DIR}/terraform-destroy-plan.txt before continuing." \
    "$RESET"
  echo
  read -r -p "$(printf '%b' "${BOLD}${RED}Type DESTROY-ARMAGEDDON to continue: ${RESET}")" confirmation

  if [[ "$confirmation" != "DESTROY-ARMAGEDDON" ]]; then
    die "Destruction cancelled."
  fi
else
  warn "Auto-approved (--yes). Destroying without an interactive prompt."
fi

danger_section "07/08 Terraform destroy"
terraform apply -auto-approve "$DESTROY_PLAN_NATIVE"
success "terraform destroy completed"

log "Waiting 20 seconds for AWS deletion to propagate."
sleep 20

section "08/08 Local cleanup and leftover check"
REMAINING_STATE="$(terraform state list 2>/dev/null || true)"

if [[ -n "$REMAINING_STATE" ]]; then
  printf '%s\n' "$REMAINING_STATE" \
    > "${ARTIFACT_DIR}/terraform-state-remaining.txt"
  warn "Terraform state still contains resources:"
  printf '%s\n' "$REMAINING_STATE"
  die "Teardown is incomplete. Review Terraform errors and remaining state."
fi

success "Terraform state is empty."

rm -f \
  "$TF_DIR/tfplan" \
  "$TF_DIR/destroy.tfplan"

if $PURGE_SESSION; then
  rm -f "${REPO_ROOT}/.lab-session.env"
  log "Removed .lab-session.env."
else
  log "Preserved .lab-session.env."
fi

if $REMOVE_TERRAFORM_CACHE; then
  rm -rf "$TF_DIR/.terraform"
  log "Removed terraform/.terraform."
else
  log "Preserved terraform/.terraform for faster future initialization."
fi

purge_previous_artifacts "${REPO_ROOT}/run-artifacts"
purge_previous_artifacts "${REPO_ROOT}/teardown-artifacts" "$ARTIFACT_DIR"

log "Removed prior run-artifacts/ directories."
log "Removed prior teardown-artifacts/ directories, keeping only: $ARTIFACT_DIR"

success_section "Armageddon 1.2.1 teardown completed"
log "Evidence and logs: $ARTIFACT_DIR"
warn "Remote S3 Terraform state was not deleted (s3://armageddon-tiqs-state-files/armageddon-class6.tfstate)."
log "Redeploy with: bash scripts/3-run-lab.sh"
