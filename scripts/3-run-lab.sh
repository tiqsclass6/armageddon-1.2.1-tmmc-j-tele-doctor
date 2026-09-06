#!/usr/bin/env bash
# Armageddon 1.2.1 deploy, validation, and live end-to-end test runner.
#
# Proves the Class 6 spec against a real AWS account:
#   - 7 regional apps on port 80
#   - ASGs across 2 AZs with no public IPs
#   - syslog to Japan over TGW only (no VPN)
#   - spokes send-only to 10.230.60.0/23 (A.3 / A.4)
#   - Loki ingest healthy; Grafana Tokyo-only; Aurora PII in Japan
#
# Run from any directory:
#   bash scripts/3-run-lab.sh
#
# Useful options:
#   --skip-apply        Validate an existing deployment (still runs init/fmt/validate/plan)
#   --skip-terraform    Skip init/fmt/validate/plan/apply; test current state only
#   --plan-only         Stop after terraform plan
#
# Environment overrides:
#   COLOR_OUTPUT=auto|always|never
#   ALB_WAIT_SECONDS=300
#   SIEM_WAIT_SECONDS=180
#   CURL_RETRY_DELAY_SECONDS=15
#   SSM_WAIT_SECONDS=60

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "ERROR: Do not source this script."
  echo "Run it with: bash scripts/3-run-lab.sh"
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
ARTIFACT_DIR="${RUN_ARTIFACT_DIR:-${REPO_ROOT}/run-artifacts/${TIMESTAMP}}"
RUN_LOG="${ARTIFACT_DIR}/3-run-lab.log"
SESSION_FILE="${ARTIFACT_DIR}/lab-session.env"
LATEST_SESSION_FILE="${REPO_ROOT}/.lab-session.env"
RESULTS_FILE="${ARTIFACT_DIR}/e2e-results.tsv"

ALB_WAIT_SECONDS="${ALB_WAIT_SECONDS:-300}"
SIEM_WAIT_SECONDS="${SIEM_WAIT_SECONDS:-180}"
CURL_RETRY_DELAY_SECONDS="${CURL_RETRY_DELAY_SECONDS:-15}"
SSM_WAIT_SECONDS="${SSM_WAIT_SECONDS:-60}"

SKIP_APPLY=false
SKIP_TERRAFORM=false
PLAN_ONLY=false

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

HUB_REGION="ap-northeast-1"
SYSLOG_CIDR="10.230.60.0/23"
TOKYO_CIDR="10.230.0.0/16"
DB_CIDR_A="10.230.51.0/24"
DB_CIDR_B="10.230.52.0/24"
EXPECTED_PAGE_MARKER="Samurai Katana"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/3-run-lab.sh [options]

Options:
  --skip-apply        Do not apply Terraform; still init/fmt/validate/plan, then test.
  --skip-terraform    Skip init, fmt, validate, plan, and apply. Test the current state.
  --plan-only         Stop after terraform plan (writes tfplan + terraform-plan.txt).
  -h, --help          Show this help.

This script must be executed, not sourced.

Git Bash on Windows:
  bash scripts/3-run-lab.sh --skip-apply

Teardown:
  bash scripts/4-teardown-lab.sh
EOF
}

while (($# > 0)); do
  case "$1" in
    --skip-apply)
      SKIP_APPLY=true
      ;;
    --skip-terraform)
      SKIP_TERRAFORM=true
      ;;
    --plan-only)
      PLAN_ONLY=true
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
: > "$RESULTS_FILE"

strip_ansi() {
  LC_ALL=C sed -E $'s/\033\\[[0-9;]*[mK]//g'
}

if $USE_COLOR; then
  exec > >(tee >(strip_ansi >> "$RUN_LOG")) 2>&1
else
  exec > >(tee -a "$RUN_LOG") 2>&1
fi

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

emit() {
  local color="$1"
  local level="$2"
  shift 2

  # stderr so command substitutions (wait_for_*, aws --query) keep a clean stdout.
  printf '%b[%s] %-9s %s%b\n' \
    "$color" \
    "$(timestamp_utc)" \
    "[${level}]" \
    "$*" \
    "$RESET" >&2
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

action() {
  emit "$BRIGHT_MAGENTA" "ACTION" "$*"
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

success_section() {
  section_with_color "$GREEN" "$*"
}

fail_section() {
  section_with_color "$RED" "$*"
}

sleep_with_message() {
  local seconds="$1"
  local reason="$2"

  if (( seconds <= 0 )); then
    return 0
  fi

  log "Waiting ${seconds} seconds: ${reason}"
  sleep "$seconds"
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

record_result() {
  local status="$1"
  local name="$2"
  local detail="$3"

  printf '%s\t%s\t%s\n' "$status" "$name" "$detail" >> "$RESULTS_FILE"

  case "$status" in
    PASS)
      PASS_COUNT=$((PASS_COUNT + 1))
      success "${name}: ${detail}"
      ;;
    FAIL)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      error "${name}: ${detail}"
      ;;
    WARN)
      WARN_COUNT=$((WARN_COUNT + 1))
      warn "${name}: ${detail}"
      ;;
    *)
      die "Unknown result status: $status"
      ;;
  esac
}

