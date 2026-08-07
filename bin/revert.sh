#!/usr/bin/env bash
#
# revert.sh — put production back to the state it was in before the last
#             update.sh --apply.
#
# DRY RUN IS THE DEFAULT.
#
#   sudo bin/revert.sh                 # show exactly what would change/be lost
#   sudo bin/revert.sh --apply         # code + frontend + FULL database restore
#   sudo bin/revert.sh --apply --code-only   # touch no data at all
#   sudo bin/revert.sh --apply --db-only     # database only
#
# The database is restored via a SIDE DATABASE: the dump is loaded into
# evelio_restore, verified there, and only then renamed into place. The live
# database is never dropped — it is renamed aside to evelio_prerevert_<ts> and
# kept, so a revert can itself be undone. See CLAUDE.md.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=../lib/db-restore.sh
source "$HERE/lib/db-restore.sh"

APPLY=0; CODE_ONLY=0; DB_ONLY=0; KEEP_ASIDE=1
while (( $# )); do
  case "$1" in
    --apply)     APPLY=1 ;;
    --code-only) CODE_ONLY=1 ;;
    --db-only)   DB_ONLY=1 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
(( CODE_ONLY && DB_ONLY )) && die "--code-only and --db-only are mutually exclusive"

assert_root
assert_prod_layout

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
       and no verified code snapshot. There has been no deploy to revert."
fi

[[ -f "$RELEASE_DIR/FILES.new" ]] || die "backup has no FILES.new (file list) — it is incomplete"
[[ -d "$RELEASE_DIR/backend"  ]] || die "backup has no backend snapshot"
[[ -f "$RELEASE_DIR/frontend/webroot.tgz" ]] || die "backup has no frontend snapshot"
tar -tzf "$RELEASE_DIR/frontend/webroot.tgz" >/dev/null 2>&1 || die "frontend snapshot is not a readable tarball"
ok "code + frontend snapshots readable"

if (( ! CODE_ONLY )); then
  [[ "${HAS_DB_DUMP:-0}" == "1" && -f "$RELEASE_DIR/db.dump" ]] \
    || die "backup has no database dump. Use --code-only, or restore by hand."
  info "checking the dump reads back"
  docker cp "$RELEASE_DIR/db.dump" "$PG_CONTAINER":/tmp/verify.dump >/dev/null
  docker exec "$PG_CONTAINER" pg_restore --list /tmp/verify.dump >/dev/null \
    || { docker exec "$PG_CONTAINER" rm -f /tmp/verify.dump; die "the dump is unreadable — do NOT proceed. Restore by hand."; }
  docker exec "$PG_CONTAINER" rm -f /tmp/verify.dump
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
  printf '  %-32s %12s %12s %10s\n' TABLE NOW BACKUP DELTA
  lost_any=0
  while IFS='|' read -r t c; do
    [[ -n "$t" ]] || continue
    pre="$(awk -F'|' -v k="$t" '$1==k{print $2}' "$RELEASE_DIR/rowcounts.pre")"
    pre="${pre:-0}"
    d=$(( c - pre ))
    if (( d != 0 )); then
      lost_any=1
      printf '  %-32s %12s %12s %+10d\n' "$t" "$c" "$pre" "$d"
    fi
  done < "$tmpnow"
  rm -f "$tmpnow"
  (( lost_any )) || log "  (no row-count changes since the backup)"
  log ""
  log "  A positive delta = rows that exist now and will be GONE after the revert."
  log "  A negative delta = rows deleted since the backup; they come back."
  log "  Row counts do not show UPDATEs — edited records revert too."
  if [[ "${DB_DUMP_MODE:-}" == "soft" ]]; then
    log ""
    warn "this is a SOFT dump: telemetry_raw rows are not in it."
    log "  To avoid destroying telemetry, the restore copies the CURRENT telemetry_raw"
    log "  into the restored database before the swap. That copy is several GB and"
    log "  takes minutes with the services stopped."
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
  done < <(cat "$RELEASE_DIR/FILES.new" "$RELEASE_DIR/FILES.prev" 2>/dev/null | sort -u)
  (( n )) || log "  (backend code already matches the backup)"
  log "  restore  $WEBROOT  (from snapshot; legal/ comes from the snapshot too)"
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
  log "${C_RED}${C_BLD}This will roll the production database back to ${CREATED_AT:-?}.${C_OFF}"
  log "Everything in the table above is discarded. This is not reversible by"
  log "this tool beyond the single aside-copy it keeps (see below)."
  confirm "" "REVERT-DATABASE" || die "aborted — production untouched."
fi

if (( ! CODE_ONLY )); then
  DB_BYTES="$(db_size_bytes "$PG_DB")"
  assert_disk_for $(( DB_BYTES / 1000000000 * 2 + 2 )) /var/lib/docker
