#!/usr/bin/env bash
# shellcheck shell=bash
#
# common.sh — shared constants, guards and helpers for the Evelio prod updater.
#
# UNLIKE the staging tooling, this repo deliberately DOES touch production.
# Everything dangerous therefore lives behind: dry-run-by-default, an explicit
# --apply, a verified backup, and a named confirmation. Read CLAUDE.md before
# changing anything in here.

set -euo pipefail

# ---------------------------------------------------------------- locations --
UPD_ROOT="${UPD_ROOT:-/opt/evelio-updating}"
TOOL_DIR="$UPD_ROOT/updating-tooling"
SRC_REPO="$UPD_ROOT/src"                       # this tool's private clone
RELEASES_DIR="$UPD_ROOT/releases"
RELEASE_DIR="$RELEASES_DIR/current"            # exactly ONE kept release
FRONTEND_BUILD_ENV="$UPD_ROOT/frontend-build.env"
TESTVENV="$UPD_ROOT/.testvenv"
LOG_DIR="$UPD_ROOT/logs"

GIT_URL="git@github.com:Evelio-Development/app.evelio.git"
GIT_REF="origin/main"                          # tip of main ONLY. No override.

# --------------------------------------------------------------- prod paths --
BACKEND_DIR="/opt/tesla-oauth"                 # backend RUNS from here
WEBROOT="/var/www/evelio-app"                  # app.evelio.net
INGEST_DIR="/opt/telemetry-ingest"             # fetch_odometer.py (root cron)
CADDYFILE="/etc/caddy/Caddyfile"
PROD_ENV_FILE="/etc/tesla-oauth.env"

# Overridable ONLY so the revert machinery can be rehearsed against the staging
# container before it is ever pointed at prod. The defaults are production; no
# script sets these, and nothing in normal operation should.
PG_CONTAINER="${PG_CONTAINER:-telemetry-postgres}"   # PROD container (:5432)
PG_DB="${PG_DB:-evelio}"
PG_USER="${PG_USER:-evelio}"
STAGING_PG_CONTAINER="telemetry-postgres-staging"  # tests only, never prod

BACKEND_SERVICES=(tesla-oauth onboarding-worker)
INGEST_SERVICE="telemetry-ingest"

# ------------------------------------------------------------------ tunables --
ROLLBACK_PROMPT_TIMEOUT="${ROLLBACK_PROMPT_TIMEOUT:-300}"  # seconds; documented
HEALTH_SETTLE_SECS="${HEALTH_SETTLE_SECS:-10}"             # crash-loop window
DISK_MARGIN_GB="${DISK_MARGIN_GB:-5}"

# ------------------------------------------------------------------ deploy set --
# Which tracked repo-root files become backend code in $BACKEND_DIR.
# Excluded on purpose: test_*.py (noise in a run-dir), fetch_odometer.py and
# ingest_from_dockerlogs.py (they live in $INGEST_DIR), frontend/ and
# server-config/ (handled by their own steps), *.md, .gitignore.
backend_deploy_files() {   # $1 = repo dir ; prints relative paths
  git -C "$1" ls-tree --name-only HEAD \
    | grep -E '\.(py|sql|sh)$' \
    | grep -Ev '^test_' \
    | grep -Ev '^(fetch_odometer\.py|ingest_from_dockerlogs\.py)$'
}

# Files/dirs in $BACKEND_DIR that this tool must NEVER mirror, delete, or treat
# as drift. These are live runtime state, secrets, or human rollback material.
PROTECTED=(
  tokens
  .venv
  __pycache__
  _bak_archive
  pending_registrations.json
)
# Glob patterns, matched against the basename.
PROTECTED_GLOBS=( '*.env' '*.bak.*' '*.pyc' '.*.swp' )

# The live run-dir holds CRLF files (they were deployed from a Windows checkout);
# the repo is LF. Every comparison this tool makes must therefore ignore line
# endings, or literally every file reads as "changed" and the drift gate becomes
# noise. update.sh writes LF, so this converges over time — but never assume it.
norm_cat() { sed 's/\r$//' "$1"; }

same_content() {  # $1 $2 — true if identical ignoring CRLF/LF
  [[ -f "$1" && -f "$2" ]] || return 1
  cmp -s <(norm_cat "$1") <(norm_cat "$2")
}

norm_sha() { sed 's/\r$//' "$1" | sha256sum | awk '{print $1}'; }