cleanup() {
  local rc=$?

  if (( rc != 0 )); then
    warn "The run stopped with exit code $rc."
    warn "Review: $RUN_LOG"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

configure_curl() {
  CURL_BIN="curl"
  CURL_TLS_ARGS=()

  if command -v curl.exe >/dev/null 2>&1; then
    CURL_BIN="curl.exe"
  fi

  if "$CURL_BIN" --version 2>/dev/null | grep -qi 'Schannel'; then
    CURL_TLS_ARGS+=(--ssl-no-revoke)
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

tf_output_required() {
  local output_name="$1"
  local value=""

  if ! value="$(terraform output -raw "$output_name" 2>/dev/null)"; then
    die "Terraform output '$output_name' is unavailable. Apply the stack or drop --skip-terraform."
  fi

  value="${value//$'\r'/}"

  if [[ -z "$value" || "$value" == "None" ]]; then
    die "Terraform output '$output_name' is empty."
  fi

  printf '%s' "$value"
}

tf_json_get() {
  local json_file="$1"
  shift

  "$PYTHON_BIN" - "$json_file" "$@" <<'PY'
import json
import sys

data = json.loads(open(sys.argv[1], encoding="utf-8").read())
cur = data
for key in sys.argv[2:]:
    if isinstance(cur, dict) and "value" in cur and key not in cur:
        cur = cur["value"]
    if isinstance(cur, dict) and key in cur:
        cur = cur[key]
        continue
    raise SystemExit(f"missing key {key}")

if isinstance(cur, dict) and set(cur.keys()) >= {"value", "type"}:
    cur = cur["value"]

if isinstance(cur, (dict, list)):
    print(json.dumps(cur))
elif cur is True:
    print("true")
elif cur is False:
    print("false")
elif cur is None:
    print("")
else:
    print(cur)
PY
}

awsq() {
  aws --no-cli-pager "$@"
}

# Git Bash treats backticks in aws --query as command substitution. Count with Python.
count_running_public_ips() {
  local json_file="$1"
  "$PYTHON_BIN" - "$json_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
count = 0
for reservation in data.get("Reservations", []):
    for instance in reservation.get("Instances", []):
        if instance.get("State", {}).get("Name") != "running":
            continue
        if instance.get("PublicIpAddress"):
            count += 1
print(count)
PY
}

count_spoke_tgw_routes() {
  local json_file="$1"
  local syslog_cidr="$2"
  local tokyo_cidr="$3"
  local db_cidr_a="$4"
  local db_cidr_b="$5"
  "$PYTHON_BIN" - "$json_file" "$syslog_cidr" "$tokyo_cidr" "$db_cidr_a" "$db_cidr_b" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
syslog_cidr, tokyo_cidr, db_a, db_b = sys.argv[2:6]
db_cidrs = {db_a, db_b}
syslog = tokyo = db = 0
for table in data.get("RouteTables", []):
    for route in table.get("Routes", []):
        if not route.get("TransitGatewayId"):
            continue
        cidr = route.get("DestinationCidrBlock") or ""
        if cidr == syslog_cidr:
            syslog += 1
        elif cidr == tokyo_cidr:
            tokyo += 1
        elif cidr in db_cidrs:
            db += 1
print(f"{syslog} {tokyo} {db}")
PY
}

save_session_values() {
  cat > "$SESSION_FILE" <<EOF
export HUB_REGION='${HUB_REGION}'
export TOKYO_ALB_URL='${TOKYO_ALB_URL}'
export NEW_YORK_ALB_URL='${NEW_YORK_ALB_URL}'
export LONDON_ALB_URL='${LONDON_ALB_URL}'
export SAO_PAULO_ALB_URL='${SAO_PAULO_ALB_URL}'
export SYDNEY_ALB_URL='${SYDNEY_ALB_URL}'
export HONG_KONG_ALB_URL='${HONG_KONG_ALB_URL}'
export CALIFORNIA_ALB_URL='${CALIFORNIA_ALB_URL}'
export LOKI_NLB_DNS='${LOKI_NLB_DNS}'
export GRAFANA_ALB_DNS='${GRAFANA_ALB_DNS}'
export AURORA_ENDPOINT='${AURORA_ENDPOINT}'
export SYSLOG_CIDR='${SYSLOG_CIDR}'
EOF

  cp "$SESSION_FILE" "$LATEST_SESSION_FILE"
  log "Session values saved to $SESSION_FILE"
  log "Latest session values copied to $LATEST_SESSION_FILE"
}

http_get() {
  local url="$1"
  local body_file="$2"
  local status=""

  status="$(
    "$CURL_BIN" \
      "${CURL_TLS_ARGS[@]}" \
      --silent \
      --show-error \
      --connect-timeout 10 \
      --max-time 25 \
      --output "$body_file" \
      --write-out '%{http_code}' \
      "$url" || true
  )"
  status="${status//$'\r'/}"
  printf '%s' "${status:-000}"
}

wait_for_http() {
  local url="$1"
  local label="$2"
  local body_file="$3"
  local timeout_seconds="$4"
  local elapsed=0
  local status="000"

  while (( elapsed <= timeout_seconds )); do
    status="$(http_get "$url" "$body_file")"
    log "${label} returned HTTP ${status}"

    if [[ "$status" == "200" ]]; then
      printf '%s' "$status"
      return 0
    fi

    sleep "$CURL_RETRY_DELAY_SECONDS"
    elapsed=$((elapsed + CURL_RETRY_DELAY_SECONDS))
  done

  printf '%s' "$status"
  return 1
}

assert_http_app() {
  local label="$1"
  local url="$2"
  local body_file="${ARTIFACT_DIR}/alb-${label}.html"
  local status=""

  if status="$(wait_for_http "$url" "$label ALB" "$body_file" "$ALB_WAIT_SECONDS")"; then
    if grep -q "$EXPECTED_PAGE_MARKER" "$body_file"; then
      record_result PASS "$label ALB :80" "HTTP 200 and page contains '${EXPECTED_PAGE_MARKER}' (${url})"
    else
      record_result FAIL "$label ALB :80" "HTTP 200 but page missing '${EXPECTED_PAGE_MARKER}' (${url})"
    fi
  else
    record_result FAIL "$label ALB :80" "HTTP ${status:-000} after ${ALB_WAIT_SECONDS}s (${url})"
  fi
}

alb_dns_host() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  url="${url%%/*}"
  printf '%s' "$url"
}

check_listener_port_80_only() {
  local label="$1"
  local region="$2"
  local alb_url="$3"
  local host=""
  local alb_arn=""
  local ports=""

  host="$(alb_dns_host "$alb_url")"
  alb_arn="$(
    awsq elbv2 describe-load-balancers \
      --region "$region" \
      --query "LoadBalancers[?DNSName=='${host}'].LoadBalancerArn | [0]" \
      --output text
  )"
  alb_arn="${alb_arn//$'\r'/}"

  if [[ -z "$alb_arn" || "$alb_arn" == "None" ]]; then
    record_result FAIL "$label listener" "ALB not found for ${host} in ${region}"
    return 0
  fi

  ports="$(
    awsq elbv2 describe-listeners \
      --region "$region" \
      --load-balancer-arn "$alb_arn" \
      --query 'sort_by(Listeners,&Port)[].Port' \
      --output text
  )"
  ports="${ports//$'\r'/}"
  ports="$(echo "$ports" | xargs)"

  if [[ "$ports" == "80" ]]; then
    record_result PASS "$label listener" "only port 80 (${region})"
  else
    record_result FAIL "$label listener" "expected only port 80, got '${ports}' (${region})"
  fi
}

