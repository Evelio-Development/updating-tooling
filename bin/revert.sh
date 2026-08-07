#!/usr/bin/env bash
#
# revert.sh — put production back to the state it was in before the last
#             update.sh --apply.
#
# DRY RUN IS THE DEFAULT.
#
#   sudo bin/revert.sh                       # show what would change and be lost
#   sudo bin/revert.sh --apply               # code + frontend + FULL db restore
#   sudo bin/revert.sh --apply --code-only   # touch no data at all
#   sudo bin/revert.sh --apply --db-only     # database only
#   sudo bin/revert.sh --apply --force       # revert again after a revert
#
# The database is restored via a SIDE DATABASE: the dump is loaded into
# evelio_restore_<ts>, verified there, and only then renamed into place. The
# live database is never dropped — it is renamed aside to evelio_prerevert_<ts>
# and kept, so a revert can itself be undone. See CLAUDE.md.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=../lib/db-restore.sh
source "$HERE/lib/db-restore.sh"

APPLY=0; CODE_ONLY=0; DB_ONLY=0; FORCE=0
while (( $# )); do
  case "$1" in
    --apply)     APPLY=1 ;;
    --code-only) CODE_ONLY=1 ;;
    --db-only)   DB_ONLY=1 ;;
    --force)     FORCE=1 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
(( CODE_ONLY && DB_ONLY )) && die "--code-only and --db-only are mutually exclusive"

assert_root
assert_prod_layout
assert_no_breadcrumb
(( APPLY )) && take_lock "revert"

INTERRUPTED=0
STOPPED=()

hdr "Evelio production REVERT"
(( APPLY )) || log "${C_YEL}DRY RUN${C_OFF} — nothing will be changed. Add --apply to execute."

# ==================================================== 1. VALIDATE BACKUP ====
hdr "1. Backup integrity"
[[ -d "$RELEASE_DIR" ]] || die "no backup at $RELEASE_DIR — there is nothing to revert to."
load_release_meta || die "corrupt $RELEASE_DIR/meta.env"

log "  release      : ${RELEASE_ID:-?}  (kind=${RELEASE_KIND:-?})"
log "  created      : ${CREATED_AT:-?}"
log "  reverts to   : ${PREV_COMMIT:-unknown}"
log "  now running  : ${RUNNING_COMMIT:-unknown}"
log "  db dump      : ${DB_DUMP_MODE:-none}"

if [[ "${RELEASE_KIND:-}" == "baseline" ]]; then
  die "the only stored release is an adopt.sh BASELINE — it has no database dump
       and no code snapshot. There has been no deploy to revert."
fi

