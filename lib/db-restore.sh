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
#   * The restored copy must match the row counts captured in the same snapshot
#     as the dump, or the swap does not happen.
#   * Nothing may write to the live database between "verified" and "swapped" —
#     enforced with ALLOW_CONNECTIONS, not with a hopeful pg_terminate_backend.
#
# Sets ASIDE_DB (the kept pre-revert database) on success.

# Set by restore_db_swap so the cleanup trap knows what to tidy.
_RDS_SIDE=""
_RDS_LOCKED=0
_RDS_DONE=0

# Dropped side databases and re-opened connections on ANY exit — including
# Ctrl-C, SIGTERM and a dropped SSH session, which the previous version leaked
# (a 6.5 GB orphan per interrupted run, on the same filesystem as production
# Postgres).
_rds_cleanup() {
  (( _RDS_DONE )) && return 0
  if (( _RDS_LOCKED )); then
    psql_maint -c "ALTER DATABASE \"$PG_DB\" WITH ALLOW_CONNECTIONS true" >/dev/null 2>&1 || true
    _RDS_LOCKED=0
  fi
  if [[ -n "$_RDS_SIDE" ]]; then
    psql_maint -c "DROP DATABASE IF EXISTS \"$_RDS_SIDE\" WITH (FORCE)" >/dev/null 2>&1 || true
    _RDS_SIDE=""
  fi
}