check_asg() {
  local label="$1"
  local region="$2"
  local asg_name="$3"
  local min_size=""
  local desired=""
  local az_count=""
  local instance_ids=""
  local public_ip_count=""

  min_size="$(
    awsq autoscaling describe-auto-scaling-groups \
      --region "$region" \
      --auto-scaling-group-names "$asg_name" \
      --query 'AutoScalingGroups[0].MinSize' \
      --output text
  )"
  desired="$(
    awsq autoscaling describe-auto-scaling-groups \
      --region "$region" \
      --auto-scaling-group-names "$asg_name" \
      --query 'AutoScalingGroups[0].DesiredCapacity' \
      --output text
  )"
  az_count="$(
    awsq autoscaling describe-auto-scaling-groups \
      --region "$region" \
      --auto-scaling-group-names "$asg_name" \
      --query 'length(AutoScalingGroups[0].AvailabilityZones)' \
      --output text
  )"
  instance_ids="$(
    awsq autoscaling describe-auto-scaling-groups \
      --region "$region" \
      --auto-scaling-group-names "$asg_name" \
      --query 'AutoScalingGroups[0].Instances[].InstanceId' \
      --output text
  )"

  min_size="${min_size//$'\r'/}"
  desired="${desired//$'\r'/}"
  az_count="${az_count//$'\r'/}"
  instance_ids="${instance_ids//$'\r'/}"

  if [[ "$min_size" == "None" || -z "$min_size" ]]; then
    record_result FAIL "$label ASG" "ASG ${asg_name} not found in ${region}"
    return 0
  fi

  if [[ "$min_size" -ge 2 && "$desired" -ge 2 && "$az_count" -ge 2 ]]; then
    record_result PASS "$label ASG" "min=${min_size} desired=${desired} azs=${az_count} (${asg_name})"
  else
    record_result FAIL "$label ASG" "min=${min_size} desired=${desired} azs=${az_count}; need min>=2, desired>=2, azs>=2"
  fi

  if [[ -z "$instance_ids" || "$instance_ids" == "None" ]]; then
    record_result FAIL "$label public IPs" "no running instances in ${asg_name}"
    return 0
  fi

  # shellcheck disable=SC2086
  awsq ec2 describe-instances \
    --region "$region" \
    --instance-ids $instance_ids \
    --output json > "${ARTIFACT_DIR}/${label}-instances.json"

  public_ip_count="$(count_running_public_ips "${ARTIFACT_DIR}/${label}-instances.json")"
  public_ip_count="${public_ip_count//$'\r'/}"

  if [[ "$public_ip_count" == "0" ]]; then
    record_result PASS "$label public IPs" "no public IPs on ASG instances"
  else
    record_result FAIL "$label public IPs" "${public_ip_count} instance(s) have a public IP"
  fi
}

check_spoke_private_route() {
  local label="$1"
  local region="$2"
  local vpc_cidr="$3"
  local vpc_id=""
  local counts=""
  local syslog_routes=""
  local tokyo_full_routes=""
  local db_routes=""

  vpc_id="$(
    awsq ec2 describe-vpcs \
      --region "$region" \
      --filters "Name=cidr-block,Values=${vpc_cidr}" \
      --query 'Vpcs[0].VpcId' \
      --output text
  )"
  vpc_id="${vpc_id//$'\r'/}"

  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    record_result FAIL "$label TGW route" "VPC ${vpc_cidr} not found in ${region}"
    return 0
  fi

  # Do not use aws --query length(RouteTables[].Routes[?...]) without a trailing []:
  # that returns the number of route tables (often 3), not matching routes.
  awsq ec2 describe-route-tables \
    --region "$region" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --output json > "${ARTIFACT_DIR}/${label}-route-tables.json"

  counts="$(
    count_spoke_tgw_routes \
      "${ARTIFACT_DIR}/${label}-route-tables.json" \
      "$SYSLOG_CIDR" \
      "$TOKYO_CIDR" \
      "$DB_CIDR_A" \
      "$DB_CIDR_B"
  )"
  counts="${counts//$'\r'/}"
  syslog_routes="$(echo "$counts" | awk '{print $1}')"
  tokyo_full_routes="$(echo "$counts" | awk '{print $2}')"
  db_routes="$(echo "$counts" | awk '{print $3}')"

  if [[ "$syslog_routes" -ge 1 && "$tokyo_full_routes" == "0" && "$db_routes" == "0" ]]; then
    record_result PASS "$label TGW route" "private path to ${SYSLOG_CIDR} only; no ${TOKYO_CIDR} or DB CIDRs"
  else
    record_result FAIL "$label TGW route" "syslog_routes=${syslog_routes} tokyo_full=${tokyo_full_routes} db_routes=${db_routes}"
  fi
}

check_no_vpn() {
  local region="$1"
  local vgws=""
  local vpngws=""

  vgws="$(
    awsq ec2 describe-vpn-gateways \
      --region "$region" \
      --query 'length(VpnGateways[?State!=`deleted`])' \
      --output text
  )"
  vpngws="$(
    awsq ec2 describe-vpn-connections \
      --region "$region" \
      --query 'length(VpnConnections[?State!=`deleted`])' \
      --output text 2>/dev/null || echo 0
  )"
  vgws="${vgws//$'\r'/}"
  vpngws="${vpngws//$'\r'/}"

  if [[ "${vgws:-0}" == "0" && "${vpngws:-0}" == "0" ]]; then
    record_result PASS "no VPN ${region}" "no virtual private gateways or VPN connections"
  else
    record_result FAIL "no VPN ${region}" "vgw=${vgws} vpn=${vpngws}"
  fi
}

