#!/usr/bin/env bash
#
# status.sh — what is deployed, what the backup holds, and what a revert would
#             cost. Read-only unless --prune-aside is given.
#
#   sudo bin/status.sh
#   sudo bin/status.sh --prune-aside      # drop kept evelio_prerevert_* databases
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/lib/common.sh"

PRUNE=0
for a in "$@"; do
  case "$a" in
    --prune-aside) PRUNE=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done
assert_root
assert_prod_layout

hdr "Production"
for u in "${BACKEND_SERVICES[@]}" "$INGEST_SERVICE" caddy; do
  printf '  %-22s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo '?')"
done
printf '  %-22s %s\n' "database $PG_DB" "$(human "$(db_size_bytes "$PG_DB")")"
printf '  %-22s %s\n' "webroot" "$(du -sh "$WEBROOT" 2>/dev/null | cut -f1)"
printf '  %-22s %sGB free\n' "disk" "$(free_gb "$UPD_ROOT")"

hdr "Source clone"
if [[ -d "$SRC_REPO/.git" ]]; then
  git -C "$SRC_REPO" fetch --prune origin >/dev/null 2>&1 || warn "fetch failed"
  printf '  origin/main : %s  %s\n' "$(git -C "$SRC_REPO" rev-parse --short "$GIT_REF")" \
    "$(git -C "$SRC_REPO" log -1 --format=%s "$GIT_REF")"
else
  warn "no clone yet — run bin/adopt.sh"
fi

hdr "Backup"
if load_release_meta; then
  printf '  release   : %s (%s)\n' "${RELEASE_ID:-?}" "${RELEASE_KIND:-?}"
  printf '  created   : %s\n' "${CREATED_AT:-?}"
  printf '  running   : %s\n' "${RUNNING_COMMIT:-unknown}"
  printf '  reverts to: %s\n' "${PREV_COMMIT:-unknown}"
  printf '  db dump   : %s %s\n' "${DB_DUMP_MODE:-none}" \
    "$( [[ -f "$RELEASE_DIR/db.dump" ]] && human "$(stat -c%s "$RELEASE_DIR/db.dump")" )"
  [[ "${SKIPPED_TESTS:-0}" == "1" ]] && warn "this release was deployed with --skip-tests"
  [[ -n "${REVERTED_AT:-}" ]] && warn "already reverted at $REVERTED_AT (${REVERTED_MODE:-?}) — this backup has been consumed"
else
  warn "no backup — nothing to revert to. Run bin/adopt.sh, then bin/update.sh."
fi

hdr "Drift in $BACKEND_DIR"
if [[ -f "$RELEASE_DIR/MANIFEST" ]]; then
  n=0
  while read -r sha rel; do
    [[ -n "$rel" ]] || continue
    if [[ "$sha" == "ABSENT" ]]; then [[ -e "$BACKEND_DIR/$rel" ]] && { log "  appeared  $rel"; (( ++n )); }; continue; fi
    if [[ ! -e "$BACKEND_DIR/$rel" ]]; then log "  deleted   $rel"; (( ++n ))
    elif [[ "$(norm_sha "$BACKEND_DIR/$rel")" != "$sha" ]]; then log "  modified  $rel"; (( ++n )); fi
  done < "$RELEASE_DIR/MANIFEST"
  (( n )) && warn "$n file(s) changed outside this tool — update.sh will refuse until you re-adopt" || ok "clean"
else
  warn "no manifest"
fi

hdr "Kept pre-revert databases"
mapfile -t aside < <(psql_maint -tAc "select datname from pg_database where datname like 'evelio_prerevert_%' or datname like 'evelio_restore_%'")
if (( ${#aside[@]} == 0 )) || [[ -z "${aside[0]:-}" ]]; then
  ok "none"
else
  for d in "${aside[@]}"; do printf '  %-34s %s\n' "$d" "$(human "$(db_size_bytes "$d")")"; done
  if (( PRUNE )); then
    log ""
    warn "these are the ONLY copies of the data as it was just before a revert."
    confirm "Dropping them is irreversible." "PRUNE" || die "aborted."
    for d in "${aside[@]}"; do
      info "dropping $d"; psql_maint -c "DROP DATABASE \"$d\" WITH (FORCE)" >/dev/null
    done
    ok "pruned"
  else
    log ""
    log "  free the space with: sudo $0 --prune-aside"
  fi
fi
