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
# See CLAUDE.md / README.md. Read "What a revert can and cannot undo" before
# your first --apply.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/lib/common.sh"

APPLY=0
SOFT_DB=0
OPT_WITH_CADDY=0
OPT_WITH_INGEST_DAEMON=0
LOG_GATE=1

while (( $# )); do
  case "$1" in
    --apply)              APPLY=1 ;;
    --soft-db-backup)     SOFT_DB=1 ;;
    --with-caddy)         OPT_WITH_CADDY=1 ;;
    --with-ingest-daemon) OPT_WITH_INGEST_DAEMON=1 ;;
    --no-log-gate)        LOG_GATE=0 ;;
    --skip-tests)
      die "--skip-tests was removed. The test suite is a hard gate: a failing
       test is either fixed or deleted in the app repo, never bypassed here.
       See README 'The test gate'." ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

assert_root
assert_prod_layout
assert_no_breadcrumb
warn_if_staging_active
mkdir -p "$LOG_DIR"
(( APPLY )) && take_lock "update"

STEP="init"
STARTED_AT=""          # set just before the first prod mutation
FIRST_MUTATION=0       # 1 once production has been touched
INTERRUPTED=0
DEPLOY_TMP=""          # in-flight *.deploying.$$ staging file, cleared on failure
NEW_REL="$RELEASES_DIR/new.$$"

hdr "Evelio production update"
(( APPLY )) || log "${C_YEL}DRY RUN${C_OFF} — nothing will be changed. Add --apply to execute."

# Leftovers from a previous aborted run: report, never silently reuse.
shopt -s nullglob
for stray in "$RELEASES_DIR"/new.* "$RELEASES_DIR"/old.*; do
  warn "leftover release staging dir from an aborted run: $stray ($(du -sh "$stray" 2>/dev/null | cut -f1))
       Safe to delete once you have confirmed releases/current is the backup you want."
done
shopt -u nullglob

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
if [[ "${RELEASE_KIND:-}" == "deploy" && "${DEPLOY_COMPLETED:-0}" != "1" ]]; then
  warn "the last deploy (${RELEASE_ID:-?}) never reported success."
  log "  Production may be running ${PREV_COMMIT:-?} (rolled back) rather than"
  log "  ${RUNNING_COMMIT:-?}. Check bin/status.sh before continuing."
fi

# --- 1b. frontend build config ---
STEP="preflight/frontend-config"
[[ -f "$FRONTEND_BUILD_ENV" ]] || die "missing $FRONTEND_BUILD_ENV.
       Copy $TOOL_DIR/frontend-build.env.template there and fill in the PROD
       values. It is untracked and must never be committed."
# Read ONLY VITE_* assignments. Sourcing the whole file would let a stray line
# in it silently redefine this tool's own variables (WEBROOT, PG_DB, APPLY…).
VITE_API_BASE=""; VITE_TURNSTILE_SITE_KEY=""
while IFS='=' read -r k v; do
  case "$k" in
    VITE_API_BASE)           VITE_API_BASE="${v%\"}"; VITE_API_BASE="${VITE_API_BASE#\"}" ;;
    VITE_TURNSTILE_SITE_KEY) VITE_TURNSTILE_SITE_KEY="${v%\"}"; VITE_TURNSTILE_SITE_KEY="${VITE_TURNSTILE_SITE_KEY#\"}" ;;
  esac
done < <(grep -E '^[[:space:]]*VITE_[A-Z_]+=' "$FRONTEND_BUILD_ENV" | sed 's/^[[:space:]]*//')
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
[[ -d "$SRC_REPO/.git" ]] || die "no clone at $SRC_REPO — run bin/adopt.sh first."
git -C "$SRC_REPO" fetch --prune origin >/dev/null || die "git fetch failed"
# origin/main, explicitly. Never a bare branch name.
TARGET_COMMIT="$(git -C "$SRC_REPO" rev-parse "$GIT_REF")" || die "cannot resolve $GIT_REF"
git -C "$SRC_REPO" checkout -q --detach "$TARGET_COMMIT"
git -C "$SRC_REPO" clean -qxdf -e node_modules -e dist -e package-lock.json
if [[ -n "$(git -C "$SRC_REPO" status --porcelain)" ]]; then
  die "the private clone $SRC_REPO is dirty after checkout — refusing to deploy an unknown tree."
fi
ok "target: ${TARGET_COMMIT:0:8}  $(git -C "$SRC_REPO" log -1 --format=%s)"