wait_for_target_health() {
  local region="$1"
  local tg_name="$2"
  local timeout_seconds="$3"
  local elapsed=0
  local tg_arn=""
  local states=""

  tg_arn="$(
    awsq elbv2 describe-target-groups \
      --region "$region" \
      --names "$tg_name" \
      --query 'TargetGroups[0].TargetGroupArn' \
      --output text
  )"
  tg_arn="${tg_arn//$'\r'/}"

  if [[ -z "$tg_arn" || "$tg_arn" == "None" ]]; then
    echo ""
    return 1
  fi

  while (( elapsed <= timeout_seconds )); do
    states="$(
      awsq elbv2 describe-target-health \
        --region "$region" \
        --target-group-arn "$tg_arn" \
        --query 'TargetHealthDescriptions[].TargetHealth.State' \
        --output text
    )"
    states="${states//$'\r'/}"
    log "${tg_name} target health: ${states:-none}"

    if [[ -n "$states" && "$states" != "None" ]] && ! grep -Eq 'unhealthy|unused|draining|initial|unavailable' <<<"$states"; then
      if grep -qw healthy <<<"$states"; then
        printf '%s' "$states"
        return 0
      fi
    fi

    sleep 15
    elapsed=$((elapsed + 15))
  done

  printf '%s' "${states:-none}"
  return 1
}

check_promtail_userdata() {
  local label="$1"
  local region="$2"
  local asg_name="$3"
  local lt_id=""
  local userdata_b64=""
  local userdata_file="${ARTIFACT_DIR}/userdata-${label}.txt"

  lt_id="$(
    awsq autoscaling describe-auto-scaling-groups \
      --region "$region" \
      --auto-scaling-group-names "$asg_name" \
      --query 'AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId' \
      --output text
  )"
  lt_id="${lt_id//$'\r'/}"

  if [[ -z "$lt_id" || "$lt_id" == "None" ]]; then
    record_result FAIL "$label Promtail" "no launch template on ${asg_name}"
    return 0
  fi

  userdata_b64="$(
    awsq ec2 describe-launch-template-versions \
      --region "$region" \
      --launch-template-id "$lt_id" \
      --versions '$Latest' \
      --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' \
      --output text
  )"
  userdata_b64="${userdata_b64//$'\r'/}"

  if [[ -z "$userdata_b64" || "$userdata_b64" == "None" ]]; then
    record_result FAIL "$label Promtail" "launch template user-data is empty"
    return 0
  fi

  printf '%s' "$userdata_b64" | base64 -d > "$userdata_file" 2>/dev/null ||
    printf '%s' "$userdata_b64" | base64 -D > "$userdata_file"

  if grep -q "${LOKI_NLB_DNS}:3100/loki/api/v1/push" "$userdata_file" &&
    ! grep -q '<LOKI_SERVER_IP>' "$userdata_file"; then
    record_result PASS "$label Promtail" "user-data pushes to http://${LOKI_NLB_DNS}:3100/loki/api/v1/push"
  else
    record_result FAIL "$label Promtail" "user-data missing Loki NLB push URL (see ${userdata_file})"
  fi
}

ssm_loki_ready() {
  local instance_ids="$1"
  local first_id=""
  local command_id=""
  local elapsed=0
  local status=""
  local output=""
  local params_file="${ARTIFACT_DIR}/ssm-loki-ready.json"
  local attempt_wait=0

  first_id="$(echo "$instance_ids" | awk '{print $1}')"
  first_id="${first_id//$'\r'/}"

  if [[ -z "$first_id" ]]; then
    record_result FAIL "Loki /ready via SSM" "no SIEM_Server instances found"
    return 0
  fi

  cat > "$params_file" <<'EOF'
{
  "commands": [
    "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 http://127.0.0.1:3100/ready"
  ]
}
EOF

  # Loki can return 503 on /ready for a few minutes after the NLB target is TCP-healthy.
  while (( elapsed <= SIEM_WAIT_SECONDS )); do
    command_id=""
    status=""
    output=""
    attempt_wait=0

    # shellcheck disable=SC2086
    if ! command_id="$(
      awsq ssm send-command \
        --region "$HUB_REGION" \
        --instance-ids $instance_ids \
        --document-name AWS-RunShellScript \
        --comment "Armageddon E2E Loki /ready" \
        --parameters "file://$(to_native_path "$params_file")" \
        --query 'Command.CommandId' \
        --output text
    )"; then
      record_result FAIL "Loki /ready via SSM" "send-command failed (SSM agent/role on SIEM instances?)"
      return 0
    fi
    command_id="${command_id//$'\r'/}"
    log "SSM command ${command_id} on SIEM instances: ${instance_ids}"

    while (( attempt_wait <= SSM_WAIT_SECONDS )); do
      status="$(
        awsq ssm get-command-invocation \
          --region "$HUB_REGION" \
          --command-id "$command_id" \
          --instance-id "$first_id" \
          --query 'Status' \
          --output text 2>/dev/null || echo "Pending"
      )"
      status="${status//$'\r'/}"

      if [[ "$status" == "Success" || "$status" == "Failed" || "$status" == "Cancelled" || "$status" == "TimedOut" ]]; then
        break
      fi

      sleep 5
      attempt_wait=$((attempt_wait + 5))
    done

    output="$(
      awsq ssm get-command-invocation \
        --region "$HUB_REGION" \
        --command-id "$command_id" \
        --instance-id "$first_id" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null || true
    )"
    output="${output//$'\r'/}"
    output="$(echo "$output" | tr -d '[:space:]')"

    if [[ "$output" == "200" ]]; then
      record_result PASS "Loki /ready via SSM" "HTTP 200 on ${first_id} (and command sent to all SIEM instances)"
      return 0
    fi

    log "Loki /ready not ready yet (status=${status} body='${output}'); retrying"
    sleep 15
    elapsed=$((elapsed + 15 + attempt_wait))
  done

  record_result FAIL "Loki /ready via SSM" "status=${status} body='${output}' on ${first_id}"
}

