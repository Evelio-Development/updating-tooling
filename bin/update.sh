#!/usr/bin/env bash
#
# update.sh — pull origin/main and deploy it to production, atomically, with a
#             verified backup that revert.sh can restore.
#
# DRY RUN IS THE DEFAULT. Nothing is touched without --apply.
#
#   sudo bin/update.sh                    # print the full plan, change nothing
#   sudo bin/update.sh --apply            # do it
#   sudo bin/update.sh --apply --soft-db-backup
#   sudo bin/update.sh --apply --with-caddy
#
# See CLAUDE.md / README.md. Read the "what a revert can and cannot undo"
# section before your first --apply.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/lib/common.sh"

APPLY=0
SOFT_DB=0
SKIP_TESTS=0
WITH_CADDY=0
WITH_INGEST_DAEMON=0
LOG_GATE=1

while (( $# )); do
  case "$1" in
    --apply)              APPLY=1 ;;
    --soft-db-backup)     SOFT_DB=1 ;;
    --skip-tests)         SKIP_TESTS=1 ;;
    --with-caddy)         WITH_CADDY=1 ;;
    --with-ingest-daemon) WITH_INGEST_DAEMON=1 ;;
    --no-log-gate)        LOG_GATE=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

assert_root
assert_prod_layout
warn_if_staging_active
mkdir -p "$LOG_DIR"

STEP="init"
STARTED_AT=""          # set just before the first prod mutation
FIRST_MUTATION=0       # 1 once production has been touched
NEW_REL="$RELEASES_DIR/new.$$"

hdr "Evelio production update"
(( APPLY )) || log "${C_YEL}DRY RUN${C_OFF} — nothing will be changed. Add --apply to execute."

# =========================================================== 1. PRE-FLIGHT ==
# Everything here is read-only. Any failure exits before production is touched.

hdr "1. Pre-flight"

# --- 1a. baseline exists ---
STEP="preflight/baseline"
[[ -f "$RELEASE_DIR/MANIFEST" ]] || die "no baseline manifest at $RELEASE_DIR/MANIFEST.
       Run 'sudo bin/adopt.sh' first — it shows you how the live run-dir has
       drifted from main and records the baseline once you approve."
load_release_meta || die "corrupt release metadata at $RELEASE_DIR/meta.env"
ok "baseline: ${RELEASE_ID:-?} (kind=${RELEASE_KIND:-?})"

# --- 1b. frontend build config ---
STEP="preflight/frontend-config"
[[ -f "$FRONTEND_BUILD_ENV" ]] || die "missing $FRONTEND_BUILD_ENV.
       Copy $TOOL_DIR/frontend-build.env.template there and fill in the PROD
       values. It is untracked and must never be committed."
# shellcheck disable=SC1090
set -a; source "$FRONTEND_BUILD_ENV"; set +a
for v in VITE_API_BASE VITE_TURNSTILE_SITE_KEY; do
  [[ -n "${!v:-}" ]] || die "$FRONTEND_BUILD_ENV: $v is unset or empty."