if [[ "${TARGET_COMMIT}" == "${RUNNING_COMMIT:-}" && "${DEPLOY_COMPLETED:-0}" == "1" ]]; then
  warn "origin/main (${TARGET_COMMIT:0:8}) is already what the last deploy shipped."
  log "  Continuing would rebuild and re-copy the same code (harmless), but it"
  log "  DESTROYS your current backup and replaces it with one taken now."
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
# The odometer script lives outside the run-dir but is deployed by this tool, so
# it gets the same gate — otherwise a hand-fix there is silently overwritten.
if [[ -f "$RELEASE_DIR/MANIFEST.ingest" ]]; then
  while read -r sha rel; do
    [[ -n "$rel" && "$sha" != "ABSENT" ]] || continue
    [[ -f "$INGEST_DIR/$rel" ]] || { drift+=("$INGEST_DIR/$rel  (deleted since last deploy)"); continue; }
    [[ "$(norm_sha "$INGEST_DIR/$rel")" == "$sha" ]] || drift+=("$INGEST_DIR/$rel  (modified since last deploy)")
  done < "$RELEASE_DIR/MANIFEST.ingest"
fi

if (( ${#drift[@]} )); then
  hdr "DRIFT DETECTED"
  printf '  %s\n' "${drift[@]}"
  log ""
  log "Someone changed production code outside this tool since the last deploy."
  log "Deploying now would overwrite those changes with main's version."
  log "Inspect (normalising line endings, since the run-dir is CRLF and git is LF):"
  log "    diff -u <(sed 's/\\r\$//' $BACKEND_DIR/<file>) <(sed 's/\\r\$//' $SRC_REPO/<file>)"
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
  mapfile -t need < <(
    cd "$SRC_REPO" || exit 1
    cat "${FILES[@]}" 2>/dev/null \
      | grep -oE "os\.environ\[['\"][A-Z_][A-Z0-9_]*['\"]\]|os\.getenv\(['\"][A-Z_][A-Z0-9_]*['\"]\s*\)|os\.environ\.get\(['\"][A-Z_][A-Z0-9_]*['\"]\s*\)" \
      | grep -oE "[A-Z_][A-Z0-9_]{2,}" | sort -u
  )
  for k in "${need[@]}"; do
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

# --- 1f. tests: a HARD gate ---
# A failing test is fixed or deleted in the app repo. It is never bypassed here:
# an escape hatch on a deploy gate gets used every time, and then the gate is
# decoration. run-tests.sh exits 0 (all passed), 1 (tests failed) or 2 (could
# not run) — 2 must never be mistaken for "nothing failed".
STEP="preflight/tests"
info "running the repo test suite (throwaway DB in $STAGING_PG_CONTAINER — never prod)"
test_rc=0
"$HERE/lib/run-tests.sh" "$SRC_REPO" || test_rc=$?
case "$test_rc" in
  0) ok "all tests passed" ;;
  1) die "the test suite is not green — refusing to deploy.
       Fix or delete the failing tests in the app repo, merge to main, re-run.
       Per-file logs: $LOG_DIR/test-*.log" ;;
  *) die "the test suite could not be run (exit $test_rc).
       This is an infrastructure failure, not a test failure — resolve it rather
       than deploying blind." ;;
esac

# --- 1g. disk ---
STEP="preflight/disk"
DB_BYTES="$(db_size_bytes "$PG_DB")"
DB_GB=$(( DB_BYTES / 1000000000 + 1 ))
assert_disk_for $(( DB_GB / 2 + 1 )) "$UPD_ROOT"
# The container's filesystem matters too: a full /var/lib/docker stops prod
# Postgres. Same device here today, checked separately so it stays correct if
# that ever changes.
assert_disk_for 2 /var/lib/docker
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

# Files the last deploy installed that main no longer has: they are removed
# from production, and they ARE in the backup (see the union snapshot below).
# sha_dir_manifest writes "<sha>  <rel>". `awk '{print $2}'` truncates any path
# containing a space at the first one, which would drop it from REMOVING, from the
# union snapshot and from FILES.prev — a deleted-in-main file with a space would
# then be neither backed up nor removed, and the truncated stem would reach
# `rm -f "$BACKEND_DIR/$rel"`. Strip exactly the "<sha><two spaces>" prefix.
mapfile -t PREV_LIST < <(sed 's/^[^ ]*  //' "$RELEASE_DIR/MANIFEST" | sed '/^$/d' | sort -u)
REMOVING=()
for rel in "${PREV_LIST[@]}"; do
  [[ -n "$rel" ]] || continue
  printf '%s\n' "${FILES[@]}" | grep -qxF "$rel" && continue
  [[ -f "$BACKEND_DIR/$rel" ]] && REMOVING+=("$rel")