# ==============================================================================
# Regions under test
# ==============================================================================

SITE_KEYS=(tokyo new_york london sao_paulo sydney hong_kong california)
SITE_LABELS=(Tokyo "New York" London "Sao Paulo" Sydney "Hong Kong" California)
SITE_REGIONS=(ap-northeast-1 us-east-1 eu-west-2 sa-east-1 ap-southeast-2 ap-east-1 us-west-1)
SITE_CIDRS=(10.230.0.0/16 10.231.0.0/16 10.232.0.0/16 10.233.0.0/16 10.234.0.0/16 10.235.0.0/16 10.236.0.0/16)
SITE_ASGS=(tokyo-web-server-asg new_york-web-server-asg london-web-server-asg sao-paulo-web-server-asg sydney-web-server-asg hong_kong-web-server-asg california-web-server-asg)
SITE_ALB_OUTPUTS=(tokyo_alb_dns new_york_alb_dns london_alb_dns sao_paulo_alb_dns sydney_alb_dns hong_kong_alb_dns california_alb_dns)

# ==============================================================================
# Run
# ==============================================================================

section "Armageddon 1.2.1  |  3-run-lab.sh"
log "Repository root: $REPO_ROOT"
log "Artifacts: $ARTIFACT_DIR"
log "Phases: 01-07 Terraform, 08-15 live E2E"

require_command aws
require_command terraform
require_command grep
require_command tee
require_command base64
configure_python
configure_curl

export AWS_PAGER=""
export AWS_CLI_FILE_ENCODING="UTF-8"
export AWS_CLI_OUTPUT_ENCODING="UTF-8"
chcp.com 65001 >/dev/null 2>&1 || true

[[ -d "$TF_DIR" ]] || die "Terraform directory not found: $TF_DIR"

section "01/15 Prerequisite versions"
aws --version
terraform version
"$PYTHON_BIN" --version
"$CURL_BIN" --version | head -n 1
awsq sts get-caller-identity
log "Checking opt-in regions ap-east-1 (Hong Kong) and ap-northeast-3 (Osaka)"
awsq ec2 describe-regions \
  --region us-east-1 \
  --query "Regions[?RegionName=='ap-east-1' || RegionName=='ap-northeast-3'].[RegionName,OptInStatus]" \
  --output table

cd "$TF_DIR"

if ! $SKIP_TERRAFORM; then
  section "02/15 Terraform init"
  log "Backend: s3://armageddon-tiqs-state-files/armageddon-class6.tfstate (us-east-1)"
  terraform init -upgrade
  success "terraform init completed"

  section "03/15 Terraform fmt"
  terraform fmt -recursive
  success "terraform fmt completed"

  section "04/15 Terraform validate"
  terraform validate
  success "terraform validate completed"

  section "05/15 Terraform plan"
  PLAN_FILE="${ARTIFACT_DIR}/tfplan"
  PLAN_FILE_NATIVE="$(to_native_path "$PLAN_FILE")"
  terraform plan -out="$PLAN_FILE_NATIVE"
  terraform show -no-color "$PLAN_FILE_NATIVE" > "${ARTIFACT_DIR}/terraform-plan.txt"
  success "Plan saved to ${ARTIFACT_DIR}/terraform-plan.txt"

  if $PLAN_ONLY; then
    success_section "05/15 Plan-only run complete"
    log "Rerun without --plan-only to apply and test."
    exit 0
  fi

  section "06/15 Terraform apply"
  if ! $SKIP_APPLY; then
    terraform apply -auto-approve "$PLAN_FILE_NATIVE"
    success "terraform apply completed"
    sleep_with_message 30 "allowing ALBs, ASGs, and TGW routes to stabilize"
  else
    warn "Terraform apply skipped; testing the existing deployment."
  fi
else
  section "02/15 Terraform init"
  warn "Skipped (--skip-terraform)"
  section "03/15 Terraform fmt"
  warn "Skipped (--skip-terraform)"
  section "04/15 Terraform validate"
  warn "Skipped (--skip-terraform)"
  section "05/15 Terraform plan"
  warn "Skipped (--skip-terraform)"
  section "06/15 Terraform apply"
  warn "Skipped (--skip-terraform)"
fi

section "07/15 Terraform outputs"
terraform output > "${ARTIFACT_DIR}/terraform-outputs.txt"
terraform output -json > "${ARTIFACT_DIR}/terraform-outputs.json"

TOKYO_ALB_URL="$(tf_output_required tokyo_alb_dns)"
NEW_YORK_ALB_URL="$(tf_output_required new_york_alb_dns)"
LONDON_ALB_URL="$(tf_output_required london_alb_dns)"
SAO_PAULO_ALB_URL="$(tf_output_required sao_paulo_alb_dns)"
SYDNEY_ALB_URL="$(tf_output_required sydney_alb_dns)"
HONG_KONG_ALB_URL="$(tf_output_required hong_kong_alb_dns)"
CALIFORNIA_ALB_URL="$(tf_output_required california_alb_dns)"
AURORA_ENDPOINT="$(tf_output_required aurora_cluster_endpoint)"
SYSLOG_FROM_TF="$(tf_output_required a3_syslog_cidr_spokes_may_reach)"
LOKI_NLB_DNS="$(tf_json_get "${ARTIFACT_DIR}/terraform-outputs.json" a3_loki_ingest_nlb dns_name)"
GRAFANA_ALB_DNS="$(tf_json_get "${ARTIFACT_DIR}/terraform-outputs.json" a3_grafana_internal_alb dns_name)"
SIEM_NACL_ID="$(tf_output_required a3_siem_nacl_id)"
AURORA_SG_SOURCE="$(tf_json_get "${ARTIFACT_DIR}/terraform-outputs.json" a3_aurora_ingress_sources source_security_group_id)"
AURORA_NO_VPN="$(tf_json_get "${ARTIFACT_DIR}/terraform-outputs.json" a3_aurora_ingress_sources no_vpn)"
GRAFANA_ALLOW_CIDR="$(tf_json_get "${ARTIFACT_DIR}/terraform-outputs.json" a3_grafana_internal_alb allowed_ingress_cidr)"

