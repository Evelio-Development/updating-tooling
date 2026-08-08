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

if [[ -f "$BREADCRUMB" ]]; then
  hdr "${C_RED}A DATABASE SWAP DID NOT FINISH${C_OFF}"
  cat "$BREADCRUMB"
  log ""
  log "update.sh and revert.sh refuse to run until this is resolved."
  log ""
fi

hdr "Production"
for u in "${BACKEND_SERVICES[@]}" "$INGEST_SERVICE" caddy; do
  printf '  %-22s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo '?')"
done
printf '  %-22s %s\n' "database $PG_DB" "$(human "$(db_size_bytes "$PG_DB")")"
printf '  %-22s %s\n' "webroot" "$(du -sh "$WEBROOT" 2>/dev/null | cut -f1)"
printf '  %-22s %sGB free\n' "disk" "$(free_gb "$UPD_ROOT")"

shopt -s nullglob
for stray in "$RELEASES_DIR"/new.* "$RELEASES_DIR"/old.*; do
  warn "leftover release staging dir: $stray ($(du -sh "$stray" 2>/dev/null | cut -f1))"
done
shopt -u nullglob

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
  # No SKIPPED_TESTS field is written any more: --skip-tests was removed, so a
  # release can only exist if the gate passed. Reporting a state the tool cannot
  # produce is worse than reporting nothing.
  printf '  completed : %s\n' "$( [[ "${DEPLOY_COMPLETED:-0}" == "1" ]] && echo yes || echo "${C_YEL}NO — the deploy never verified${C_OFF}" )"
  [[ -n "${REVERTED_AT:-}" ]] && warn "already reverted at $REVERTED_AT (${REVERTED_MODE:-?}) — reverting again needs --force"
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
# Only evelio_prerevert_* is prunable. evelio_restore_* is the SCRATCH database
# of a revert that may be running right now in another terminal — dropping it
# mid-restore would kill that revert.
mapfile -t aside < <(psql_maint -tAc "select datname from pg_database where datname like 'evelio_prerevert_%' order by datname" </dev/null)
mapfile -t scratch < <(psql_maint -tAc "select datname from pg_database where datname like 'evelio_restore_%' order by datname" </dev/null)

if (( ${#aside[@]} == 0 )) || [[ -z "${aside[0]:-}" ]]; then
  ok "no pre-revert databases"
  aside=()
else
  for d in "${aside[@]}"; do printf '  %-34s %s\n' "$d" "$(human "$(db_size_bytes "$d")")"; done
fi

if (( ${#scratch[@]} )) && [[ -n "${scratch[0]:-}" ]]; then
  log ""
  warn "scratch restore database(s) present:"
  for d in "${scratch[@]}"; do
    busy="$(psql_maint -tAc "select count(*) from pg_stat_activity where datname='$d'" </dev/null || echo 0)"
    printf '  %-34s %s  %s\n' "$d" "$(human "$(db_size_bytes "$d")")" \
      "$( [[ "${busy:-0}" != "0" ]] && echo "${C_YEL}IN USE — a revert may be running${C_OFF}" || echo "(idle; leftover from an interrupted revert)" )"
  done
  log "  These are never pruned automatically. If no revert is running, drop them:"
  log "    docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres -c 'DROP DATABASE \"<name>\" WITH (FORCE)'"
fi

if (( PRUNE )); then
  # An evelio_prerevert_* database is not always "the old copy": between the two
  # renames of a swap, and after any crash in that window, it IS production's
  # only data and no database named evelio exists. Pruning then destroys prod
  # irrecoverably — and the prompt's own wording ("the ONLY copies") reads as
  # reassurance while describing exactly that. So: refuse while a swap is
  # unresolved, refuse if the live database is missing, take the lock so a revert
  # running in another terminal cannot have its aside copy pulled out from under
  # it, and skip any candidate that still has sessions on it.
  assert_no_breadcrumb
  take_lock "prune-aside"
  db_exists "$PG_DB" \
    || die "there is no database named '$PG_DB'. One of the databases below is
       therefore production's live data, not a spare copy. Refusing to prune.
       Rename the right one back into place first (see bin/revert.sh output)."
  if (( ${#aside[@]} == 0 )); then
    ok "nothing to prune"
  else
    keep=(); drop=()
    for d in "${aside[@]}"; do
      busy="$(psql_maint -tAc "select count(*) from pg_stat_activity where datname='$d'" </dev/null || echo 1)"
      if [[ "${busy:-1}" != "0" ]]; then keep+=("$d"); else drop+=("$d"); fi
    done
    (( ${#keep[@]} )) && warn "skipping (sessions still attached — a revert may be running): ${keep[*]}"
    if (( ${#drop[@]} == 0 )); then
      ok "nothing prunable"
    else
      log ""
      warn "these are the ONLY copies of the data as it was just before a revert:"
      printf '    %s\n' "${drop[@]}"
      confirm "Dropping them is irreversible." "PRUNE" || die "aborted."
      for d in "${drop[@]}"; do
        info "dropping $d"; psql_maint -c "DROP DATABASE \"$d\" WITH (FORCE)" >/dev/null
      done
      ok "pruned"
    fi
  fi
elif (( ${#aside[@]} )); then
  log ""
  log "  free the space with: sudo $0 --prune-aside"
fi