done
if (( ${#REMOVING[@]} )); then
  log "  removing        : ${#REMOVING[@]} file(s) deleted in main"
  printf '    %s\n' "${REMOVING[@]}"
fi

# Add-order, not alphabetical: the migrations are not independent. Shared with
# run-tests.sh so the gate builds its schema exactly the way production gets it.
mapfile -t MIGRATIONS < <(migration_files "$SRC_REPO")
log "  migrations      : ${#MIGRATIONS[@]} (all replayed; they are idempotent)"
(( ${#MIGRATIONS[@]} )) && printf '    %s\n' "${MIGRATIONS[@]}"
log "  frontend        : npm build -> $WEBROOT (legal/ preserved)"
log "  odometer script : fetch_odometer.py -> $INGEST_DIR"
(( OPT_WITH_INGEST_DAEMON )) && log "  ingest daemon   : ingest_from_dockerlogs.py -> $INGEST_DIR (+ restart $INGEST_SERVICE)"
(( OPT_WITH_CADDY )) && log "  caddy           : server-config/Caddyfile -> $CADDYFILE (backup, validate, reload)"
log "  cron            : stopped for the duration, restarted afterwards"
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
  log "(The new backup is completed BEFORE the old one is removed, and the swap"
  log " is two renames, so a complete backup always exists on disk.)"
fi
confirm "" "DEPLOY" || die "aborted by operator — production untouched."

# ======================================================= 4. TAKE BACKUP =====
# Still no production mutation. The backup is built complete in a staging dir,
# verified, and only then swapped over the old one.

hdr "4. Backup (production not yet modified)"
STEP="backup"
rm -rf "$NEW_REL"
mkdir -p "$NEW_REL"/{backend,frontend,ingest,caddy}
# A release dir holds a full pg_dump of production — user PII, password hashes,
# and every token/credential column — plus a tar of the webroot. Under the default
# 0022 umask those land mode 644 inside a 755 tree, i.e. readable by every local
# account. Tighten the release tree and the log dir explicitly rather than relying
# on whatever umask the operator's shell happened to have.
chmod 700 "$RELEASES_DIR" "$LOG_DIR" 2>/dev/null || true
chmod -R go-rwx "$NEW_REL"
REL_ID="$(now_id)"

# Snapshot the UNION of "what this deploy installs" and "what the last deploy
# installed". Snapshotting only the new list would leave a file that main has
# DELETED absent from the backup — so the deploy removes it from production and
# the revert, finding nothing to restore, removes it again. It would be gone for
# good. The union is a few hundred KB of text; there is no reason not to.
mapfile -t SNAP_FILES < <(printf '%s\n' "${FILES[@]}" "${PREV_LIST[@]}" | sed '/^$/d' | sort -u)
info "snapshotting backend code (${#SNAP_FILES[@]} files: new set ∪ previously deployed set)"
for f in "${SNAP_FILES[@]}"; do
  [[ -f "$BACKEND_DIR/$f" ]] || continue
  is_protected "$f" && continue
  mkdir -p "$NEW_REL/backend/$(dirname "$f")"
  cp -a "$BACKEND_DIR/$f" "$NEW_REL/backend/$f"
done

info "snapshotting frontend ($WEBROOT)"
tar -C "$WEBROOT" -czf "$NEW_REL/frontend/webroot.tgz" . || die "frontend snapshot failed"
tar -tzf "$NEW_REL/frontend/webroot.tgz" >/dev/null || die "frontend snapshot does not read back"

if [[ -f "$INGEST_DIR/fetch_odometer.py" ]]; then
  cp -a "$INGEST_DIR/fetch_odometer.py" "$NEW_REL/ingest/"
fi
(( OPT_WITH_INGEST_DAEMON )) && [[ -f "$INGEST_DIR/ingest_from_dockerlogs.py" ]] \
  && cp -a "$INGEST_DIR/ingest_from_dockerlogs.py" "$NEW_REL/ingest/"
[[ -f "$CADDYFILE" ]] && cp -a "$CADDYFILE" "$NEW_REL/caddy/Caddyfile"

if (( SOFT_DB )); then DUMP_MODE=soft; else DUMP_MODE=full; fi
info "pg_dump ($DUMP_MODE) — this is the one that matters; do not interrupt it"
# Create the dump mode 600 BEFORE any data goes into it — chmod'ing afterwards
# leaves a window where the whole production database is world-readable.
install -m 600 /dev/null "$NEW_REL/db.dump"
install -m 600 /dev/null "$NEW_REL/rowcounts.pre"
dump_and_count_consistently "$NEW_REL/db.dump" "$NEW_REL/rowcounts.pre" "$DUMP_MODE"
ok "dump $(human "$(stat -c%s "$NEW_REL/db.dump")"), $(wc -l < "$NEW_REL/rowcounts.pre") tables counted in the same snapshot"

info "verifying the dump reads back"
docker exec -i "$PG_CONTAINER" pg_restore --list < "$NEW_REL/db.dump" >/dev/null 2>&1 \
  || die "the dump does not read back — refusing to deploy without a usable backup."
ok "dump verified"

printf '%s\n' "${FILES[@]}"     > "$NEW_REL/FILES.new"
printf '%s\n' "${PREV_LIST[@]}" > "$NEW_REL/FILES.prev"
cp -a "$RELEASE_DIR/MANIFEST" "$NEW_REL/MANIFEST"   # rewritten after the copy
# Keep the PRE-deploy fingerprint under its own name. MANIFEST is overwritten with
# the post-deploy hashes later in this run, which used to destroy the only record
# of which files existed before the deploy — the evidence revert.sh needs to tell
# "this file did not exist pre-deploy, remove it" apart from "the snapshot is
# incomplete, do NOT remove production's copy".
cp -a "$RELEASE_DIR/MANIFEST" "$NEW_REL/MANIFEST.pre"

cat > "$NEW_REL/meta.env" <<EOF
RELEASE_ID=$REL_ID
RELEASE_KIND=deploy
# What production ran BEFORE this deploy — what revert.sh goes back to.
PREV_COMMIT=${RUNNING_COMMIT:-unknown}
# What production runs now. Written as PREV_COMMIT here and only advanced to
# TARGET_COMMIT once the deploy has actually verified, so a failed deploy never
# leaves metadata claiming code is live that isn't.
RUNNING_COMMIT=${RUNNING_COMMIT:-unknown}
TARGET_COMMIT=$TARGET_COMMIT
DEPLOY_COMPLETED=0
CREATED_AT=$(date -u +%FT%TZ)
HAS_DB_DUMP=1
DB_DUMP_MODE=$DUMP_MODE
# THIS deploy's intent, from the command line — not whatever the previous release
# recorded. These keys are read back by revert.sh to decide whether the Caddyfile
# and the ingest daemon are part of the snapshot it restores.
WITH_CADDY=$OPT_WITH_CADDY
WITH_INGEST_DAEMON=$OPT_WITH_INGEST_DAEMON
EOF

# Swap by two renames within one filesystem, so a complete release always
# exists: `rm -rf current; mv new current` would have a window with no backup.
OLD_REL="$RELEASES_DIR/old.$$"
# A leftover old.<same-pid> (PID reuse after a crash in this exact window) would
# make `mv` NEST the previous backup inside it and still report success — the
# following rm -rf would then delete both. Refuse instead of guessing.
[[ -e "$OLD_REL" ]] && die "a leftover staging dir $OLD_REL already exists.
       Confirm releases/current is the backup you want, remove $OLD_REL, re-run."
if [[ -d "$RELEASE_DIR" ]]; then
  mv "$RELEASE_DIR" "$OLD_REL" || die "could not move the previous backup aside"
fi
mv "$NEW_REL" "$RELEASE_DIR" || die "could not install the new backup"
rm -rf "$OLD_REL"
# The release holds the dump and a webroot tar; keep the whole tree off-limits.
chmod -R go-rwx "$RELEASE_DIR" 2>/dev/null || true
ok "backup complete: $RELEASE_DIR ($REL_ID)"

# =================================================== 5. ROLLBACK MACHINERY ==
# From here on, production gets modified. Any failure lands in on_failure().

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
  done < <(cat "$RELEASE_DIR/FILES.new" "$RELEASE_DIR/FILES.prev" 2>/dev/null | sed '/^$/d' | sort -u)
  find "$BACKEND_DIR" -maxdepth 1 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
}

rollback_code() {
  warn "rolling back CODE to the pre-deploy snapshot…"
  restore_backend_code

  [[ -f "$RELEASE_DIR/ingest/fetch_odometer.py" ]] \
    && cp -a "$RELEASE_DIR/ingest/fetch_odometer.py" "$INGEST_DIR/"
  [[ -f "$RELEASE_DIR/ingest/ingest_from_dockerlogs.py" ]] \
    && cp -a "$RELEASE_DIR/ingest/ingest_from_dockerlogs.py" "$INGEST_DIR/"

  warn "restoring $WEBROOT"
  restore_webroot "$RELEASE_DIR/frontend/webroot.tgz" || warn "webroot NOT restored — check it by hand"

  if (( OPT_WITH_CADDY )) && [[ -f "$RELEASE_DIR/caddy/Caddyfile" ]]; then
    cp -a "$RELEASE_DIR/caddy/Caddyfile" "$CADDYFILE"
    caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
      && systemctl reload caddy || warn "caddy rollback did not validate — check $CADDYFILE by hand"
  fi

  # The drift fingerprint must describe the code that is now on disk, or the
  # next deploy reports the whole rollback as "someone hand-edited production"
  # and refuses.
  mapfile -t _rb < <(cat "$RELEASE_DIR/FILES.new" "$RELEASE_DIR/FILES.prev" 2>/dev/null | sed '/^$/d' | sort -u)
  sha_dir_manifest "$BACKEND_DIR" "${_rb[@]}" > "$RELEASE_DIR/MANIFEST"
  # Same superset as the deploy path, or the rollback reads as drift next time.
  _rbi=()
  for _f in fetch_odometer.py ingest_from_dockerlogs.py; do
    [[ -f "$INGEST_DIR/$_f" ]] && _rbi+=("$_f")
  done
  # An `if`, not `(( n )) && cmd`: a function whose last executed statement is a
  # false `&&` guard RETURNS non-zero, and under `set -e` that kills the caller at
  # the point of the call. This is the rollback path, so an accidental exit here
  # would abandon production half-rolled-back. Nothing currently sits at the tail
  # of this function, but nothing should have to check that before adding a line.
  if (( ${#_rbi[@]} )); then
    sha_dir_manifest "$INGEST_DIR" "${_rbi[@]}" > "$RELEASE_DIR/MANIFEST.ingest"
  fi

  systemctl restart "${BACKEND_SERVICES[@]}" || true
  resume_cron
  warn "code rollback done — verifying production came back"
  verify_prod "$STARTED_AT" || true
  if (( VERIFY_FAILED )); then
    warn "PRODUCTION IS STILL UNHEALTHY AFTER THE ROLLBACK. Check:"
    log "    journalctl -u tesla-oauth -n 100 --no-pager"
  else
    ok "production verified healthy on the previous code"
  fi
}

on_failure() {
  local rc=$?
  # A signal-terminated bash runs its EXIT trap with $? == 0, so an interrupted
  # deploy would otherwise look like a success and skip the rollback entirely.
  (( INTERRUPTED )) && rc=130
  (( rc == 0 )) && return 0
  set +e
  trap - EXIT
  # Never leave a half-written staging file in the live run-dir.
  [[ -n "${DEPLOY_TMP:-}" ]] && rm -f "$DEPLOY_TMP"
  hdr "${C_RED}DEPLOY FAILED at step: $STEP${C_OFF}"
  (( INTERRUPTED )) && warn "interrupted by a signal (Ctrl-C, SIGTERM or a dropped SSH session)"

  if (( ! FIRST_MUTATION )); then
    log "Production was not modified. Nothing to roll back."
    resume_cron
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
    # The EXIT trap is already cleared, so a Ctrl-C during this 300s prompt would
    # otherwise exit straight out with production mutated and NOTHING rolled back.
    # An interrupt at a rollback prompt means "get on with the safe option", not
    # "abandon production half-deployed".
    trap 'warn "interrupted at the prompt — taking option 1 (code-only rollback)."' INT TERM HUP
    read -r -t "$ROLLBACK_PROMPT_TIMEOUT" -p "choice [1/2/3] (default 1): " choice || choice=1
    trap '' INT TERM HUP
    [[ -n "${choice:-}" ]] || choice=1
  else
    warn "not a terminal — taking option 1."
  fi

  case "$choice" in
    2)
      rollback_code
      log ""
      warn "handing over to revert.sh for the database restore."
      # NOT exec: the deploy failed, and this process must still exit non-zero.
      # CLOSE fd 9, don't just `flock -u` it: leaving it open meant the child's own
      # `exec 9<>` re-truncated the lock file and, once the child exited, nothing
      # held the lock at all while this process was still running.
      exec 9>&- 2>/dev/null || true
      # Restore the default signal disposition before handing over. A signal set
      # to SIG_IGN is INHERITED as ignored and a child cannot trap or reset it —
      # so with `trap '' INT TERM HUP` still in force, every signal trap inside
      # revert.sh and db-restore.sh is inert. The operator watching a multi-minute
      # pg_restore would find Ctrl-C did nothing, escalate to kill -9, and SIGKILL
      # skips `on_abort` as well: production left closed to connections with its
      # services and cron down. The revert is designed to stay interruptible
      # through the restore, and this is the one path that silently removed that.
      trap - INT TERM HUP
      "$HERE/bin/revert.sh" --apply --db-only || warn "the database revert did not complete"
      trap '' INT TERM HUP
      ;;
    3)
      warn "leaving production as-is at your request."
      resume_cron
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

on_signal() { INTERRUPTED=1; trap - INT TERM HUP; exit 130; }

# ========================================================== 6. BUILD =======
# Build BEFORE touching production: a build failure must cost nothing.
hdr "5. Build frontend"
STEP="build/frontend"
pushd "$SRC_REPO/frontend" >/dev/null
if [[ -f package-lock.json ]]; then
  info "npm ci"
  npm ci --no-audit --no-fund >"$LOG_DIR/npm-ci.log" 2>&1 \
    || { tail -30 "$LOG_DIR/npm-ci.log" >&2; die "npm ci failed (see $LOG_DIR/npm-ci.log)"; }
else
  # The app repo gitignores package-lock.json, so `npm ci` (which requires one)
  # can never work. Fall back, but say so: without a lockfile the dependency
  # versions in a production build are whatever npm resolved today.
  warn "no package-lock.json in the app repo (it is gitignored) — using 'npm install'."
  log "  This build is NOT reproducible: transitive dependency versions are"
  log "  resolved fresh. Committing a lockfile in the app repo fixes it."
  npm install --no-audit --no-fund >"$LOG_DIR/npm-ci.log" 2>&1 \
    || { tail -30 "$LOG_DIR/npm-ci.log" >&2; die "npm install failed (see $LOG_DIR/npm-ci.log)"; }
fi
info "npm run build"
VITE_API_BASE="$VITE_API_BASE" VITE_TURNSTILE_SITE_KEY="$VITE_TURNSTILE_SITE_KEY" \
  npm run build >"$LOG_DIR/npm-build.log" 2>&1 \
  || { tail -30 "$LOG_DIR/npm-build.log" >&2; die "npm run build failed (see $LOG_DIR/npm-build.log)"; }
[[ -f dist/index.html ]] || die "build produced no dist/index.html"
popd >/dev/null

info "verifying the bundle"
# Scan the WHOLE dist tree, not just dist/assets/. index.html, inlined scripts,
# anything Vite emits at the top level and everything copied through from public/
# are all published, so all of them have to be checked. And do NOT hide errors
# with 2>/dev/null: a missing or renamed assets/ dir made the dev-host grep exit
# non-zero, which read as "no dev host found" and silently PASSED the gate.
DIST="$SRC_REPO/frontend/dist"
[[ -d "$DIST" ]] || die "no build output at $DIST"
if ! grep -rqF "$VITE_API_BASE" "$DIST"; then
  die "the built bundle does not contain the prod API base '$VITE_API_BASE' —
       publishing it would point production at the wrong backend."
fi
# grep exits 0=match, 1=no match, 2=ERROR. A bare `if grep …` treats 2 as "no
# match" and passes — so an unreadable entry under dist/ (a broken symlink from a
# plugin, an odd mode) makes this gate and the sitekey gate below wave the bundle
# through. Dropping `2>/dev/null` earlier fixed the visibility of that, not the
# logic. Require exactly 1 ("searched everything, found nothing") to pass.
_grep_clean() {   # $@ = grep args ; 0 = definitely no match, non-zero = matched OR errored
  local rc=0
  grep "$@" || rc=$?
  case "$rc" in
    1) return 0 ;;
    0) return 1 ;;
    *) die "the bundle scan could not read part of $DIST (grep exit $rc).
       Refusing to publish a bundle that was not fully checked." ;;
  esac
}
if ! _grep_clean -rqE 'dev\.app\.evelio\.net|localhost:8[0-9]{3}' "$DIST"; then
  die "the built bundle references a dev/staging host — refusing to publish it to prod."
fi
# The 1x/2x/3x testing-sitekey check is applied to frontend-build.env during
# pre-flight, but that only proves what we PASSED to the build. If the app repo
# ships its own frontend/.env*, or reads a differently-named variable, a testing
# sitekey reaches production while the gate says "bundle verified". Check the
# artifact, which is the thing that actually gets published.
if ! _grep_clean -rqE '"[123]x[A-Za-z0-9_-]{10,}"' "$DIST"; then
  die "the built bundle contains a Cloudflare TESTING Turnstile sitekey (1x/2x/3x…).
       That key always passes validation — publishing it disables the bot check on
       production. Check frontend/.env* in the app repo, not just frontend-build.env."
fi
ok "bundle verified"

# ================================================ 7. MUTATE PRODUCTION =====
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
trap on_failure EXIT
trap on_signal INT TERM HUP

hdr "6. Quiescing cron"
STEP="cron"
FIRST_MUTATION=1
pause_cron

hdr "7. Migrations (before code — always)"
STEP="migrate"
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

hdr "8. Backend code"
STEP="deploy/backend"
for f in "${FILES[@]}"; do
  is_protected "$f" && { warn "refusing to write protected path $f"; continue; }
  mkdir -p "$BACKEND_DIR/$(dirname "$f")"
  # normalize CRLF: a Windows checkout breaks #! lines
  tmpf="$BACKEND_DIR/$f.deploying.$$"
  DEPLOY_TMP="$tmpf"     # so the EXIT/signal path can clear it — see below
  sed 's/\r$//' "$SRC_REPO/$f" > "$tmpf" || { rm -f "$tmpf"; die "could not write $f"; }
  chmod --reference="$SRC_REPO/$f" "$tmpf" 2>/dev/null || true
  mv -f "$tmpf" "$BACKEND_DIR/$f"
  DEPLOY_TMP=""
done
# An interrupt between the sed and the mv leaves <name>.deploying.<pid> in the live
# run-dir. It matches no PROTECTED_GLOBS entry, so it is not protected, and adopt.sh
# would later present it to a human as a mystery file "unknown to git".
shopt -s nullglob
for stray in "$BACKEND_DIR"/*.deploying.*; do
  warn "removing leftover staging file from an interrupted deploy: $stray"
  rm -f "$stray"
done
shopt -u nullglob
# Remove code that main deleted — safe, because the union snapshot above has it.
for rel in "${PREV_LIST[@]}"; do
  [[ -n "$rel" ]] || continue
  printf '%s\n' "${FILES[@]}" | grep -qxF "$rel" && continue
  is_protected "$rel" && continue
  [[ -f "$BACKEND_DIR/$rel" ]] || continue
  info "removing $rel (deleted in main; in the backup, so the revert restores it)"
  rm -f "$BACKEND_DIR/$rel"
done
find "$BACKEND_DIR" -maxdepth 1 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

# The drift fingerprint for the NEXT deploy must describe what is actually on
# disk now, not what the repo holds — the two differ whenever a file needed CRLF
# normalisation.
sha_dir_manifest "$BACKEND_DIR" "${FILES[@]}" > "$RELEASE_DIR/MANIFEST"
ok "${#FILES[@]} backend file(s) in place"

hdr "9. Odometer script"
STEP="deploy/ingest"
# Write via a temp file and rename, exactly as the backend copy above does.
# `sed … > "$INGEST_DIR/fetch_odometer.py"` truncates the LIVE file first, so a
# signal or ENOSPC part-way through leaves a truncated script on the ingest host —
# and root's crontab runs it every 15 minutes. The rename is atomic, so the file
# is either the old one or the new one, never half of either. It also inherits the
# source's mode, which the bare redirect only did when the target already existed
# (a newly created fetch_odometer.py landed 0644, not executable).
deploy_ingest_file() {   # $1 = filename
  local f="$1" tmp="$INGEST_DIR/$1.deploying.$$"
  DEPLOY_TMP="$tmp"
  sed 's/\r$//' "$SRC_REPO/$f" > "$tmp" || { rm -f "$tmp"; DEPLOY_TMP=""; die "could not write $f"; }
  chmod --reference="$SRC_REPO/$f" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$INGEST_DIR/$f"
  DEPLOY_TMP=""
}
if [[ -f "$SRC_REPO/fetch_odometer.py" ]]; then
  deploy_ingest_file fetch_odometer.py
  ok "fetch_odometer.py -> $INGEST_DIR (next cron run picks it up)"
  # MANIFEST.ingest is written once, below, covering every deployed ingest file.
fi
if (( OPT_WITH_INGEST_DAEMON )) && [[ -f "$SRC_REPO/ingest_from_dockerlogs.py" ]]; then
  deploy_ingest_file ingest_from_dockerlogs.py
  chmod +x "$INGEST_DIR/ingest_from_dockerlogs.py"
  systemctl restart "$INGEST_SERVICE"
  ok "ingest_from_dockerlogs.py deployed, $INGEST_SERVICE restarted"
fi
# Same sweep the run-dir gets: an interrupt between the sed and the mv leaves a
# <name>.deploying.<pid> that nothing else would ever clean up.
shopt -s nullglob
for stray in "$INGEST_DIR"/*.deploying.*; do
  warn "removing leftover staging file from an interrupted deploy: $stray"
  rm -f "$stray"
done
shopt -u nullglob
# Fingerprint every ingest file this tool actually deploys, not just the odometer
# script: MANIFEST.ingest used to record fetch_odometer.py alone, so a hand-fix in
# ingest_from_dockerlogs.py passed the drift gate and was silently overwritten by
# the next --with-ingest-daemon deploy.
_ingest_tracked=()
for f in fetch_odometer.py ingest_from_dockerlogs.py; do
  [[ -f "$INGEST_DIR/$f" ]] && _ingest_tracked+=("$f")
done
if (( ${#_ingest_tracked[@]} )); then
  sha_dir_manifest "$INGEST_DIR" "${_ingest_tracked[@]}" > "$RELEASE_DIR/MANIFEST.ingest"
fi

hdr "10. Frontend publish"
STEP="deploy/frontend"
# Stage beside the live tree and swap with renames: `rm -rf assets` followed by
# a slow `cp` leaves an index.html referencing JS that is not there yet — a
# white-screened production site for the duration, and permanently if the copy
# is interrupted. legal/ is never touched (published PDFs live only there).
NEWDIR="$WEBROOT/.publish.$$"
rm -rf "$NEWDIR"
cp -r "$SRC_REPO/frontend/dist" "$NEWDIR" || die "could not stage the new frontend"
chmod -R a+rX "$NEWDIR"
if [[ -d "$NEWDIR/legal" && -d "$WEBROOT/legal" ]]; then
  # The repo ships some legal PDFs; hand-published ones exist only on the server.
  # Merge without deleting, so a published version is never replaced by absence.
  cp -rn "$WEBROOT/legal/." "$NEWDIR/legal/" 2>/dev/null || true
elif [[ -d "$WEBROOT/legal" ]]; then
  cp -r "$WEBROOT/legal" "$NEWDIR/legal"
fi
# Publish with ONE rsync pass rather than "move the live tree aside, then move the
# new one in". That two-loop swap had a window between the loops where $WEBROOT
# held no index.html and no assets/ at all — the site 404s, and if the process
# died there production stayed empty with its only content in .retired.$$. It also
# discarded every mv error (2>/dev/null || true) and then rm -rf'd the retired
# copy unconditionally: a single failed rename (EACCES/EBUSY, or assets/ nesting
# into assets/assets/) deleted the live webroot, hand-published legal/ PDFs
# included. rsync replaces files in place and never empties the directory.
#
# legal/ is excluded from the transfer entirely: the published PDFs were merged
# into $NEWDIR above with cp -rn, and `P` alone would let an older tracked PDF
# overwrite a hand-republished one of the same name.
[[ -s "$NEWDIR/index.html" ]] \
  || die "staged frontend has no index.html — refusing to publish. $WEBROOT is untouched."
rsync -a --delete \
      --filter='P legal/***' --filter='- legal/***' \
      --filter='P .publish.*' --filter='P .retired.*' \
      "$NEWDIR/" "$WEBROOT/" \
  || die "publishing the frontend failed — $WEBROOT may be partially updated.
       Re-run, or restore with bin/revert.sh."
[[ -s "$WEBROOT/index.html" && -d "$WEBROOT/assets" ]] \
  || die "the published webroot has no index.html or no assets/ — production may be
       serving nothing. Restore with bin/revert.sh."
# legal/ was held out of the pass above, so publish the repo's tracked PDFs in a
# second, ADD-ONLY pass: --ignore-existing installs a genuinely new agreement
# version but never replaces a published file, and nothing here deletes.
if [[ -d "$NEWDIR/legal" ]]; then
  mkdir -p "$WEBROOT/legal"
  rsync -a --ignore-existing "$NEWDIR/legal/" "$WEBROOT/legal/" \
    || warn "could not publish tracked legal/ PDFs — check $WEBROOT/legal by hand"
fi
rm -rf "$NEWDIR"
chmod -R a+rX "$WEBROOT"
ok "published to $WEBROOT (legal/ preserved)"

if (( OPT_WITH_CADDY )); then
  hdr "11. Caddy"
  STEP="deploy/caddy"
  if [[ -f "$SRC_REPO/server-config/Caddyfile" ]] && ! cmp -s "$SRC_REPO/server-config/Caddyfile" "$CADDYFILE"; then
    # Validate the SOURCE before installing it. Installing first and validating
    # after leaves an invalid file at $CADDYFILE when validation fails: the
    # running Caddy keeps its in-memory config, so the failure looks contained,
    # but the next reload, package upgrade or reboot takes TLS and the proxy down
    # for production. Backup -> validate -> install -> reload.
    caddy validate --config "$SRC_REPO/server-config/Caddyfile" --adapter caddyfile \
      || die "new Caddyfile does NOT validate — nothing was installed and the running
       config is untouched. Fix server-config/Caddyfile in the app repo."
    cp -a "$CADDYFILE" "$CADDYFILE.bak.$(now_id)"
    cp "$SRC_REPO/server-config/Caddyfile" "$CADDYFILE"
    systemctl reload caddy || die "caddy reload failed"
    ok "Caddyfile updated, validated and reloaded"
  else
    ok "Caddyfile unchanged"
  fi
fi

hdr "12. Restart backend"
STEP="restart"
systemctl restart "${BACKEND_SERVICES[@]}" || die "service restart failed"
ok "restarted ${BACKEND_SERVICES[*]}"

hdr "13. Resuming cron"
STEP="cron-resume"
resume_cron
ok "cron running"

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

# Only now is it true that production runs the new commit.
sed -i "s/^RUNNING_COMMIT=.*/RUNNING_COMMIT=$TARGET_COMMIT/" "$RELEASE_DIR/meta.env"
sed -i "s/^DEPLOY_COMPLETED=.*/DEPLOY_COMPLETED=1/" "$RELEASE_DIR/meta.env"

trap - EXIT INT TERM HUP
hdr "${C_GRN}Deploy complete${C_OFF}"
log "  now running : ${TARGET_COMMIT:0:8}  $(git -C "$SRC_REPO" log -1 --format=%s)"
log "  revert with : sudo $HERE/bin/revert.sh            (dry run first)"
log "  backup      : $RELEASE_DIR  ($REL_ID, db-dump=$DUMP_MODE)"
log ""
log "This backup is the ONLY way back. The next deploy replaces it."