SITE_ALB_URLS=(
  "$TOKYO_ALB_URL"
  "$NEW_YORK_ALB_URL"
  "$LONDON_ALB_URL"
  "$SAO_PAULO_ALB_URL"
  "$SYDNEY_ALB_URL"
  "$HONG_KONG_ALB_URL"
  "$CALIFORNIA_ALB_URL"
)

printf '%-22s %s\n' \
  "TOKYO_ALB" "$TOKYO_ALB_URL" \
  "NEW_YORK_ALB" "$NEW_YORK_ALB_URL" \
  "LONDON_ALB" "$LONDON_ALB_URL" \
  "SAO_PAULO_ALB" "$SAO_PAULO_ALB_URL" \
  "SYDNEY_ALB" "$SYDNEY_ALB_URL" \
  "HONG_KONG_ALB" "$HONG_KONG_ALB_URL" \
  "CALIFORNIA_ALB" "$CALIFORNIA_ALB_URL" \
  "LOKI_NLB" "$LOKI_NLB_DNS" \
  "GRAFANA_ALB" "$GRAFANA_ALB_DNS" \
  "AURORA" "$AURORA_ENDPOINT" \
  "SYSLOG_CIDR" "$SYSLOG_FROM_TF"

save_session_values

# ------------------------------------------------------------------------------
# Live E2E
# ------------------------------------------------------------------------------

section "08/15 Public apps on port 80"
log "Expect HTTP 200 and the Samurai Katana page from every regional ALB."
for i in "${!SITE_KEYS[@]}"; do
  assert_http_app "${SITE_KEYS[$i]}" "${SITE_ALB_URLS[$i]}"
done

section "09/15 ALB listeners are port 80 only"
for i in "${!SITE_KEYS[@]}"; do
  check_listener_port_80_only "${SITE_KEYS[$i]}" "${SITE_REGIONS[$i]}" "${SITE_ALB_URLS[$i]}"
done

section "10/15 ASGs, two AZs, no public IPs"
for i in "${!SITE_KEYS[@]}"; do
  check_asg "${SITE_KEYS[$i]}" "${SITE_REGIONS[$i]}" "${SITE_ASGS[$i]}"
done

siem_min="$(
  awsq autoscaling describe-auto-scaling-groups \
    --region "$HUB_REGION" \
    --query "AutoScalingGroups[?Tags[?Key=='Name' && Value=='SIEM_Server']] | [0].MinSize" \
    --output text
)"
siem_max="$(
  awsq autoscaling describe-auto-scaling-groups \
    --region "$HUB_REGION" \
    --query "AutoScalingGroups[?Tags[?Key=='Name' && Value=='SIEM_Server']] | [0].MaxSize" \
    --output text
)"
siem_azs="$(
  awsq autoscaling describe-auto-scaling-groups \
    --region "$HUB_REGION" \
    --query "length(AutoScalingGroups[?Tags[?Key=='Name' && Value=='SIEM_Server']] | [0].AvailabilityZones)" \
    --output text
)"
siem_min="${siem_min//$'\r'/}"
siem_max="${siem_max//$'\r'/}"
siem_azs="${siem_azs//$'\r'/}"

if [[ "$siem_min" == "2" && "$siem_max" == "2" && "$siem_azs" -ge 2 ]]; then
  record_result PASS "SIEM ASG A.1" "min=2 max=2 azs=${siem_azs}"
else
  record_result FAIL "SIEM ASG A.1" "min=${siem_min} max=${siem_max} azs=${siem_azs}; expected min=max=2 across 2 AZs"
fi

section "11/15 A.4 Terraform artifacts (send-only syslog)"
if [[ "$SYSLOG_FROM_TF" == "$SYSLOG_CIDR" ]]; then
  record_result PASS "a3_syslog_cidr" "$SYSLOG_FROM_TF"
else
  record_result FAIL "a3_syslog_cidr" "expected ${SYSLOG_CIDR}, got ${SYSLOG_FROM_TF}"
fi

spoke_routes_json="$(tf_json_get "${ARTIFACT_DIR}/terraform-outputs.json" a3_spoke_tgw_routes_to_syslog_only)"
if "$PYTHON_BIN" - "$spoke_routes_json" "$SYSLOG_CIDR" <<'PY'; then
import json, sys
routes = json.loads(sys.argv[1])
expected = sys.argv[2]
bad = [k for k, v in routes.items() if v != expected]
sys.exit(1 if bad else 0)
PY
  record_result PASS "a3_spoke_tgw_routes" "all six spokes route ${SYSLOG_CIDR}"
else
  record_result FAIL "a3_spoke_tgw_routes" "${spoke_routes_json}"
fi

siem_cidrs="$(tf_json_get "${ARTIFACT_DIR}/terraform-outputs.json" a3_siem_subnet_cidrs)"
db_cidrs="$(tf_json_get "${ARTIFACT_DIR}/terraform-outputs.json" a3_db_subnet_cidrs)"
if "$PYTHON_BIN" - "$siem_cidrs" "$db_cidrs" <<'PY'; then
import json, sys
siem = set(json.loads(sys.argv[1]))
db = set(json.loads(sys.argv[2]))
sys.exit(0 if siem and db and siem.isdisjoint(db) else 1)
PY
  record_result PASS "SIEM vs DB subnets" "SIEM ${siem_cidrs} disjoint from DB ${db_cidrs}"
else
  record_result FAIL "SIEM vs DB subnets" "SIEM ${siem_cidrs} DB ${db_cidrs}"
fi

if [[ "$GRAFANA_ALLOW_CIDR" == "$TOKYO_CIDR" ]]; then
  record_result PASS "Grafana SG ingress" "port 3000 allowed from ${TOKYO_CIDR} only"
else
  record_result FAIL "Grafana SG ingress" "allowed_ingress_cidr=${GRAFANA_ALLOW_CIDR}"
fi

if [[ "$AURORA_NO_VPN" == "true" && -n "$AURORA_SG_SOURCE" ]]; then
  record_result PASS "Aurora ingress A.3" "5432 from ${AURORA_SG_SOURCE}; no_vpn=true; region=${HUB_REGION}"