# A backup is a one-shot. Restoring the same dump a second time rewinds
# everything production has done SINCE the first revert, and creates a second
# aside database — with the first revert's aside (the only copy of the
# post-deploy data) still sitting there unmentioned.
if [[ -n "${REVERTED_AT:-}" ]]; then
  hdr "THIS BACKUP HAS ALREADY BEEN REVERTED"
  log "  reverted at : $REVERTED_AT  (mode: ${REVERTED_MODE:-?})"
  log ""
  log "Production has already been rolled back to this release. Reverting again"
  log "restores the SAME dump on top, discarding everything since $REVERTED_AT."
  mapfile -t asides < <(psql_maint -tAc "select datname from pg_database where datname like 'evelio_prerevert_%' order by datname" </dev/null)
  if (( ${#asides[@]} )) && [[ -n "${asides[0]:-}" ]]; then
    log ""
    log "  The data from before that revert is still here:"
    for d in "${asides[@]}"; do log "    $d  ($(human "$(db_size_bytes "$d")"))"; done
    log "  To go FORWARD to it instead, rename it into place with the services stopped."
  fi
  (( FORCE )) || die "refusing. Re-run with --force if you really mean to revert twice."
  warn "--force given — proceeding with a second revert."
fi

[[ -f "$RELEASE_DIR/FILES.new" ]] || die "backup has no FILES.new (file list) — it is incomplete"
[[ -d "$RELEASE_DIR/backend"  ]] || die "backup has no backend snapshot"
[[ -f "$RELEASE_DIR/frontend/webroot.tgz" ]] || die "backup has no frontend snapshot"
tar -tzf "$RELEASE_DIR/frontend/webroot.tgz" >/dev/null 2>&1 || die "frontend snapshot is not a readable tarball"
ok "code + frontend snapshots readable"

if (( ! CODE_ONLY )); then
  [[ "${HAS_DB_DUMP:-0}" == "1" && -f "$RELEASE_DIR/db.dump" ]] \
    || die "backup has no database dump. Use --code-only, or restore by hand."
  [[ -s "$RELEASE_DIR/rowcounts.pre" ]] \
    || die "backup has no row counts — a restore could not be verified. Refusing."
  info "checking the dump reads back"
  docker exec -i "$PG_CONTAINER" pg_restore --list < "$RELEASE_DIR/db.dump" >/dev/null 2>&1 \
    || die "the dump is unreadable — do NOT proceed. Restore by hand."
  ok "dump verified: $(human "$(stat -c%s "$RELEASE_DIR/db.dump")")"
fi

# ================================================ 2. WHAT WILL BE LOST ======
if (( ! CODE_ONLY )); then
  hdr "2. What the database restore will DISCARD"
  age_h=$(( ( $(date +%s) - $(date -d "${CREATED_AT:-now}" +%s 2>/dev/null || date +%s) ) / 3600 ))
  log "  the backup is ${age_h}h old — every write production accepted in that"
  log "  window is undone: sign-ups, agreement acceptances, onboarding, telemetry."
  log ""

  tmpnow="$(mktemp)"; capture_rowcounts "$tmpnow"
  printf '  %-38s %12s %12s %11s\n' TABLE NOW BACKUP DELTA
  lost_any=0
  while IFS='|' read -r t c; do
    [[ -n "$t" ]] || continue
    pre="$(awk -F'|' -v k="$t" '$1==k{print $2}' "$RELEASE_DIR/rowcounts.pre")"
    if [[ -z "$pre" ]]; then
      lost_any=1
      printf '  %-38s %12s %12s %11s\n' "$t" "$c" "-" "DROPPED"
      continue
    fi
    d=$(( c - pre ))
    (( d != 0 )) && { lost_any=1; printf '  %-38s %12s %12s %+11d\n' "$t" "$c" "$pre" "$d"; }
  done < "$tmpnow"
  # Tables that existed at backup time and do not exist now come BACK.
  while IFS='|' read -r t c; do
    [[ -n "$t" ]] || continue
    grep -q "^$t|" "$tmpnow" || { lost_any=1; printf '  %-38s %12s %12s %11s\n' "$t" "-" "$c" "RECREATED"; }
  done < "$RELEASE_DIR/rowcounts.pre"
  rm -f "$tmpnow"
  (( lost_any )) || log "  (no row-count changes since the backup)"
  log ""
  log "  A positive delta = rows that exist now and will be GONE after the revert."
  log "  A negative delta = rows deleted since the backup; they come back."
  log "  Row counts do not show UPDATEs — edited records revert too."
  if [[ "${DB_DUMP_MODE:-}" == "soft" ]]; then
    log ""
    warn "this is a SOFT dump: telemetry_raw rows are not in it."
    log "  Live telemetry is copied into the restored database before the swap, so"
    log "  it survives. That copy is several GB and takes minutes with services down."
    log "  Telemetry belonging to vehicles onboarded since the backup cannot be"
    log "  carried over (the vehicle row is being removed); it stays in the kept"
    log "  pre-revert database."
  fi
fi

# ======================================================= 3. CODE DIFF =======
if (( ! DB_ONLY )); then
  hdr "3. Code that will be restored"
  n=0
  while read -r rel; do
    [[ -n "$rel" ]] || continue
    is_protected "$rel" && continue
    if [[ -f "$RELEASE_DIR/backend/$rel" ]]; then
      same_content "$RELEASE_DIR/backend/$rel" "$BACKEND_DIR/$rel" || { log "  restore  $rel"; (( ++n )); }
    else
      [[ -f "$BACKEND_DIR/$rel" ]] && { log "  remove   $rel  (did not exist before the deploy)"; (( ++n )); }
    fi
  done < <(cat "$RELEASE_DIR/FILES.new" "$RELEASE_DIR/FILES.prev" 2>/dev/null | sed '/^$/d' | sort -u)
  (( n )) || log "  (backend code already matches the backup)"

  log ""
  log "  $WEBROOT is restored from the snapshot. legal/ is never deleted; these"
  log "  files exist now, are not in the snapshot, and WILL be removed:"
  dels="$(webroot_deletions "$RELEASE_DIR/frontend/webroot.tgz")"
  if [[ -n "$dels" ]]; then printf '%s\n' "$dels"; else log "    (none)"; fi
fi

if (( ! APPLY )); then
  hdr "DRY RUN complete — production untouched."
  log "Run again with --apply to execute."
  exit 0
fi

# ========================================================= 4. CONFIRM ======
hdr "4. Confirm"
if (( CODE_ONLY )); then
  log "CODE ONLY: the database will not be touched. No data can be lost."
  confirm "" "REVERT" || die "aborted — production untouched."
else
  if (( DB_ONLY )) && [[ "${RUNNING_COMMIT:-x}" != "${PREV_COMMIT:-y}" ]]; then
    warn "--db-only rewinds the SCHEMA too, while the NEW code stays deployed."
    log "  Columns a migration added disappear from under code that reads them:"
    log "  expect 500s. This mode is for use right after a failed deploy whose"
    log "  code has already been rolled back."
    log ""
  fi
  log "${C_RED}${C_BLD}This will roll the production database back to ${CREATED_AT:-?}.${C_OFF}"
  log "Everything in the table above is discarded. The pre-revert data is kept as"
  log "a database you can rename back; nothing else undoes this."
  confirm "" "REVERT-DATABASE" || die "aborted — production untouched."
fi

if (( ! CODE_ONLY )); then
  DB_BYTES="$(db_size_bytes "$PG_DB")"
  # The side copy and the aside copy exist at once; soft mode also streams the
  # whole telemetry table through WAL.
  assert_disk_for $(( DB_BYTES / 1000000000 * 2 + 4 )) /var/lib/docker
fi

# =================================================== 5. STOP THE WRITERS ====
restart_all() {
  if ! db_exists "$PG_DB"; then
    warn "NOT starting the services: there is no database named '$PG_DB'."
    log "  Your data is intact under an evelio_prerevert_* database. Put it back"
    log "  before starting anything — see $BREADCRUMB."
    return 1
  fi
  local u
  for u in "${STOPPED[@]}"; do systemctl start "$u" || warn "could not start $u"; done
  resume_cron
  return 0
}
on_abort() {
  local rc=$?
  (( INTERRUPTED )) && rc=130
  (( rc == 0 )) && return 0
  trap - EXIT
  warn "revert aborted (rc=$rc) — restarting services"
  restart_all || true
  exit "$rc"
}
on_signal() { INTERRUPTED=1; trap - INT TERM HUP; exit 130; }

# Install the traps BEFORE stopping anything: an interrupt in between would
# otherwise leave production down with nothing to bring it back.
trap on_abort EXIT
trap on_signal INT TERM HUP

hdr "5. Stopping services"
STOPPED=("${BACKEND_SERVICES[@]}")
(( CODE_ONLY )) || STOPPED+=("$INGEST_SERVICE")
for u in "${STOPPED[@]}"; do
  info "stop $u"; systemctl stop "$u" || warn "could not stop $u"
done
pause_cron
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

# ========================================================== 6. CODE ========
if (( ! DB_ONLY )); then
  hdr "6. Restoring code"
  mapfile -t RESTORED < <(cat "$RELEASE_DIR/FILES.new" "$RELEASE_DIR/FILES.prev" 2>/dev/null | sed '/^$/d' | sort -u)
  for rel in "${RESTORED[@]}"; do
    [[ -n "$rel" ]] || continue
    is_protected "$rel" && continue
    if [[ -f "$RELEASE_DIR/backend/$rel" ]]; then
      mkdir -p "$BACKEND_DIR/$(dirname "$rel")"
      cp -a "$RELEASE_DIR/backend/$rel" "$BACKEND_DIR/$rel"
    else
      rm -f "$BACKEND_DIR/$rel"
    fi
  done
  find "$BACKEND_DIR" -maxdepth 1 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

  # The drift fingerprint must describe the RESTORED code, or the next
  # update.sh sees the whole rollback as drift and refuses.
  sha_dir_manifest "$BACKEND_DIR" "${RESTORED[@]}" > "$RELEASE_DIR/MANIFEST"
  ok "backend code restored"

  if [[ -f "$RELEASE_DIR/ingest/fetch_odometer.py" ]]; then
    cp -a "$RELEASE_DIR/ingest/fetch_odometer.py" "$INGEST_DIR/"
    sha_dir_manifest "$INGEST_DIR" fetch_odometer.py > "$RELEASE_DIR/MANIFEST.ingest"
    ok "fetch_odometer.py restored"
  fi
  if [[ -f "$RELEASE_DIR/ingest/ingest_from_dockerlogs.py" ]]; then
    cp -a "$RELEASE_DIR/ingest/ingest_from_dockerlogs.py" "$INGEST_DIR/"
    ok "ingest_from_dockerlogs.py restored"
  fi

  info "restoring $WEBROOT"
  if restore_webroot "$RELEASE_DIR/frontend/webroot.tgz"; then
    ok "frontend restored (legal/ preserved)"
  else
    warn "frontend NOT restored — check $WEBROOT by hand"
  fi

  if [[ "${WITH_CADDY:-0}" == "1" && -f "$RELEASE_DIR/caddy/Caddyfile" ]]; then
    if ! cmp -s "$RELEASE_DIR/caddy/Caddyfile" "$CADDYFILE"; then
      cp -a "$CADDYFILE" "$CADDYFILE.bak.$(now_id)"
      cp "$RELEASE_DIR/caddy/Caddyfile" "$CADDYFILE"
      caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null \
        && systemctl reload caddy && ok "Caddyfile restored + reloaded" \
        || warn "restored Caddyfile did not validate — the running config is unchanged; fix by hand"
    fi
  fi
fi

# ======================================================= 7. DATABASE =======
if (( ! CODE_ONLY )); then
  hdr "7. Restoring the database (side database, then swap)"
  # The swap is two renames with a moment in between where no database is named
  # evelio. Signals are blocked across it; this breadcrumb is the only thing
  # that would tell the next person what happened if the machine died anyway.
  breadcrumb_write <<EOF
An Evelio database swap was in progress and did not finish.
started: $(date -u +%FT%TZ)

If no database named '$PG_DB' exists, YOUR DATA IS SAFE under an
evelio_prerevert_* database. List them:
  docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres -c '\\l'
Put it back:
  docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres \\
    -c 'ALTER DATABASE "<evelio_prerevert_...>" RENAME TO "$PG_DB"'
Then: systemctl start ${BACKEND_SERVICES[*]} $INGEST_SERVICE cron
Finally delete this file.
EOF
  trap '' INT TERM HUP
  restore_db_swap "$RELEASE_DIR/db.dump" "$RELEASE_DIR/rowcounts.pre" "${DB_DUMP_MODE:-full}"
  trap on_signal INT TERM HUP
  breadcrumb_clear
  log "  pre-revert database kept as '$ASIDE_DB' ($(human "$(db_size_bytes "$ASIDE_DB")"))"
fi

# Record that this backup has been consumed.
{
  # --db-only did not touch the code, so the running commit is unchanged.
  (( DB_ONLY )) || sed -i "s/^RUNNING_COMMIT=.*/RUNNING_COMMIT=${PREV_COMMIT:-unknown}/" "$RELEASE_DIR/meta.env"
  sed -i '/^REVERTED_AT=/d;/^REVERTED_MODE=/d' "$RELEASE_DIR/meta.env"
  {
    printf 'REVERTED_AT=%s\n' "$(date -u +%FT%TZ)"
    printf 'REVERTED_MODE=%s\n' "$( (( CODE_ONLY )) && echo code-only || { (( DB_ONLY )) && echo db-only || echo full; } )"
  } >> "$RELEASE_DIR/meta.env"
} || warn "could not update release metadata"

# ========================================================= 8. BRING UP =====
trap - EXIT INT TERM HUP
hdr "8. Restarting services"
restart_all || die "services were NOT started — see the message above. Fix the
       database first; production must not run against the wrong one."

verify_prod "$STARTED_AT"

hdr "$( (( VERIFY_FAILED )) && echo "${C_RED}REVERT COMPLETED, BUT VERIFICATION FAILED${C_OFF}" || echo "${C_GRN}Revert complete${C_OFF}")"
if (( ! CODE_ONLY )); then
  log "  pre-revert database kept as : $ASIDE_DB"
  log "  undo this revert (stop the services first):"
  log "      docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres -c \\"
  log "        'ALTER DATABASE \"$PG_DB\" RENAME TO \"${PG_DB}_undo_$(now_id)\";"
  log "         ALTER DATABASE \"$ASIDE_DB\" RENAME TO \"$PG_DB\";'"
  log "  free the space when you are sure:  sudo $HERE/bin/status.sh --prune-aside"
fi
if (( VERIFY_FAILED )); then
  log ""
  warn "production is running the reverted state but the health checks did not pass."
  log "Check: journalctl -u tesla-oauth -n 100 --no-pager"
  exit 1
fi