restore_db_swap() {   # $1 = dump file, $2 = rowcounts file, $3 = full|soft
  local dump="$1" pre="$2" mode="$3"
  local ts side
  ts="$(now_id)"
  side="evelio_restore_$ts"
  ASIDE_DB="evelio_prerevert_$ts"
  _RDS_SIDE="$side"; _RDS_LOCKED=0; _RDS_DONE=0
  trap _rds_cleanup EXIT INT TERM

  [[ -f "$dump" ]] || die "restore_db_swap: no dump at $dump"
  [[ -s "$pre"  ]] || die "restore_db_swap: no row counts at $pre"

  # Leftovers from an interrupted earlier run: report them, never silently reuse.
  local stale
  stale="$(psql_maint -tAc "select string_agg(datname,' ') from pg_database where datname like 'evelio_restore_%'" </dev/null || true)"
  [[ -n "$stale" ]] && warn "leftover scratch database(s) from an interrupted run: $stale
       They are safe to drop (bin/status.sh --prune-aside); this run uses its own."

  # Self-contained integrity check: this function must never load a dump it has
  # not read back itself.
  info "checking the dump reads back"
  docker exec -i "$PG_CONTAINER" pg_restore --list < "$dump" >/dev/null 2>&1 \
    || die "the dump does not read back (pg_restore --list failed) — nothing changed."

  # Match the live database's encoding/locale exactly, and build from template0
  # so nothing anyone happens to have created in template1 rides along into
  # production at the swap.
  local enc coll ctype
  IFS='|' read -r enc coll ctype < <(psql_maint -tAF'|' -c \
    "select pg_encoding_to_char(encoding), datcollate, datctype from pg_database where datname='$PG_DB'" </dev/null)
  [[ -n "$enc" ]] || die "could not read $PG_DB's encoding/locale — nothing changed."

  info "creating side database $side (template0, $enc/$coll)"
  psql_maint -c "CREATE DATABASE \"$side\" OWNER \"$PG_USER\" TEMPLATE template0
                 ENCODING '$enc' LC_COLLATE '$coll' LC_CTYPE '$ctype'" >/dev/null \
    || die "could not create $side — nothing changed."

  info "pg_restore into $side (the live database is still untouched)"
  # NOTE: no file argument — pg_restore then reads the dump from stdin. Passing
  # /dev/stdin instead makes it try to seek a pipe, which fails, and the writer
  # dies of SIGPIPE before any error is printed.
  if ! docker exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$side" \
        --no-owner --no-privileges --exit-on-error < "$dump"; then
    _rds_cleanup
    die "pg_restore FAILED. The live database was never opened for writing —
       production is exactly as it was before this command."
  fi
  ok "dump loaded into $side"

  # A soft dump carries no telemetry rows, so the LIVE ones are copied across —
  # BEFORE the database is closed to connections, because the copy has to read
  # from it. The writers (services, cron) are already stopped by the caller, so
  # the source is quiet; anything that did sneak in between this copy and the
  # swap simply stays in the kept pre-revert database.
  if [[ "$mode" == "soft" ]]; then
    _carry_over_telemetry "$side" || { _rds_cleanup; return 1; }
  fi

  # ---------------------------------------------------------------------------
  # Close the live database to everyone BEFORE verifying and swapping.
  #
  # Stopping the services is not enough: root's crontab runs fetch_odometer.py
  # and run_outage_check.sh every 15 minutes and the notifier hourly, and a soft
  # restore holds the window open for minutes. Anything that connects in that
  # window both writes data that the swap then discards unseen, and can make the
  # rename fail with "database is being accessed by other users".
  # ALLOW_CONNECTIONS=false closes that structurally; the trap reopens it.
  # ---------------------------------------------------------------------------
  info "closing '$PG_DB' to new connections for the swap"
  psql_maint -c "ALTER DATABASE \"$PG_DB\" WITH ALLOW_CONNECTIONS false" >/dev/null \
    || { _rds_cleanup; die "could not close $PG_DB to connections — nothing changed."; }
  _RDS_LOCKED=1
  psql_maint -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                 WHERE datname = '$PG_DB' AND pid <> pg_backend_pid()" >/dev/null || true

  info "verifying $side against the row counts captured with the dump"
  local bad=0 checked=0 t c got
  # NOTE: `docker exec -i` inside a `while read` loop would consume the loop's
  # own stdin and silently skip every table after the first — which defeats the
  # entire verification. Read the list into an array first, and give the inner
  # command </dev/null as well. lib/selftest.sh exists to catch a regression
  # here; it caught exactly this bug once already.
  local -a rows=() ; local line sch tbl
  mapfile -t rows < "$pre"
  for line in "${rows[@]}"; do
    [[ -n "$line" ]] || continue
    t="${line%|*}"; c="${line##*|}"
    [[ -n "$t" ]] || continue
    sch="${t%%.*}"; tbl="${t#*.}"
    [[ "$t" == "public.telemetry_raw" && "$mode" == "soft" ]] && continue
    got="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$side" -tAc \
            "select count(*) from \"$sch\".\"$tbl\"" </dev/null 2>/dev/null || echo MISSING)"
    (( ++checked ))
    if [[ "$got" != "$c" ]]; then
      warn "  $t: restored=$got expected=$c"; bad=1
    fi
  done
  if (( checked == 0 )); then
    _rds_cleanup
    die "verified ZERO tables — the recorded row counts are empty or unreadable.
       Refusing to swap on the strength of a check that did not run."
  fi
  if (( bad )); then
    _rds_cleanup
    die "the restored database does not match the row counts captured with the dump.
       The live database was NOT touched — production is unchanged. Do not retry
       blindly; the dump or the container is suspect."
  fi
  ok "$checked table(s) verified against the backup"

  # Database-level state that pg_dump does NOT carry: per-database settings
  # (ALTER DATABASE … SET), the database ACL, connection limit and comment.
  _copy_database_level_state "$side"

  info "swapping databases"
  psql_maint -c "ALTER DATABASE \"$PG_DB\" RENAME TO \"$ASIDE_DB\"" >/dev/null \
    || { _rds_cleanup; die "could not rename the live database — nothing changed."; }

  if ! psql_maint -c "ALTER DATABASE \"$side\" RENAME TO \"$PG_DB\"" >/dev/null; then
    warn "second rename failed — putting the original database back"
    if psql_maint -c "ALTER DATABASE \"$ASIDE_DB\" RENAME TO \"$PG_DB\"" >/dev/null; then
      _rds_cleanup
      die "swap aborted — the production database is unchanged and back in place."
    fi
    # Do NOT reopen/cleanup here: the data is under $ASIDE_DB and must be left
    # exactly where it is for the human. Suppress the trap's tidying.
    _RDS_DONE=1; RDS_CRITICAL=1
    die "CRITICAL: no database named '$PG_DB' exists right now.
       YOUR DATA IS INTACT under '$ASIDE_DB'. Put it back by hand:
         docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres \\
           -c 'ALTER DATABASE \"$ASIDE_DB\" RENAME TO \"$PG_DB\"'
       Do NOT start the services until that succeeds."
  fi

  # The rename carried the ALLOW_CONNECTIONS=false with the old name; make sure
  # the database that is now live accepts connections again.
  psql_maint -c "ALTER DATABASE \"$PG_DB\" WITH ALLOW_CONNECTIONS true" >/dev/null || true
  psql_maint -c "ALTER DATABASE \"$ASIDE_DB\" WITH ALLOW_CONNECTIONS true" >/dev/null || true
  _RDS_LOCKED=0; _RDS_SIDE=""; _RDS_DONE=1
  trap - EXIT INT TERM

  ok "'$PG_DB' is now the restored copy; the pre-revert data is kept as '$ASIDE_DB'"
}