done
[[ "$VITE_API_BASE" == https://* ]] || die "VITE_API_BASE must be an https:// URL, got '$VITE_API_BASE'"
case "$VITE_TURNSTILE_SITE_KEY" in
  1x*|2x*|3x*) die "VITE_TURNSTILE_SITE_KEY looks like a Cloudflare TESTING key.
       Production needs the real, domain-locked sitekey — a testing key here makes
       every prod sign-up succeed against a captcha that verifies nothing." ;;
esac
ok "frontend build config present (API base $VITE_API_BASE)"

# --- 1c. fetch + resolve target ---
STEP="preflight/git"
if [[ -d "$SRC_REPO/.git" ]]; then
  git -C "$SRC_REPO" fetch --prune origin >/dev/null || die "git fetch failed"
else
  die "no clone at $SRC_REPO — run bin/adopt.sh first."
fi
# origin/main, explicitly. Never a bare branch name.
TARGET_COMMIT="$(git -C "$SRC_REPO" rev-parse "$GIT_REF")" || die "cannot resolve $GIT_REF"
git -C "$SRC_REPO" checkout -q --detach "$TARGET_COMMIT"
git -C "$SRC_REPO" clean -qxdf -e node_modules -e dist   # stale build artefacts
if [[ -n "$(git -C "$SRC_REPO" status --porcelain)" ]]; then
  die "the private clone $SRC_REPO is dirty after checkout — refusing to deploy an unknown tree."
fi
ok "target: ${TARGET_COMMIT:0:8}  $(git -C "$SRC_REPO" log -1 --format=%s)"

if [[ "${TARGET_COMMIT}" == "${RUNNING_COMMIT:-}" ]]; then
  warn "origin/main (${TARGET_COMMIT:0:8}) is already what the last deploy shipped."
  log "  Continuing anyway would rebuild and re-copy the same code (harmless, but"
  log "  it DESTROYS your current backup and replaces it with one taken now)."
fi

mapfile -t FILES < <(backend_deploy_files "$SRC_REPO")
(( ${#FILES[@]} )) || die "no deployable files in $TARGET_COMMIT"

# --- 1d. drift check: has anyone hand-edited the run-dir since last deploy? ---
STEP="preflight/drift"
drift=()
while read -r sha rel; do
  [[ -n "$rel" ]] || continue
  if [[ "$sha" == "ABSENT" ]]; then
    [[ -e "$BACKEND_DIR/$rel" ]] && drift+=("$rel  (appeared since last deploy)")
    continue
  fi
  if [[ ! -e "$BACKEND_DIR/$rel" ]]; then
    drift+=("$rel  (deleted since last deploy)")
  elif [[ "$(norm_sha "$BACKEND_DIR/$rel")" != "$sha" ]]; then
    drift+=("$rel  (modified since last deploy)")
  fi
done < "$RELEASE_DIR/MANIFEST"

if (( ${#drift[@]} )); then
  hdr "DRIFT DETECTED in $BACKEND_DIR"
  printf '  %s\n' "${drift[@]}"
  log ""
  log "Someone changed production code outside this tool since the last deploy."
  log "Deploying now would overwrite those changes with main's version."
  log "Inspect with:  diff -u $BACKEND_DIR/<file> $SRC_REPO/<file>"
  log "Then either merge the change into main, or re-baseline with bin/adopt.sh --apply."
  die "refusing to deploy over unexplained drift."
fi
ok "no drift — run-dir matches the last deploy"

# --- 1e. env-var check ---
STEP="preflight/env-vars"
missing_env=()
if [[ -r "$PROD_ENV_FILE" ]]; then
  # Key NAMES only. This tool never reads or copies secret values.
  mapfile -t have < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$PROD_ENV_FILE" | sort -u)
  # os.environ["X"] and os.getenv("X") WITHOUT a default — those are the ones
  # that blow up at runtime if unset.
  mapfile -t need < <(
    cd "$SRC_REPO" && cat "${FILES[@]}" 2>/dev/null \
      | grep -oE "os\.environ\[['\"][A-Z_][A-Z0-9_]*['\"]\]|os\.getenv\(['\"][A-Z_][A-Z0-9_]*['\"]\s*\)" \
      | grep -oE "[A-Z_][A-Z0-9_]{2,}" | sort -u
  )
  for k in "${need[@]:-}"; do
    [[ -n "$k" ]] || continue
    printf '%s\n' "${have[@]}" | grep -qxF "$k" || missing_env+=("$k")
  done
  if (( ${#missing_env[@]} )); then
    hdr "MISSING ENVIRONMENT VARIABLES"
    printf '  %s\n' "${missing_env[@]}"
    log ""
    log "The new code reads these with no default; $PROD_ENV_FILE does not define them."
    log "Add them (values from your password manager — never from this repo) and re-run."
    die "refusing to deploy code that would 500 on a missing variable."
  fi
  ok "all required env vars present in $PROD_ENV_FILE"
else
  warn "cannot read $PROD_ENV_FILE — skipping the env-var check"
fi

# --- 1f. tests ---
STEP="preflight/tests"
# This is a REGRESSION gate, not a pass/fail gate. A large part of the app's
# suite has been red for a while; a gate that blocks every deploy would just be
# bypassed with --skip-tests every time, which protects nothing. So: record the
# set of test files that fail today (the baseline), and block only when a file
# that used to pass starts failing.
TEST_BASELINE="$UPD_ROOT/tests.baseline"
if (( SKIP_TESTS )); then
  warn "--skip-tests: the test gate is DISABLED for this deploy"
else
  info "running the repo test suite (throwaway DB in $STAGING_PG_CONTAINER — never prod)"
  TEST_RESULTS="$(mktemp)"
  RESULTS_FILE="$TEST_RESULTS" "$HERE/lib/run-tests.sh" "$SRC_REPO" || true

  if [[ ! -f "$TEST_BASELINE" ]]; then
    hdr "NO TEST BASELINE YET"
    if [[ -s "$TEST_RESULTS" ]]; then
      log "These test files fail on ${TARGET_COMMIT:0:8}:"
      sed 's/^/  /' "$TEST_RESULTS"
      log ""
      log "They are recorded as the known-bad baseline. From the next deploy on,"
      log "this gate blocks only if a file that currently PASSES starts failing."
    else
      log "The whole suite passes. That becomes the baseline: any failure blocks."
    fi
    if (( APPLY )); then
      cp "$TEST_RESULTS" "$TEST_BASELINE"
      ok "baseline recorded at $TEST_BASELINE"
    else
      log "(dry run — the baseline is recorded on the first --apply)"
    fi
  else
    REGRESSED="$(comm -23 "$TEST_RESULTS" "$TEST_BASELINE")"
    FIXED="$(comm -13 "$TEST_RESULTS" "$TEST_BASELINE")"
    if [[ -n "$REGRESSED" ]]; then
      hdr "TEST REGRESSION"
      log "These test files passed at the last deploy and fail now:"
      sed 's/^/  /' <<<"$REGRESSED"
      log ""
      log "Logs: $LOG_DIR/test-<file>.log"
      rm -f "$TEST_RESULTS"
      die "refusing to deploy a test regression.
       Fix main, or override with --skip-tests if you have judged it irrelevant
       (that choice is recorded in the release metadata)."
    fi
    if [[ -n "$FIXED" ]]; then
      ok "newly passing: $(tr '\n' ' ' <<<"$FIXED")"
      (( APPLY )) && cp "$TEST_RESULTS" "$TEST_BASELINE"   # tightening is safe
    fi
    ok "no test regressions ($(wc -l < "$TEST_RESULTS") known-failing file(s))"
  fi
  rm -f "$TEST_RESULTS"
fi

# --- 1g. disk ---
STEP="preflight/disk"
DB_BYTES="$(db_size_bytes "$PG_DB")"
DB_GB=$(( DB_BYTES / 1000000000 + 1 ))
# Dump (~6% of DB) + webroot + code snapshot. A revert later needs 2x DB, and
# revert.sh checks that itself; here we only need room for the backup.
assert_disk_for $(( DB_GB / 2 + 1 )) "$UPD_ROOT"
ok "disk ok ($(free_gb "$UPD_ROOT")GB free; DB is $(human "$DB_BYTES"))"

# =============================================================== 2. PLAN ====
hdr "2. Plan"
log "  commit          : ${RUNNING_COMMIT:-unknown} -> ${TARGET_COMMIT:0:8}"
if [[ "${RUNNING_COMMIT:-unknown}" != "unknown" ]]; then
  log "  changes:"
  git -C "$SRC_REPO" log --oneline "${RUNNING_COMMIT}..${TARGET_COMMIT}" 2>/dev/null | sed 's/^/    /' || true
fi
log "  backend files   : ${#FILES[@]} -> $BACKEND_DIR"
CHANGED=()
for f in "${FILES[@]}"; do
  same_content "$BACKEND_DIR/$f" "$SRC_REPO/$f" || CHANGED+=("$f")
done
log "  changing        : ${#CHANGED[@]} file(s)"
(( ${#CHANGED[@]} )) && printf '    %s\n' "${CHANGED[@]}"

mapfile -t MIGRATIONS < <(cd "$SRC_REPO" && git log --diff-filter=A --format='%H' --reverse -- 'migrate_*.sql' \
  | while read -r c; do git show --name-only --format='' --diff-filter=A "$c" -- 'migrate_*.sql'; done | awk '!seen[$0]++')
log "  migrations      : ${#MIGRATIONS[@]} (all replayed; they are idempotent)"
(( ${#MIGRATIONS[@]} )) && printf '    %s\n' "${MIGRATIONS[@]}"
log "  frontend        : npm ci && npm run build -> $WEBROOT (legal/ preserved)"
log "  odometer script : $SRC_REPO/fetch_odometer.py -> $INGEST_DIR"
(( WITH_INGEST_DAEMON )) && log "  ingest daemon   : ingest_from_dockerlogs.py -> $INGEST_DIR (+ restart $INGEST_SERVICE)"
(( WITH_CADDY )) && log "  caddy           : server-config/Caddyfile -> $CADDYFILE (backup, validate, reload)"
log "  restart         : ${BACKEND_SERVICES[*]}"
if (( SOFT_DB )); then
  log "  db backup       : ${C_YEL}SOFT${C_OFF} — schema + all tables EXCEPT telemetry_raw rows"
else
  log "  db backup       : FULL pg_dump -Fc of '$PG_DB' ($(human "$DB_BYTES"))"
fi

if (( ! APPLY )); then
  hdr "DRY RUN complete — production untouched."
  log "Run the same command with --apply to execute."
  exit 0
fi

# ========================================================== 3. CONFIRM ======
hdr "3. Confirm"
if [[ -f "$RELEASE_DIR/meta.env" ]]; then
  log "${C_RED}${C_BLD}The existing backup will be DELETED and replaced.${C_OFF}"
  log "  existing : ${RELEASE_ID:-?}  created ${CREATED_AT:-?}  db-dump=${HAS_DB_DUMP:-0} (${DB_DUMP_MODE:-none})"
  log ""
  log "Only ONE release is kept. After this deploy you can revert to the state"
  log "production is in RIGHT NOW — and no further back. If you are mid-way"
  log "through debugging a previous deploy, stop and finish that first."
  log ""
  log "(The new backup is taken BEFORE the old one is removed, so there is never"
  log " a moment with no backup at all.)"
fi
confirm "" "DEPLOY" || die "aborted by operator — production untouched."

# ======================================================= 4. TAKE BACKUP =====
# Still no production mutation. The backup is built complete in a staging dir,
# verified, and only then swapped over the old one.

hdr "4. Backup (production not yet modified)"
STEP="backup"
rm -rf "$NEW_REL"
mkdir -p "$NEW_REL"/{backend,frontend,ingest,caddy}
REL_ID="$(now_id)"

info "snapshotting backend code"
for f in "${FILES[@]}"; do
  [[ -e "$BACKEND_DIR/$f" ]] || continue
  mkdir -p "$NEW_REL/backend/$(dirname "$f")"
  cp -a "$BACKEND_DIR/$f" "$NEW_REL/backend/$f"
done
# Also capture live-only files so a revert can never be blamed for losing them.
( cd "$BACKEND_DIR" && find . -maxdepth 1 -type f -printf '%P\n' ) > "$NEW_REL/backend.listing"

info "snapshotting frontend ($WEBROOT)"
tar -C "$WEBROOT" -czf "$NEW_REL/frontend/webroot.tgz" . || die "frontend snapshot failed"

if [[ -f "$INGEST_DIR/fetch_odometer.py" ]]; then
  cp -a "$INGEST_DIR/fetch_odometer.py" "$NEW_REL/ingest/"
fi
(( WITH_INGEST_DAEMON )) && [[ -f "$INGEST_DIR/ingest_from_dockerlogs.py" ]] \
  && cp -a "$INGEST_DIR/ingest_from_dockerlogs.py" "$NEW_REL/ingest/"
[[ -f "$CADDYFILE" ]] && cp -a "$CADDYFILE" "$NEW_REL/caddy/Caddyfile"

info "capturing row counts (the evidence revert.sh diffs against)"
capture_rowcounts "$NEW_REL/rowcounts.pre"
ok "$(wc -l < "$NEW_REL/rowcounts.pre") tables recorded"

info "pg_dump — this is the one that matters; do not interrupt it"
if (( SOFT_DB )); then
  docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc -Z1 \
      --exclude-table-data=public.telemetry_raw -f /tmp/evelio.dump \
    || die "pg_dump failed — production NOT modified."
  DUMP_MODE=soft
else
  docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc -Z1 -f /tmp/evelio.dump \
    || die "pg_dump failed — production NOT modified."
  DUMP_MODE=full
fi
docker cp "$PG_CONTAINER":/tmp/evelio.dump "$NEW_REL/db.dump" || die "could not copy the dump out of the container"
docker exec "$PG_CONTAINER" rm -f /tmp/evelio.dump || true

info "verifying the dump is readable"
docker cp "$NEW_REL/db.dump" "$PG_CONTAINER":/tmp/verify.dump >/dev/null
docker exec "$PG_CONTAINER" pg_restore --list /tmp/verify.dump >/dev/null \
  || { docker exec "$PG_CONTAINER" rm -f /tmp/verify.dump; die "the dump does not read back — refusing to deploy without a usable backup."; }
docker exec "$PG_CONTAINER" rm -f /tmp/verify.dump
ok "dump verified: $(human "$(stat -c%s "$NEW_REL/db.dump")") ($DUMP_MODE)"

# The file list this deploy installs, and the one installed before it. Restore
# logic is driven by these two lists plus the backend/ snapshot — never by
# MANIFEST, which is only the drift fingerprint and is written after the copy.
printf '%s\n' "${FILES[@]}" > "$NEW_REL/FILES.new"
awk '{print $2}' "$RELEASE_DIR/MANIFEST" > "$NEW_REL/FILES.prev"
cp -a "$RELEASE_DIR/MANIFEST" "$NEW_REL/MANIFEST"   # placeholder; rewritten post-copy

cat > "$NEW_REL/meta.env" <<EOF
RELEASE_ID=$REL_ID
RELEASE_KIND=deploy
# What production runs AFTER this deploy. The next deploy reads this as "current".
RUNNING_COMMIT=$TARGET_COMMIT
# What production ran BEFORE it — what revert.sh goes back to.
PREV_COMMIT=${RUNNING_COMMIT:-unknown}
CREATED_AT=$(date -u +%FT%TZ)
HAS_DB_DUMP=1
DB_DUMP_MODE=$DUMP_MODE
SKIPPED_TESTS=$SKIP_TESTS
WITH_CADDY=$WITH_CADDY
WITH_INGEST_DAEMON=$WITH_INGEST_DAEMON
EOF

# Swap: only now is the previous backup discarded.
rm -rf "$RELEASE_DIR"
mv "$NEW_REL" "$RELEASE_DIR"
ok "backup complete: $RELEASE_DIR ($REL_ID)"

# =================================================== 5. ROLLBACK MACHINERY ==
# From here on, production gets modified. Any failure lands in on_failure().

# Restore the backend to the snapshot. Driven by the union of "what this deploy
# installs" and "what was installed before", so a file the deploy ADDED gets
# removed and a file the deploy DELETED comes back.
restore_backend_code() {
  local rel
  while read -r rel; do
    [[ -n "$rel" ]] || continue
    is_protected "$rel" && continue
    if [[ -f "$RELEASE_DIR/backend/$rel" ]]; then
      mkdir -p "$BACKEND_DIR/$(dirname "$rel")"
      cp -a "$RELEASE_DIR/backend/$rel" "$BACKEND_DIR/$rel"
    else
      rm -f "$BACKEND_DIR/$rel"
    fi
  done < <(cat "$RELEASE_DIR/FILES.new" "$RELEASE_DIR/FILES.prev" 2>/dev/null | sort -u)
  find "$BACKEND_DIR" -maxdepth 2 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
}

rollback_code() {
  warn "rolling back CODE to the pre-deploy snapshot…"
  restore_backend_code

  if [[ -f "$RELEASE_DIR/ingest/fetch_odometer.py" ]]; then
    cp -a "$RELEASE_DIR/ingest/fetch_odometer.py" "$INGEST_DIR/"
  fi
  if [[ -f "$RELEASE_DIR/ingest/ingest_from_dockerlogs.py" ]]; then
    cp -a "$RELEASE_DIR/ingest/ingest_from_dockerlogs.py" "$INGEST_DIR/"
  fi

  if [[ -f "$RELEASE_DIR/frontend/webroot.tgz" ]]; then
    warn "restoring $WEBROOT"
    local tmp; tmp="$(mktemp -d)"
    tar -C "$tmp" -xzf "$RELEASE_DIR/frontend/webroot.tgz"
    rsync -a --delete "$tmp/" "$WEBROOT/"
    chmod -R a+rX "$WEBROOT"
    rm -rf "$tmp"
  fi

  if (( WITH_CADDY )) && [[ -f "$RELEASE_DIR/caddy/Caddyfile" ]]; then
    cp -a "$RELEASE_DIR/caddy/Caddyfile" "$CADDYFILE"
    caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
      && systemctl reload caddy || warn "caddy rollback did not validate — check $CADDYFILE by hand"
  fi

  systemctl restart "${BACKEND_SERVICES[@]}" || true
  warn "code rollback done."
}

on_failure() {
  local rc=$?
  (( rc == 0 )) && return 0
  set +e
  hdr "${C_RED}DEPLOY FAILED at step: $STEP${C_OFF}"

  if (( ! FIRST_MUTATION )); then
    log "Production was not modified. Nothing to roll back."
    exit "$rc"
  fi

  log "Production HAS been modified. Choose a rollback:"
  log "  1) code only  — restore code/frontend/services, leave the database alone (SAFE)"
  log "  2) code + db  — also restore the database from the backup taken minutes ago"
  log "  3) nothing    — leave production as it is and investigate by hand"
  log ""
  log "Waiting ${ROLLBACK_PROMPT_TIMEOUT}s. If nobody answers (or this is not a"
  log "terminal), option 1 is taken automatically — an unattended process must"
  log "never decide on its own to rewind production data."

  local choice=1
  if [[ -t 0 ]]; then
    read -r -t "$ROLLBACK_PROMPT_TIMEOUT" -p "choice [1/2/3] (default 1): " choice || choice=1
    [[ -n "${choice:-}" ]] || choice=1
  else
    warn "not a terminal — taking option 1."
  fi

  case "$choice" in
    2)
      rollback_code
      log ""
      warn "handing over to revert.sh for the database restore."
      log "It will show you exactly which rows would be lost and ask again."
      exec "$HERE/bin/revert.sh" --apply --db-only
      ;;
    3)
      warn "leaving production as-is at your request."
      log "Backup is intact at $RELEASE_DIR. Revert later with: sudo bin/revert.sh --apply"
      ;;
    *)
      rollback_code
      hdr "${C_YEL}THE DATABASE WAS NOT REVERTED.${C_OFF}"
      log "Migrations applied during this deploy are still in place. They are"
      log "additive and the restored code ignores them, so prod should work — but"
      log "if the failure WAS the database, restore it deliberately with:"
      log "    sudo $HERE/bin/revert.sh --apply --db-only"
      ;;
  esac
  exit "$rc"
}
trap on_failure EXIT

# ========================================================== 6. BUILD =======
# Build BEFORE touching production: a build failure must cost nothing.
hdr "5. Build frontend"
STEP="build/frontend"
pushd "$SRC_REPO/frontend" >/dev/null
info "npm ci"
npm ci --no-audit --no-fund >"$LOG_DIR/npm-ci.log" 2>&1 || { tail -30 "$LOG_DIR/npm-ci.log" >&2; die "npm ci failed (see $LOG_DIR/npm-ci.log)"; }
info "npm run build"
VITE_API_BASE="$VITE_API_BASE" VITE_TURNSTILE_SITE_KEY="$VITE_TURNSTILE_SITE_KEY" \
  npm run build >"$LOG_DIR/npm-build.log" 2>&1 \
  || { tail -30 "$LOG_DIR/npm-build.log" >&2; die "npm run build failed (see $LOG_DIR/npm-build.log)"; }
[[ -f dist/index.html ]] || die "build produced no dist/index.html"
popd >/dev/null

info "verifying the bundle"
if ! grep -rqF "$VITE_API_BASE" "$SRC_REPO/frontend/dist/assets/" 2>/dev/null; then
  die "the built bundle does not contain the prod API base '$VITE_API_BASE' —
       publishing it would point production at the wrong backend."
fi
if grep -rqE 'dev\.app\.evelio\.net|localhost:8[0-9]{3}' "$SRC_REPO/frontend/dist/assets/" 2>/dev/null; then
  die "the built bundle references a dev/staging host — refusing to publish it to prod."
fi
ok "bundle verified"

# ================================================ 7. MUTATE PRODUCTION =====
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

hdr "6. Migrations (before code — always)"
STEP="migrate"
FIRST_MUTATION=1
if (( ${#MIGRATIONS[@]} )); then
  for m in "${MIGRATIONS[@]}"; do
    [[ -f "$SRC_REPO/$m" ]] || { warn "$m listed but missing in the tree — skipped"; continue; }
    info "applying $m"
    psql_prod < "$SRC_REPO/$m" >>"$LOG_DIR/migrations.log" 2>&1 \
      || die "migration $m failed (see $LOG_DIR/migrations.log)"
  done
  ok "${#MIGRATIONS[@]} migration(s) applied"
else
  ok "no migrations"
fi

hdr "7. Backend code"
STEP="deploy/backend"
for f in "${FILES[@]}"; do
  is_protected "$f" && { warn "refusing to write protected path $f"; continue; }
  mkdir -p "$BACKEND_DIR/$(dirname "$f")"
  # normalize CRLF: a Windows checkout breaks #! lines
  sed 's/\r$//' "$SRC_REPO/$f" > "$BACKEND_DIR/$f.tmp.$$"
  chmod --reference="$SRC_REPO/$f" "$BACKEND_DIR/$f.tmp.$$" 2>/dev/null || true
  mv -f "$BACKEND_DIR/$f.tmp.$$" "$BACKEND_DIR/$f"
done
# Remove code that main deleted — but only files the LAST deploy put there.
while read -r rel; do
  [[ -n "$rel" ]] || continue
  printf '%s\n' "${FILES[@]}" | grep -qxF "$rel" && continue
  is_protected "$rel" && continue
  [[ -f "$BACKEND_DIR/$rel" ]] || continue
  info "removing $rel (deleted in main; was deployed by this tool)"
  rm -f "$BACKEND_DIR/$rel"
done < "$RELEASE_DIR/FILES.prev"
find "$BACKEND_DIR" -name '__pycache__' -maxdepth 2 -type d -exec rm -rf {} + 2>/dev/null || true

# The drift fingerprint for the NEXT deploy must describe what is actually on
# disk now, not what the repo holds. Writing it from $BACKEND_DIR is the only
# version that is true.
sha_dir_manifest "$BACKEND_DIR" "${FILES[@]}" > "$RELEASE_DIR/MANIFEST"
[[ -f "$INGEST_DIR/fetch_odometer.py" ]] && sha_dir_manifest "$INGEST_DIR" fetch_odometer.py > "$RELEASE_DIR/MANIFEST.ingest"
ok "${#FILES[@]} backend file(s) in place"

hdr "8. Odometer script"
STEP="deploy/ingest"
if [[ -f "$SRC_REPO/fetch_odometer.py" ]]; then
  sed 's/\r$//' "$SRC_REPO/fetch_odometer.py" > "$INGEST_DIR/fetch_odometer.py"
  ok "fetch_odometer.py -> $INGEST_DIR (next cron run picks it up)"
fi
if (( WITH_INGEST_DAEMON )) && [[ -f "$SRC_REPO/ingest_from_dockerlogs.py" ]]; then
  sed 's/\r$//' "$SRC_REPO/ingest_from_dockerlogs.py" > "$INGEST_DIR/ingest_from_dockerlogs.py"
  chmod +x "$INGEST_DIR/ingest_from_dockerlogs.py"
  systemctl restart "$INGEST_SERVICE"
  ok "ingest_from_dockerlogs.py deployed, $INGEST_SERVICE restarted"
fi

hdr "9. Frontend publish"
STEP="deploy/frontend"
# legal/ holds published agreement PDFs that are NOT in this repo — never delete them.
rm -rf "${WEBROOT:?}/assets"
cp -r "$SRC_REPO/frontend/dist/." "$WEBROOT/"
chmod -R a+rX "$WEBROOT"
ok "published to $WEBROOT (legal/ preserved)"

if (( WITH_CADDY )); then
  hdr "10. Caddy"
  STEP="deploy/caddy"
  if [[ -f "$SRC_REPO/server-config/Caddyfile" ]] && ! cmp -s "$SRC_REPO/server-config/Caddyfile" "$CADDYFILE"; then
    cp -a "$CADDYFILE" "$CADDYFILE.bak.$(now_id)"
    cp "$SRC_REPO/server-config/Caddyfile" "$CADDYFILE"
    caddy validate --config "$CADDYFILE" --adapter caddyfile \
      || die "new Caddyfile does NOT validate — the old config is still running; restore $CADDYFILE.bak.*"
    systemctl reload caddy || die "caddy reload failed"
    ok "Caddyfile updated, validated and reloaded"
  else
    ok "Caddyfile unchanged"
  fi
fi

hdr "11. Restart backend"
STEP="restart"
systemctl restart "${BACKEND_SERVICES[@]}" || die "service restart failed"
ok "restarted ${BACKEND_SERVICES[*]}"

# ========================================================== 8. VERIFY ======
STEP="verify"
verify_prod "$STARTED_AT"
if (( VERIFY_FAILED )); then
  die "post-deploy verification failed (see the WARNs above)."
fi
if (( VERIFY_LOG_ONLY )); then
  if (( LOG_GATE )); then
    die "tracebacks appeared in the log after restart.
       If you have judged them pre-existing/harmless, re-run with --no-log-gate."
  fi
  warn "tracebacks present but --no-log-gate given — continuing."
fi

trap - EXIT
hdr "${C_GRN}Deploy complete${C_OFF}"
log "  now running : ${TARGET_COMMIT:0:8}  $(git -C "$SRC_REPO" log -1 --format=%s)"
log "  revert with : sudo $HERE/bin/revert.sh            (dry run first)"
log "  backup      : $RELEASE_DIR  ($REL_ID, db-dump=$DUMP_MODE)"
log ""
log "This backup is the ONLY way back. The next deploy replaces it."
