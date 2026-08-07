#!/usr/bin/env bash
# shellcheck shell=bash
#
# db-restore.sh — the database half of a revert, isolated so it can be
# rehearsed. `lib/selftest.sh` exercises this exact function against the
# STAGING container before you ever point it at prod.
#
# Contract, and the reason it is written this way:
#
#   * The live database is NEVER dropped and never written to. It is renamed
#     aside and kept.
#   * Every failure mode before the swap leaves production bit-identical.
#   * The restored copy must match the row counts recorded at backup time, or
#     the swap does not happen.
#
# Sets ASIDE_DB (the kept pre-revert database) on success.

restore_db_swap() {   # $1 = dump file, $2 = rowcounts.pre file, $3 = full|soft
  local dump="$1" pre="$2" mode="$3"
  local ts side
  ts="$(now_id)"
  side="evelio_restore_$ts"
  ASIDE_DB="evelio_prerevert_$ts"

  [[ -f "$dump" ]] || die "restore_db_swap: no dump at $dump"
  [[ -f "$pre"  ]] || die "restore_db_swap: no row counts at $pre"

  local _cleanup_side
  _cleanup_side() {
    psql_maint -c "DROP DATABASE IF EXISTS \"$side\" WITH (FORCE)" >/dev/null 2>&1 || true
  }

  # A leftover from an interrupted earlier run would silently be restored into.
  if db_exists "$side"; then
    warn "stale $side found — dropping it"
    _cleanup_side
  fi

  # Self-contained integrity check: callers do this too, but this function must
  # never load a dump it has not read back itself.
  docker cp "$dump" "$PG_CONTAINER":/tmp/verify.$$.dump >/dev/null
  if ! docker exec "$PG_CONTAINER" pg_restore --list "/tmp/verify.$$.dump" >/dev/null 2>&1; then
    docker exec "$PG_CONTAINER" rm -f "/tmp/verify.$$.dump" || true
    die "the dump does not read back (pg_restore --list failed) — nothing changed."
  fi
  docker exec "$PG_CONTAINER" rm -f "/tmp/verify.$$.dump" || true

  info "creating side database $side"
  psql_maint -c "CREATE DATABASE \"$side\" OWNER \"$PG_USER\"" >/dev/null \
    || die "could not create $side — nothing changed."

  info "pg_restore into $side (the live database is still untouched)"
  docker cp "$dump" "$PG_CONTAINER":/tmp/restore.$$.dump >/dev/null
  if ! docker exec "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$side" \
        --no-owner --no-privileges --exit-on-error "/tmp/restore.$$.dump"; then
    docker exec "$PG_CONTAINER" rm -f "/tmp/restore.$$.dump" || true
    _cleanup_side
    die "pg_restore FAILED. The live database was never opened for writing —
       production is exactly as it was before this command."
  fi
  docker exec "$PG_CONTAINER" rm -f "/tmp/restore.$$.dump" || true
  ok "dump loaded into $side"

  # A soft dump carries no telemetry rows. Copy the LIVE ones across so the
  # swap cannot destroy telemetry.
  if [[ "$mode" == "soft" ]]; then
    info "soft dump: copying live telemetry_raw into $side (minutes, not seconds)"
    docker exec "$PG_CONTAINER" bash -c \
      "pg_dump -U '$PG_USER' -d '$PG_DB' --data-only -t public.telemetry_raw \
       | psql -U '$PG_USER' -d '$side' -v ON_ERROR_STOP=1 -q" \
      || { _cleanup_side; die "telemetry carry-over failed — live database untouched, nothing lost."; }
    ok "telemetry_raw carried over"
  fi

  info "verifying $side against the row counts recorded at backup time"
  local bad=0 checked=0 t c got
  # NOTE: `docker exec -i` inside a `while read` loop would consume the loop's
  # own stdin and silently skip every table after the first — which defeats the
  # entire verification. Read the list into an array first, and give the inner
  # command </dev/null as well. lib/selftest.sh case 2 exists to catch a
  # regression here; it caught exactly this bug once already.
  local -a rows=()
  mapfile -t rows < "$pre"
  for line in "${rows[@]}"; do
    [[ -n "$line" ]] || continue
    t="${line%%|*}"; c="${line##*|}"
    [[ -n "$t" ]] || continue
    [[ "$t" == "telemetry_raw" && "$mode" == "soft" ]] && continue
    got="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$side" -tAc \
            "select count(*) from public.\"$t\"" </dev/null 2>/dev/null || echo MISSING)"
    (( ++checked ))
    if [[ "$got" != "$c" ]]; then
      warn "  $t: restored=$got expected=$c"; bad=1
    fi
  done
  if (( checked == 0 )); then
    _cleanup_side
    die "verified ZERO tables — the recorded row counts are empty or unreadable.
       Refusing to swap on the strength of a check that did not run."
  fi
  info "  $checked table(s) verified"
  if (( bad )); then
    _cleanup_side
    die "the restored database does not match the backup's recorded row counts.
       The live database was NOT touched — production is unchanged. Do not retry
       blindly; the dump or the container is suspect."
  fi
  ok "row counts match the backup exactly"

  info "swapping databases"
  # Both renames need zero connections. Callers have already stopped the
  # services; this catches anything else (a psql session, a cron job).
  psql_maint -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                 WHERE datname IN ('$PG_DB','$side') AND pid <> pg_backend_pid()" >/dev/null
  sleep 1

  psql_maint -c "ALTER DATABASE \"$PG_DB\" RENAME TO \"$ASIDE_DB\"" >/dev/null \
    || { _cleanup_side; die "could not rename the live database (still-open connections?) — nothing changed."; }

  if ! psql_maint -c "ALTER DATABASE \"$side\" RENAME TO \"$PG_DB\"" >/dev/null; then
    warn "second rename failed — putting the original database back"
    if psql_maint -c "ALTER DATABASE \"$ASIDE_DB\" RENAME TO \"$PG_DB\"" >/dev/null; then
      _cleanup_side
      die "swap aborted — the production database is unchanged and back in place."
    fi
    die "CRITICAL: no database named '$PG_DB' exists right now.
       YOUR DATA IS INTACT under '$ASIDE_DB'. Put it back by hand:
         docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres \\
           -c 'ALTER DATABASE \"$ASIDE_DB\" RENAME TO \"$PG_DB\"'
       Then start the services: systemctl start ${BACKEND_SERVICES[*]}"
  fi

  ok "'$PG_DB' is now the restored copy; the pre-revert data is kept as '$ASIDE_DB'"
}