# ---------------------------------------------------------------------------
# Soft-mode telemetry carry-over.
#
# Two things go wrong here if you write the obvious pipeline:
#
#  1. `bash -c "pg_dump … | psql …"` has no pipefail, so only psql's status is
#     seen. A pg_dump that dies mid-stream after emitting a valid partial COPY
#     looks like success — and because soft mode deliberately exempts
#     telemetry_raw from row verification, the swap would then proceed with
#     production's telemetry silently truncated. That is the only path in this
#     tool that could destroy data while printing "ok". Hence -o pipefail AND an
#     explicit count check below.
#  2. telemetry_raw has a FK to vehicles(vin). The restored database's vehicles
#     is rewound, so telemetry belonging to a vehicle onboarded AFTER the backup
#     references a row that no longer exists and the copy dies on the
#     constraint. Those rows belong to a vehicle the revert is removing, so they
#     are filtered out — and reported, loudly, because "we dropped N rows" is
#     not something to discover later. They remain in the kept aside database.
# ---------------------------------------------------------------------------
_carry_over_telemetry() {  # $1 = side db
  local side="$1" live_total copied want got fk vins where=""

  sq()  { docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$side"   -tAc "$1" </dev/null 2>/dev/null; }
  lq()  { docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB"  -tAc "$1" </dev/null 2>/dev/null; }

  live_total="$(lq "select count(*) from public.telemetry_raw")"
  [[ -n "$live_total" ]] || { warn "could not count live telemetry_raw"; return 1; }

  # Does telemetry_raw reference vehicles? On prod it does
  # (telemetry_raw_vin_fkey ... REFERENCES vehicles(vin)), and the restored
  # database's vehicles list is rewound — so rows belonging to a vehicle
  # onboarded after the backup would violate the constraint and abort the copy.
  # Those rows belong to a vehicle this revert is removing; they are filtered
  # out and reported, and they remain in the kept pre-revert database.
  fk="$(sq "select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid
             where c.contype='f' and t.relname='telemetry_raw' limit 1")"
  if [[ "$fk" == "1" ]]; then
    vins="$(sq "select string_agg(quote_literal(vin), ',') from public.vehicles")"
    if [[ -z "$vins" ]]; then
      warn "the restored database has no vehicles — no telemetry can be carried over."
      return 1
    fi
    where="WHERE vin IN ($vins)"
  fi

  info "soft dump: copying live telemetry_raw into $side ($live_total rows — minutes, not seconds)"

  # bash -o pipefail is load-bearing: without it only psql's status is seen, so
  # a pg_dump/COPY that dies mid-stream after emitting a valid partial COPY
  # looks like success. Soft mode exempts telemetry_raw from the row
  # verification, so that would silently truncate production's telemetry at the
  # swap — the one path in this tool that could destroy data while printing ok.
  if ! docker exec -i "$PG_CONTAINER" bash -o pipefail -c \
      "psql -U '$PG_USER' -d '$PG_DB' -qtAX -c \
         \"COPY (SELECT * FROM public.telemetry_raw $where) TO STDOUT\" \
       | psql -U '$PG_USER' -d '$side' -v ON_ERROR_STOP=1 -q -c \
         'COPY public.telemetry_raw FROM STDIN'" </dev/null; then
    warn "telemetry carry-over failed — live database untouched, nothing lost."
    return 1
  fi

  # The explicit count that soft mode's verification exemption would skip.
  want="$(lq "select count(*) from public.telemetry_raw ${where}")"
  got="$(sq "select count(*) from public.telemetry_raw")"
  if [[ -z "$want" || -z "$got" || "$want" != "$got" ]]; then
    warn "telemetry carry-over is incomplete: copied ${got:-?} of ${want:-?} rows."
    return 1
  fi
  copied="$got"

  # Keep the sequence ahead of the carried-over ids.
  sq "select setval(pg_get_serial_sequence('public.telemetry_raw','id'),
                    greatest(coalesce((select max(id) from public.telemetry_raw),1),1))" >/dev/null

  ok "telemetry_raw carried over: $copied of $live_total live rows"
  if (( live_total > copied )); then
    warn "$(( live_total - copied )) telemetry row(s) were NOT carried over: they belong to
       vehicles that did not exist at backup time and that this revert removes.
       They remain in the kept pre-revert database ('$ASIDE_DB')."
  fi
  return 0
}

# Per-database settings, ACL, connection limit and comment are NOT in a
# pg_dump -Fc, so a database-swap loses them unless they are copied across.
# Today prod has none of these set; this exists so that stays true by accident
# no longer.
_copy_database_level_state() {  # $1 = side db
  local side="$1" n
  n="$(psql_maint -tAc \
    "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase
      where d.datname='$PG_DB'" </dev/null 2>/dev/null || echo 0)"
  if [[ "${n:-0}" != "0" ]]; then
    info "copying $n per-database setting(s) onto $side"
    local stmts
    stmts="$(psql_maint -tAc "
      select coalesce(string_agg(format('ALTER DATABASE %I %s SET %s;',
               '$side',
               case when s.setrole = 0 then '' else 'IN ROLE '||pg_get_userbyid(s.setrole) end,
               replace(cfg, '=', ' TO ')), ' '), '')
      from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase,
           unnest(s.setconfig) cfg
      where d.datname='$PG_DB'" </dev/null 2>/dev/null || echo '')"
    [[ -n "$stmts" ]] && psql_maint -c "$stmts" >/dev/null 2>&1 \
      || warn "could not copy per-database settings — check them by hand after the swap"
  fi

  local lim
  lim="$(psql_maint -tAc "select datconnlimit from pg_database where datname='$PG_DB'" </dev/null 2>/dev/null || echo -1)"
  [[ "${lim:--1}" != "-1" ]] && psql_maint -c "ALTER DATABASE \"$side\" CONNECTION LIMIT $lim" >/dev/null 2>&1 || true

  local acl
  acl="$(psql_maint -tAc "select coalesce(array_to_string(datacl,','),'') from pg_database where datname='$PG_DB'" </dev/null 2>/dev/null || echo '')"
  if [[ -n "$acl" ]]; then
    warn "database-level GRANTs exist on $PG_DB ($acl) and are not reproduced automatically.
       Re-apply them after the swap, or the roles they name lose their access."
  fi
  return 0
}
