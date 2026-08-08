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
    # Reopen whichever name the database is actually under right now. If we were
    # interrupted between the two renames, $PG_DB does not exist and the data is
    # under $ASIDE_DB — which carries the ALLOW_CONNECTIONS=false with it. Only
    # reopening $PG_DB would leave the surviving copy closed to every client.
    local d
    for d in "$PG_DB" "${ASIDE_DB:-}"; do
      [[ -n "$d" ]] || continue
      psql_maint -c "ALTER DATABASE \"$d\" WITH ALLOW_CONNECTIONS true" >/dev/null 2>&1 || true
    done
    _RDS_LOCKED=0
  fi
  if [[ -n "$_RDS_SIDE" ]]; then
    psql_maint -c "DROP DATABASE IF EXISTS \"$_RDS_SIDE\" WITH (FORCE)" >/dev/null 2>&1 || true
    _RDS_SIDE=""
  fi
}

# A signal during the (long) pre-swap phase: tidy the scratch database and exit
# 130, letting the CALLER's EXIT trap bring production's services back up.
_rds_on_signal() {
  INTERRUPTED=1
  trap '' INT TERM HUP
  _rds_cleanup
  exit 130
}

restore_db_swap() {   # $1 = dump file, $2 = rowcounts file, $3 = full|soft
  local dump="$1" pre="$2" mode="$3"
  local ts side
  ts="$(now_id)"
  side="evelio_restore_$ts"
  ASIDE_DB="evelio_prerevert_$ts"
  _RDS_SIDE="$side"; _RDS_LOCKED=0; _RDS_DONE=0
  # Signals only — this function must NOT install an EXIT trap. revert.sh's EXIT
  # trap (on_abort) is the ONLY thing that restarts the services and cron it
  # stopped; replacing it here meant every aborted restore (row-count mismatch,
  # unreadable dump, failed CREATE DATABASE) exited with production stopped and
  # nothing said so. revert.sh's on_abort calls _rds_cleanup itself.
  trap _rds_on_signal INT TERM HUP

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

  # Wait for the terminated backends to actually detach. ALTER DATABASE … RENAME
  # fails while any session is still attached, and a backend winding down a long
  # statement would otherwise turn into the abort below for no reason.
  local i drained=0
  for i in {1..30}; do
    [[ "$(psql_maint -tAc "select count(*) from pg_stat_activity
            where datname='$PG_DB' and pid <> pg_backend_pid()" </dev/null 2>/dev/null || echo 1)" == "0" ]] \
      && { drained=1; break; }
    sleep 1
  done
  (( drained )) || warn "sessions are still attached to '$PG_DB' after 30s — the rename may fail"

  # Signals are BLOCKED across the two renames: between them there is no database
  # named $PG_DB, and a handler that ran here would drop the verified copy and
  # leave production down. The breadcrumb is the only on-disk record of this
  # window, and the caller writes it before calling us.
  info "swapping databases"
  trap '' INT TERM HUP
  psql_maint -c "ALTER DATABASE \"$PG_DB\" RENAME TO \"$ASIDE_DB\"" >/dev/null \
    || { trap _rds_on_signal INT TERM HUP; _rds_cleanup
         die "could not rename the live database — nothing changed."; }

  if ! psql_maint -c "ALTER DATABASE \"$side\" RENAME TO \"$PG_DB\"" >/dev/null; then
    warn "second rename failed — putting the original database back"
    if psql_maint -c "ALTER DATABASE \"$ASIDE_DB\" RENAME TO \"$PG_DB\"" >/dev/null; then
      trap _rds_on_signal INT TERM HUP
      _rds_cleanup
      die "swap aborted — the production database is unchanged and back in place."
    fi
    # Do NOT reopen/cleanup here: the data is under $ASIDE_DB and must be left
    # exactly where it is for the human. Suppress the trap's tidying.
    _RDS_DONE=1; RDS_CRITICAL=1
    # The rename carried ALLOW_CONNECTIONS=false onto $ASIDE_DB, so renaming it
    # back is NOT enough — without the second statement the operator gets
    # "database is not currently accepting connections" and no hint why.
    die "CRITICAL: no database named '$PG_DB' exists right now.
       YOUR DATA IS INTACT under '$ASIDE_DB'. Put it back by hand — BOTH
       statements, the second one matters:
         docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres \\
           -c 'ALTER DATABASE \"$ASIDE_DB\" RENAME TO \"$PG_DB\"' \\
           -c 'ALTER DATABASE \"$PG_DB\" WITH ALLOW_CONNECTIONS true'
       Do NOT start the services until both succeed."
  fi

  # The rename carried the ALLOW_CONNECTIONS=false with the old name; make sure
  # the database that is now live accepts connections again. This is NOT optional
  # — swallowing a failure here means restart_all starts every service against a
  # database that refuses to talk to them, and the revert reports success.
  psql_maint -c "ALTER DATABASE \"$PG_DB\" WITH ALLOW_CONNECTIONS true" >/dev/null \
    || die "the swap completed but '$PG_DB' could not be reopened to connections.
       The restored data IS in place. Run this before starting anything:
         docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres \\
           -c 'ALTER DATABASE \"$PG_DB\" WITH ALLOW_CONNECTIONS true'"
  # The aside copy must be reachable too, or "undo this revert" cannot be used.
  psql_maint -c "ALTER DATABASE \"$ASIDE_DB\" WITH ALLOW_CONNECTIONS true" >/dev/null \
    || warn "could not reopen '$ASIDE_DB' to connections — do that before trying to undo this revert."
  _RDS_LOCKED=0; _RDS_SIDE=""; _RDS_DONE=1
  trap - INT TERM HUP

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
    # `vin IN (...)` is NULL — i.e. NOT selected — for a row with a NULL vin, and
    # telemetry_raw.vin is nullable (the FK permits it). Without the IS NULL arm
    # every NULL-vin row is dropped, and because the count check below uses this
    # same predicate it would agree with itself and report success: telemetry
    # destroyed while printing ok, in the one place row verification is exempt.
    where="WHERE vin IS NULL OR vin IN ($vins)"
  fi

  # Name the columns explicitly on BOTH sides. The source is the post-deploy live
  # table and the target is the pre-deploy restored one; a bare `SELECT *` / `COPY
  # FROM STDIN` pair matches by ordinal position, so a migration that RENAMED or
  # reordered two same-typed columns would load telemetry into the wrong columns,
  # silently — soft mode exempts this table from row verification. Using the
  # target's column list turns that into an honest error instead.
  local cols
  cols="$(sq "select string_agg(quote_ident(attname), ',' order by attnum)
              from pg_attribute
              where attrelid = 'public.telemetry_raw'::regclass
                and attnum > 0 and not attisdropped")"
  [[ -n "$cols" ]] || { warn "could not read telemetry_raw's columns in $side"; return 1; }
  local livecols
  livecols="$(lq "select string_agg(quote_ident(attname), ',' order by attnum)
                  from pg_attribute
                  where attrelid = 'public.telemetry_raw'::regclass
                    and attnum > 0 and not attisdropped")"
  if [[ "$cols" != "$livecols" ]]; then
    warn "telemetry_raw's columns differ between the live and restored databases:
       live    : ${livecols:-?}
       restored: $cols
       A soft revert cannot carry telemetry across a change to this table. Re-run
       with --code-only, or restore the full dump."
    return 1
  fi

  info "soft dump: copying live telemetry_raw into $side ($live_total rows — minutes, not seconds)"

  # bash -o pipefail is load-bearing: without it only psql's status is seen, so
  # a pg_dump/COPY that dies mid-stream after emitting a valid partial COPY
  # looks like success. Soft mode exempts telemetry_raw from the row
  # verification, so that would silently truncate production's telemetry at the
  # swap — the one path in this tool that could destroy data while printing ok.
  if ! docker exec -i "$PG_CONTAINER" bash -o pipefail -c \
      "psql -U '$PG_USER' -d '$PG_DB' -qtAX -c \
         \"COPY (SELECT $cols FROM public.telemetry_raw $where) TO STDOUT\" \
       | psql -U '$PG_USER' -d '$side' -v ON_ERROR_STOP=1 -q -c \
         'COPY public.telemetry_raw ($cols) FROM STDIN'" </dev/null; then
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

# Per-database settings, ACL and connection limit are NOT in a pg_dump -Fc, so a
# database-swap loses them unless they are copied across. (Database-level GRANTs
# are reported, not reproduced — see the warning at the end.)
# Today prod has none of these set; this exists so that stays true by accident
# no longer.
_copy_database_level_state() {  # $1 = side db
  local side="$1" n
  n="$(psql_maint -tAc \
    "select count(*) from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase
      where d.datname='$PG_DB'" </dev/null 2>/dev/null || echo 0)"
  if [[ "${n:-0}" != "0" ]]; then
    info "copying $n per-database setting(s) onto $side"
    # Three things the obvious one-liner gets wrong, all of which end as a single
    # swallowed `warn` on a stressful revert:
    #   * `ALTER DATABASE db IN ROLE r SET …` is not valid SQL. Role-scoped
    #     settings need `ALTER ROLE r IN DATABASE db SET …`.
    #   * replace(cfg,'=',' TO ') neither quotes the value nor stops at the first
    #     `=`, so statement_timeout=30s becomes a syntax error.
    #   * one -c is one implicit transaction, so a single bad statement discards
    #     the good ones too. Run them one at a time.
    local stmts failed=0 s
    stmts="$(psql_maint -tAc "
      select string_agg(
        case when s.setrole = 0
             then format('ALTER DATABASE %I SET %I TO %L',
                         '$side', split_part(cfg,'=',1),
                         substr(cfg, strpos(cfg,'=')+1))
             else format('ALTER ROLE %I IN DATABASE %I SET %I TO %L',
                         pg_get_userbyid(s.setrole), '$side', split_part(cfg,'=',1),
                         substr(cfg, strpos(cfg,'=')+1))
        end, E'\n')
      from pg_db_role_setting s join pg_database d on d.oid=s.setdatabase,
           unnest(s.setconfig) cfg
      where d.datname='$PG_DB'" </dev/null 2>/dev/null || echo '')"
    if [[ -n "$stmts" ]]; then
      while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        psql_maint -c "$s" >/dev/null 2>&1 || { warn "  failed: $s"; failed=1; }
      done <<<"$stmts"
      (( failed )) && warn "some per-database settings were NOT copied onto the restored
       database (listed above) — re-apply them by hand after the swap."
    else
      warn "there are $n per-database setting(s) on $PG_DB but none could be read —
       check them by hand after the swap."
    fi
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