fi

# =================================================== 5. STOP THE WRITERS ====
hdr "5. Stopping services"
STOPPED=("${BACKEND_SERVICES[@]}")
(( CODE_ONLY )) || STOPPED+=("$INGEST_SERVICE")
for u in "${STOPPED[@]}"; do
  info "stop $u"; systemctl stop "$u" || warn "could not stop $u"
done
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

restart_all() {
  for u in "${STOPPED[@]}"; do systemctl start "$u" || warn "could not start $u"; done
}
# From here, never leave the box with services down.
trap 'rc=$?; warn "revert aborted (rc=$rc) — restarting services"; restart_all; exit $rc' EXIT

# ========================================================== 6. CODE ========
if (( ! DB_ONLY )); then
  hdr "6. Restoring code"
  mapfile -t RESTORED < <(cat "$RELEASE_DIR/FILES.new" "$RELEASE_DIR/FILES.prev" 2>/dev/null | sort -u)
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
  find "$BACKEND_DIR" -maxdepth 2 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

  # The drift fingerprint now has to describe the RESTORED code. Without this,
  # the next update.sh would see the whole rollback as "drift" and refuse.
  sha_dir_manifest "$BACKEND_DIR" "${RESTORED[@]}" > "$RELEASE_DIR/MANIFEST"
  ok "backend code restored"

  if [[ -f "$RELEASE_DIR/ingest/fetch_odometer.py" ]]; then
    cp -a "$RELEASE_DIR/ingest/fetch_odometer.py" "$INGEST_DIR/"; ok "fetch_odometer.py restored"
  fi
  if [[ -f "$RELEASE_DIR/ingest/ingest_from_dockerlogs.py" ]]; then
    cp -a "$RELEASE_DIR/ingest/ingest_from_dockerlogs.py" "$INGEST_DIR/"; ok "ingest_from_dockerlogs.py restored"
  fi

  info "restoring $WEBROOT"
  tmpd="$(mktemp -d)"
  tar -C "$tmpd" -xzf "$RELEASE_DIR/frontend/webroot.tgz"
  rsync -a --delete "$tmpd/" "$WEBROOT/"
  chmod -R a+rX "$WEBROOT"
  rm -rf "$tmpd"
  ok "frontend restored"

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
  restore_db_swap "$RELEASE_DIR/db.dump" "$RELEASE_DIR/rowcounts.pre" "${DB_DUMP_MODE:-full}"
  log "  pre-revert database kept as '$ASIDE_DB' ($(human "$(db_size_bytes "$ASIDE_DB")"))"
fi

# ========================================================= 8. BRING UP =====
# Record that this backup has been consumed: production is now the PREV state,
# and reverting again would be a no-op.
{
  sed -i "s/^RUNNING_COMMIT=.*/RUNNING_COMMIT=${PREV_COMMIT:-unknown}/" "$RELEASE_DIR/meta.env"
  grep -q '^REVERTED_AT=' "$RELEASE_DIR/meta.env" \
    && sed -i "s|^REVERTED_AT=.*|REVERTED_AT=$(date -u +%FT%TZ)|" "$RELEASE_DIR/meta.env" \
    || echo "REVERTED_AT=$(date -u +%FT%TZ)" >> "$RELEASE_DIR/meta.env"
  echo "REVERTED_MODE=$( (( CODE_ONLY )) && echo code-only || { (( DB_ONLY )) && echo db-only || echo full; })" >> "$RELEASE_DIR/meta.env"
} || warn "could not update release metadata"

trap - EXIT
hdr "8. Restarting services"
restart_all

STEP=verify
verify_prod "$STARTED_AT"

hdr "$( (( VERIFY_FAILED )) && echo "${C_RED}REVERT COMPLETED, BUT VERIFICATION FAILED${C_OFF}" || echo "${C_GRN}Revert complete${C_OFF}")"
if (( ! CODE_ONLY )); then
  log "  pre-revert database kept as : $ASIDE_DB"
  log "  undo this revert            : stop the services, then"
  log "      docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres -c \\"
  log "        'ALTER DATABASE \"$PG_DB\" RENAME TO \"${PG_DB}_undo_$(now_id)\"; ALTER DATABASE \"$ASIDE_DB\" RENAME TO \"$PG_DB\";'"
  log "  free the space when you are sure ($(human "$(db_size_bytes "$ASIDE_DB" 2>/dev/null || echo 0)")):"
  log "      sudo $HERE/bin/status.sh --prune-aside"
fi
if (( VERIFY_FAILED )); then
  log ""
  warn "production is running the reverted state but the health checks did not pass."
  log "Check: journalctl -u tesla-oauth -n 100 --no-pager"
  exit 1
fi