else
  record_result FAIL "Aurora ingress A.3" "no_vpn=${AURORA_NO_VPN} source=${AURORA_SG_SOURCE}"
fi

loki_internal="$(tf_json_get "${ARTIFACT_DIR}/terraform-outputs.json" a3_loki_ingest_nlb internal)"
if [[ "$loki_internal" == "true" ]]; then
  record_result PASS "Loki NLB internal" "${LOKI_NLB_DNS}:3100 is internal"
else
  record_result FAIL "Loki NLB internal" "internal=${loki_internal}"
fi

section "12/15 Live spoke routes and no VPN"
for i in "${!SITE_KEYS[@]}"; do
  if [[ "${SITE_KEYS[$i]}" == "tokyo" ]]; then
    continue
  fi
  check_spoke_private_route "${SITE_KEYS[$i]}" "${SITE_REGIONS[$i]}" "${SITE_CIDRS[$i]}"
done

for i in "${!SITE_KEYS[@]}"; do
  check_no_vpn "${SITE_REGIONS[$i]}"
done
check_no_vpn ap-northeast-3

section "13/15 Restricted AZs and public subnets"
tokyo_vpc_id="$(
  awsq ec2 describe-vpcs \
    --region "$HUB_REGION" \
    --filters "Name=cidr-block,Values=${TOKYO_CIDR}" \
    --query 'Vpcs[0].VpcId' \
    --output text
)"
tokyo_vpc_id="${tokyo_vpc_id//$'\r'/}"

public_subnets_1d="$(
  awsq ec2 describe-subnets \
    --region "$HUB_REGION" \
    --filters "Name=vpc-id,Values=${tokyo_vpc_id}" "Name=availability-zone,Values=ap-northeast-1d" \
    --query 'Subnets[].{Id:SubnetId,Cidr:CidrBlock,Public:MapPublicIpOnLaunch,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output json
)"
printf '%s\n' "$public_subnets_1d" > "${ARTIFACT_DIR}/tokyo-subnets-1d.json"

public_named_1d="$(
  "$PYTHON_BIN" - "${ARTIFACT_DIR}/tokyo-subnets-1d.json" <<'PY'
import json, sys
subs = json.loads(open(sys.argv[1], encoding="utf-8").read())
hits = [s for s in subs if (s.get("Name") or "").lower().find("public") >= 0 or s.get("Public") is True]
print(len(hits))
PY
)"

if [[ "$public_named_1d" == "0" ]]; then
  record_result PASS "AZ ap-northeast-1d" "no public subnet in the SIEM/DB AZ"
else
  record_result FAIL "AZ ap-northeast-1d" "public subnet present in restricted AZ"
fi

public_named_1c="$(
  awsq ec2 describe-subnets \
    --region "$HUB_REGION" \
    --filters "Name=vpc-id,Values=${tokyo_vpc_id}" "Name=availability-zone,Values=ap-northeast-1c" \
    --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,Public:MapPublicIpOnLaunch}' \
    --output json
)"
printf '%s\n' "$public_named_1c" > "${ARTIFACT_DIR}/tokyo-subnets-1c.json"
has_public_1c="$(
  "$PYTHON_BIN" - "${ARTIFACT_DIR}/tokyo-subnets-1c.json" <<'PY'
import json, sys
subs = json.loads(open(sys.argv[1], encoding="utf-8").read())
hits = [s for s in subs if (s.get("Name") or "").lower().find("public") >= 0 or s.get("Public") is True]
print("yes" if hits else "no")
PY
)"
if [[ "$has_public_1c" == "yes" ]]; then
  record_result WARN "AZ ap-northeast-1c" "account only has 1a/1c/1d; 1c is both app-public and restricted so ALB + Aurora/NLB can each span two AZs"
else
  record_result PASS "AZ ap-northeast-1c" "no public subnet"
fi

nacl_deny_grafana="$(
  awsq ec2 describe-network-acls \
    --region "$HUB_REGION" \
    --network-acl-ids "$SIEM_NACL_ID" \
    --query "length(NetworkAcls[0].Entries[?Egress==\`false\` && RuleAction=='deny' && PortRange.From==\`3000\`])" \
    --output text
)"
nacl_deny_ssh="$(
  awsq ec2 describe-network-acls \
    --region "$HUB_REGION" \
    --network-acl-ids "$SIEM_NACL_ID" \
    --query "length(NetworkAcls[0].Entries[?Egress==\`false\` && RuleAction=='deny' && PortRange.From==\`22\`])" \
    --output text
)"
nacl_deny_grafana="${nacl_deny_grafana//$'\r'/}"
nacl_deny_ssh="${nacl_deny_ssh//$'\r'/}"

if [[ "$nacl_deny_grafana" -ge 1 && "$nacl_deny_ssh" -ge 1 ]]; then
  record_result PASS "SIEM NACL A.3" "${SIEM_NACL_ID} denies 3000 and 22"
else
  record_result FAIL "SIEM NACL A.3" "deny3000=${nacl_deny_grafana} deny22=${nacl_deny_ssh}"
fi

section "14/15 Loki ingest and Grafana (Japan)"
loki_states=""
if loki_states="$(wait_for_target_health "$HUB_REGION" "siem-loki-tg" "$SIEM_WAIT_SECONDS")"; then
  record_result PASS "Loki NLB targets" "healthy (${loki_states})"
else
  record_result FAIL "Loki NLB targets" "not healthy after ${SIEM_WAIT_SECONDS}s (${loki_states:-none})"
fi

grafana_states=""
if grafana_states="$(wait_for_target_health "$HUB_REGION" "siem-grafana-tg" "$SIEM_WAIT_SECONDS")"; then
  record_result PASS "Grafana ALB targets" "healthy (${grafana_states}) — Grafana is up on :3000 inside Tokyo"
else
  record_result FAIL "Grafana ALB targets" "not healthy after ${SIEM_WAIT_SECONDS}s (${grafana_states:-none})"
fi