is_protected() {  # $1 = path relative to $BACKEND_DIR
  local rel="$1" top="${1%%/*}" base p g
  base="$(basename "$rel")"
  for p in "${PROTECTED[@]}"; do
    [[ "$top" == "$p" || "$rel" == "$p" ]] && return 0
  done
  for g in "${PROTECTED_GLOBS[@]}"; do
    # shellcheck disable=SC2053
    [[ "$base" == $g ]] && return 0
  done
  return 1
}

# ------------------------------------------------------------------- output --
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_OFF=''
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()    { printf '%s ok %s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%sWARN%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()   { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
hdr()   { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_OFF"; }

# In dry-run, `run` prints instead of executing. Every mutating command in this
# repo goes through `run` (or is explicitly guarded by $APPLY).
APPLY="${APPLY:-0}"
run() {
  if (( APPLY )); then "$@"; else printf '   [dry-run] %s\n' "$*"; fi
}
run_sh() {  # for pipelines/redirection; $1 = shell string
  if (( APPLY )); then bash -c "$1"; else printf '   [dry-run] %s\n' "$1"; fi
}

# ------------------------------------------------------------------- guards --
assert_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root (sudo) — this deploys production."
}

assert_prod_layout() {
  [[ -d "$BACKEND_DIR"    ]] || die "missing backend run-dir $BACKEND_DIR"
  [[ -d "$WEBROOT"        ]] || die "missing webroot $WEBROOT"
  [[ -f "$PROD_ENV_FILE"  ]] || die "missing $PROD_ENV_FILE"
  docker inspect "$PG_CONTAINER" >/dev/null 2>&1 \
    || die "prod postgres container '$PG_CONTAINER' not found"
}

# Refuse to run while a staging env holds the shared dev URL, or mid-spinup:
# not a safety boundary, just prevents confusing overlapping work.
warn_if_staging_active() {
  local f=/opt/evelio-staging/.active-env
  [[ -s "$f" ]] && warn "a staging env is currently active ($(cat "$f")) — unrelated to prod, but check you meant to deploy prod."
  return 0
}

# Typed confirmation. Returns non-zero if the user declines.
# In non-interactive mode it ALWAYS declines — never assume consent.
confirm() {   # $1 = prompt, $2 = word that must be typed
  local prompt="$1" word="$2" answer=""
  if [[ ! -t 0 ]]; then
    warn "not interactive — confirmation for '$word' auto-DECLINED."
    return 1
  fi
  printf '%s\n%sType %s to continue:%s ' "$prompt" "$C_BLD" "$word" "$C_OFF"
  read -r answer || true
  [[ "$answer" == "$word" ]]
}

# ---------------------------------------------------------------- postgres --
psql_prod() {  # read/write on the PROD db — callers must be deliberate
  docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 "$@"
}
psql_maint() { # connects to 'postgres', for CREATE/DROP/ALTER DATABASE
  docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 "$@"
}

db_exists() { # $1 = dbname
  [[ "$(psql_maint -tAc "select 1 from pg_database where datname='$1'" 2>/dev/null)" == "1" ]]
}

db_size_bytes() { # $1 = dbname
  psql_maint -tAc "select pg_database_size('$1')" 2>/dev/null || echo 0
}

# Row counts for every user table — the evidence a revert diff is built from.
capture_rowcounts() {  # $1 = output file
  local out="$1" sql
  sql="select string_agg(format('select %L::text t, count(*) c from %I.%I', c.relname, n.nspname, c.relname), ' union all ')
       from pg_class c join pg_namespace n on n.oid=c.relnamespace
       where n.nspname='public' and c.relkind='r'"
  local q; q="$(psql_prod -tAc "$sql")"
  [[ -n "$q" ]] || die "could not enumerate tables for row counts"
  psql_prod -tAF'|' -c "$q" | sort > "$out"
}

# ------------------------------------------------------------------- disk --
free_gb() { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }

assert_disk_for() {  # $1 = needed GB, $2 = path
  local need="$1" path="$2" avail
  avail="$(free_gb "$path")"
  (( avail >= need + DISK_MARGIN_GB )) \
    || die "not enough disk on $path: ${avail}GB free, need ${need}GB + ${DISK_MARGIN_GB}GB margin.
       A full disk breaks Postgres — i.e. it breaks production. Free space first."
}

# --------------------------------------------------------------- services --
svc_active() { systemctl is-active --quiet "$1"; }

restart_services() {  # $@ = units
  local u
  for u in "$@"; do
    info "restarting $u"
    run systemctl restart "$u"
  done
}

stop_services() {
  local u
  for u in "$@"; do
    info "stopping $u"
    run systemctl stop "$u"
  done
}

start_services() {
  local u
  for u in "$@"; do
    info "starting $u"
    run systemctl start "$u"
  done
}

# ------------------------------------------------------------ health checks --
# Each returns 0/1 and prints its own line. verify_prod() aggregates.

check_services_up() {
  local u bad=0
  for u in "${BACKEND_SERVICES[@]}"; do
    svc_active "$u" || { warn "service $u is NOT active"; bad=1; }
  done
  (( bad == 0 )) && ok "services active: ${BACKEND_SERVICES[*]}"
  return $bad
}

check_services_stayed_up() {
  info "waiting ${HEALTH_SETTLE_SECS}s to catch a crash-loop…"
  sleep "$HEALTH_SETTLE_SECS"
  check_services_up
}

check_http() {
  local bad=0 code
  for url in https://evelio.net/health https://app.evelio.net/api/v1/health; do
    code="$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
    if [[ "$code" =~ ^(200|204|401|403|404)$ ]]; then
      # 401/403/404 still prove the backend answered rather than the proxy erroring.
      ok "HTTP $url -> $code"
    else
      warn "HTTP $url -> $code"; bad=1
    fi
  done
  return $bad
}

check_frontend_served() {
  local code idx bad=0
  code="$(curl -sS -o /dev/null -m 15 -w '%{http_code}' https://app.evelio.net/ 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] || { warn "frontend / -> $code (403 usually means the chmod a+rX was missed)"; bad=1; }
  # the main JS asset referenced by the served index must itself be fetchable
  idx="$(curl -sS -m 15 https://app.evelio.net/ 2>/dev/null || true)"
  local asset
  asset="$(grep -oE '/assets/[A-Za-z0-9._-]+\.js' <<<"$idx" | head -1 || true)"
  if [[ -n "$asset" ]]; then
    code="$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "https://app.evelio.net$asset" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] || { warn "frontend asset $asset -> $code"; bad=1; }
  else
    warn "could not find a JS asset in the served index.html"; bad=1
  fi
  (( bad == 0 )) && ok "frontend served (index + main asset)"
  return $bad
}

# Traceback scan. Deliberately NOT a rollback trigger on its own by default —
# see CLAUDE.md "log scan is advisory".
check_logs_clean() {  # $1 = since-timestamp
  local since="$1" hits
  hits="$(journalctl -u tesla-oauth --since "$since" --no-pager 2>/dev/null \
          | grep -cE 'Traceback \(most recent call last\)|CRITICAL' || true)"
  if (( hits > 0 )); then
    warn "$hits traceback/critical line(s) in tesla-oauth since $since:"
    journalctl -u tesla-oauth --since "$since" --no-pager 2>/dev/null \
      | grep -E -A3 'Traceback \(most recent call last\)|CRITICAL' | head -40 >&2
    return 1
  fi
  ok "no tracebacks in tesla-oauth since $since"
  return 0
}

# Aggregate. $1 = since-timestamp for the log scan.
# Sets VERIFY_FAILED / VERIFY_LOG_ONLY for the caller to act on.
verify_prod() {
  local since="$1" hard=0 soft=0
  hdr "Verifying production"
  check_services_stayed_up || hard=1
  check_http               || hard=1
  check_frontend_served    || hard=1
  check_logs_clean "$since" || soft=1
  VERIFY_FAILED=$hard
  VERIFY_LOG_ONLY=$soft
  return 0
}

# -------------------------------------------------------------- misc helpers --
now_id()  { date -u +%Y%m%dT%H%M%SZ; }
human()   { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

# Manifest entries are CRLF-normalized hashes — see norm_sha above.
sha_dir_manifest() {  # $1 = dir, $2... = relative files ; prints "sha  rel"
  local d="$1"; shift
  local f
  for f in "$@"; do
    if [[ -f "$d/$f" ]]; then
      printf '%s  %s\n' "$(norm_sha "$d/$f")" "$f"
    else
      printf '%s  %s\n' "ABSENT" "$f"
    fi
  done
}

load_release_meta() {
  [[ -f "$RELEASE_DIR/meta.env" ]] || return 1
  # shellcheck disable=SC1091
  source "$RELEASE_DIR/meta.env"
}