siem_ids="$(
  awsq ec2 describe-instances \
    --region "$HUB_REGION" \
    --filters "Name=tag:Name,Values=SIEM_Server" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text
)"
siem_ids="${siem_ids//$'\r'/}"
ssm_loki_ready "$siem_ids"

laptop_loki="$(http_get "http://${LOKI_NLB_DNS}:3100/ready" "${ARTIFACT_DIR}/loki-from-laptop.txt")"
if [[ "$laptop_loki" == "000" ]]; then
  record_result PASS "Loki NLB not public" "laptop curl returned 000 (internal NLB as required)"
else
  record_result FAIL "Loki NLB not public" "laptop reached Loki with HTTP ${laptop_loki}; NLB should be internal"
fi

section "15/15 Promtail, Aurora, and syslog S3 (Japan)"
for i in "${!SITE_KEYS[@]}"; do
  check_promtail_userdata "${SITE_KEYS[$i]}" "${SITE_REGIONS[$i]}" "${SITE_ASGS[$i]}"
done

aurora_az="$(
  awsq rds describe-db-clusters \
    --region "$HUB_REGION" \
    --db-cluster-identifier aurora-postgres-cluster \
    --query 'DBClusters[0].AvailabilityZones' \
    --output text
)"
aurora_encrypted="$(
  awsq rds describe-db-clusters \
    --region "$HUB_REGION" \
    --db-cluster-identifier aurora-postgres-cluster \
    --query 'DBClusters[0].StorageEncrypted' \
    --output text
)"
aurora_az="${aurora_az//$'\r'/}"
aurora_encrypted="${aurora_encrypted//$'\r'/}"

if [[ "$AURORA_ENDPOINT" == *".ap-northeast-1."* && "$aurora_encrypted" == "True" ]]; then
  record_result PASS "Aurora PII in Japan" "${AURORA_ENDPOINT} encrypted=${aurora_encrypted} azs=${aurora_az}"
else
  record_result FAIL "Aurora PII in Japan" "endpoint=${AURORA_ENDPOINT} encrypted=${aurora_encrypted}"
fi

tokyo_ec2_sg_id="$(
  awsq ec2 describe-security-groups \
    --region "$HUB_REGION" \
    --filters "Name=vpc-id,Values=${tokyo_vpc_id}" "Name=group-name,Values=tokyo-ec2-sg" \
    --query 'SecurityGroups[0].GroupId' \
    --output text
)"
tokyo_ec2_sg_id="${tokyo_ec2_sg_id//$'\r'/}"
if [[ "$AURORA_SG_SOURCE" == "$tokyo_ec2_sg_id" ]]; then
  record_result PASS "Aurora SG source" "5432 only from tokyo-ec2-sg (${tokyo_ec2_sg_id})"
else
  record_result FAIL "Aurora SG source" "output=${AURORA_SG_SOURCE} live tokyo-ec2-sg=${tokyo_ec2_sg_id}"
fi

syslog_bucket="$(
  awsq s3api list-buckets \
    --query "Buckets[?starts_with(Name, 'syslog-bucket-')].Name | [0]" \
    --output text
)"
dest_bucket="$(
  awsq s3api list-buckets \
    --query "Buckets[?starts_with(Name, 'destination-')].Name | [0]" \
    --output text
)"
syslog_bucket="${syslog_bucket//$'\r'/}"
dest_bucket="${dest_bucket//$'\r'/}"

if [[ -n "$syslog_bucket" && "$syslog_bucket" != "None" ]]; then
  syslog_region="$(awsq s3api get-bucket-location --bucket "$syslog_bucket" --query 'LocationConstraint' --output text)"
  syslog_region="${syslog_region//$'\r'/}"
  [[ "$syslog_region" == "None" || -z "$syslog_region" ]] && syslog_region="us-east-1"
  if [[ "$syslog_region" == "ap-northeast-1" ]]; then
    record_result PASS "Syslog S3 in Japan" "${syslog_bucket} in ${syslog_region}"
  else
    record_result FAIL "Syslog S3 in Japan" "${syslog_bucket} in ${syslog_region}"
  fi
else
  record_result FAIL "Syslog S3 in Japan" "syslog-bucket-* not found"
fi

if [[ -n "$dest_bucket" && "$dest_bucket" != "None" ]]; then
  dest_region="$(awsq s3api get-bucket-location --bucket "$dest_bucket" --query 'LocationConstraint' --output text)"
  dest_region="${dest_region//$'\r'/}"
  if [[ "$dest_region" == "ap-northeast-3" ]]; then
    record_result PASS "Syslog replica in Japan" "${dest_bucket} in Osaka ${dest_region}"
  else
    record_result FAIL "Syslog replica in Japan" "${dest_bucket} in ${dest_region}"
  fi
else
  record_result WARN "Syslog replica in Japan" "destination-* bucket not found"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

print_results_table() {
  local status=""
  local name=""
  local detail=""
  local color=""

  printf '\n%b%-6s  %-28s  %s%b\n' "$WHITE" "RESULT" "CHECK" "DETAIL" "$RESET"
  printf '%b%s%b\n' "$DIM" "------  ----------------------------  ------------------------------" "$RESET"

  while IFS=$'\t' read -r status name detail; do
    case "$status" in
      PASS) color="$GREEN" ;;
      FAIL) color="$RED" ;;
      WARN) color="$YELLOW" ;;
      *) color="$WHITE" ;;
    esac
    printf '%b%-6s%b  %-28s  %s\n' "$color" "$status" "$RESET" "$name" "$detail"
  done < "$RESULTS_FILE"
}

print_results_table

if (( FAIL_COUNT > 0 )); then
  fail_section "Armageddon E2E finished with failures"
else
  success_section "Armageddon E2E completed successfully"
fi

log "Results: ${PASS_COUNT} passed, ${WARN_COUNT} warning(s), ${FAIL_COUNT} failed"
log "Artifacts: $ARTIFACT_DIR"
log "Run log: $RUN_LOG"
log "Reusable session values: $LATEST_SESSION_FILE"
action "Grafana is internal. SSM to a Tokyo app instance (no SSM role today) or use the Grafana TG health result above."
action "When finished: bash scripts/4-teardown-lab.sh"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
