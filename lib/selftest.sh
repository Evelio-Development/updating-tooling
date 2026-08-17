#!/usr/bin/env bash
#
# selftest.sh — rehearse the revert machinery against the STAGING Postgres.
#
# It exercises the real restore_db_swap() from lib/db-restore.sh (the same code
# revert.sh runs) on a throwaway database, and asserts the properties that make
# a revert safe:
#
#   1. a good dump restores and swaps, and the data is exactly the backup's
#   2. the pre-revert data is KEPT, not destroyed
#   3. a row-count mismatch ABORTS and leaves the live database untouched
#   4. a corrupt dump ABORTS and leaves the live database untouched
#
# It never touches production: it runs entirely inside
# telemetry-postgres-staging on databases named selftest_*.
#
#   sudo lib/selftest.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PG_CONTAINER=telemetry-postgres-staging
export PG_DB=selftest_live
export PG_USER=evelio
# shellcheck source=./common.sh
source "$HERE/lib/common.sh"
# shellcheck source=./db-restore.sh
source "$HERE/lib/db-restore.sh"
# common.sh sets -e; the whole point of this harness is to run things that fail.
set +e

WORK="$(mktemp -d)"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then ok "$1"; (( ++PASS )); else warn "$1  (got '$2', want '$3')"; (( ++FAIL )); fi; }

cleanup() {
  for d in $(psql_maint -tAc "select datname from pg_database where datname like 'selftest%' or datname like 'evelio_prerevert_%' or datname like 'evelio_restore_%'" 2>/dev/null); do
    psql_maint -c "DROP DATABASE IF EXISTS \"$d\" WITH (FORCE)" >/dev/null 2>&1
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

q() { psql_prod -tAc "$1"; }

fresh_live() {
  psql_maint -c "DROP DATABASE IF EXISTS \"$PG_DB\" WITH (FORCE)" >/dev/null 2>&1
  psql_maint -c "CREATE DATABASE \"$PG_DB\" OWNER $PG_USER" >/dev/null
  psql_prod -q <<'SQL'
CREATE TABLE users (id serial primary key, email text, note text);
CREATE TABLE telemetry_raw (id serial primary key, payload text);
INSERT INTO users (email, note) SELECT 'u'||i||'@x', 'original' FROM generate_series(1,10) i;
INSERT INTO telemetry_raw (payload) SELECT 'row'||i FROM generate_series(1,100) i;
SQL
}

take_backup() {   # -> $WORK/db.dump, $WORK/rowcounts.pre
  dump_and_count_consistently "$WORK/db.dump" "$WORK/rowcounts.pre" full >/dev/null 2>&1
}

# A writer that keeps inserting while the backup is taken — production is never
# idle, and the counts/dump must still agree. Case 5 exists because the original
# implementation counted BEFORE dumping and every real revert would have aborted.
start_writer() {
  ( while :; do
      docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -qtAX -c \
        "INSERT INTO telemetry_raw (payload) VALUES ('bg')" </dev/null >/dev/null 2>&1
      sleep 0.05
    done ) &
  WRITER_PID=$!
}
stop_writer() { [[ -n "${WRITER_PID:-}" ]] && kill "$WRITER_PID" 2>/dev/null; wait "$WRITER_PID" 2>/dev/null; WRITER_PID=""; }

hdr "selftest: revert machinery (container=$PG_CONTAINER, db=$PG_DB)"
docker inspect "$PG_CONTAINER" >/dev/null 2>&1 || die "staging container not running"

# ---------------------------------------------------------------- case 1 --
hdr "1. happy path: restore + swap"
fresh_live
take_backup
# production moves on: a new user signs up, telemetry keeps arriving, a row is edited
psql_prod -q -c "INSERT INTO users (email,note) VALUES ('late@x','after-backup')"
psql_prod -q -c "UPDATE users SET note='edited' WHERE id=1"
psql_prod -q -c "INSERT INTO telemetry_raw (payload) SELECT 'new'||i FROM generate_series(1,50) i"
check "pre-revert live has 11 users"  "$(q 'select count(*) from users')" "11"

restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" full >/dev/null 2>&1 \
  && ok "restore_db_swap succeeded" || { warn "restore_db_swap FAILED"; (( ++FAIL )); }

check "live rolled back to 10 users"          "$(q 'select count(*) from users')" "10"
check "edited row is back to 'original'"      "$(q "select note from users where id=1")" "original"
check "telemetry rewound to 100 rows"         "$(q 'select count(*) from telemetry_raw')" "100"
check "aside copy exists"                     "$(db_exists "$ASIDE_DB" && echo yes || echo no)" "yes"
check "aside copy still holds the 11th user"  \
  "$(docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$ASIDE_DB" -tAc "select count(*) from users")" "11"
check "no stray evelio_restore_* left behind" \
  "$(psql_maint -tAc "select count(*) from pg_database where datname like 'evelio_restore_%'")" "0"

# ---------------------------------------------------------------- case 2 --
hdr "2. row-count mismatch must abort without touching the live database"
fresh_live
take_backup
# corrupt the EXPECTATION, so the verified restore cannot match it
sed -i 's/^public\.users|10/public.users|999/' "$WORK/rowcounts.pre"
psql_prod -q -c "INSERT INTO users (email,note) VALUES ('keepme@x','must-survive')"
before="$(q 'select count(*) from users')"
# subshell: die() exits, and here that must fail the CASE, not the harness
( restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" full ) >/dev/null 2>&1
rc=$?
check "aborted with non-zero exit"        "$(( rc != 0 ))" "1"
check "live database untouched"           "$(q 'select count(*) from users')" "$before"
check "the extra user still exists"       "$(q "select count(*) from users where email='keepme@x'")" "1"
check "side database cleaned up"          "$(psql_maint -tAc "select count(*) from pg_database where datname like 'evelio_restore_%'")" "0"

# ---------------------------------------------------------------- case 3 --
hdr "3. corrupt dump must abort without touching the live database"
fresh_live
take_backup
# truncate the dump: a genuinely unusable backup, the case that matters
truncate -s "$(( $(stat -c%s "$WORK/db.dump") * 2 / 5 ))" "$WORK/db.dump"
psql_prod -q -c "INSERT INTO users (email,note) VALUES ('keepme3@x','must-survive')"
before="$(q 'select count(*) from users')"
# subshell: die() exits, and here that must fail the CASE, not the harness
( restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" full ) >/dev/null 2>&1
rc=$?
check "aborted with non-zero exit"        "$(( rc != 0 ))" "1"
check "live database untouched"           "$(q 'select count(*) from users')" "$before"
check "the extra user still exists"       "$(q "select count(*) from users where email='keepme3@x'")" "1"
check "side database cleaned up"          "$(psql_maint -tAc "select count(*) from pg_database where datname like 'evelio_restore_%'")" "0"

# ---------------------------------------------------------------- case 4 --
hdr "4. soft dump: telemetry must SURVIVE the revert"
fresh_live
capture_rowcounts "$WORK/rowcounts.pre"
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc -Z1 \
  --exclude-table-data=public.telemetry_raw -f /tmp/st.dump
docker cp "$PG_CONTAINER":/tmp/st.dump "$WORK/db.dump" >/dev/null
docker exec "$PG_CONTAINER" rm -f /tmp/st.dump
psql_prod -q -c "INSERT INTO users (email,note) VALUES ('late@x','after-backup')"
psql_prod -q -c "INSERT INTO telemetry_raw (payload) SELECT 'new'||i FROM generate_series(1,50) i"

restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" soft >/dev/null 2>&1 \
  && ok "soft restore_db_swap succeeded" || { warn "soft restore FAILED"; (( ++FAIL )); }
check "users rolled back to 10"                 "$(q 'select count(*) from users')" "10"
check "telemetry PRESERVED (150, not 100)"      "$(q 'select count(*) from telemetry_raw')" "150"

# ---------------------------------------------------------------- case 5 --
hdr "5. writes DURING the backup must not break the restore"
fresh_live
start_writer
sleep 1
take_backup            # counts + dump must describe one instant despite the writer
sleep 1
stop_writer
n_at_backup="$(awk -F'|' '$1=="public.telemetry_raw"{print $2}' "$WORK/rowcounts.pre")"
n_now="$(q 'select count(*) from telemetry_raw')"
check "the writer really was writing"  "$(( n_now > n_at_backup ))" "1"
restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" full >/dev/null 2>&1 \
  && ok "restore succeeded despite concurrent writes" || { warn "restore FAILED (the count/dump skew bug)"; (( ++FAIL )); }
check "restored to the backup instant" "$(q 'select count(*) from telemetry_raw')" "$n_at_backup"

# ---------------------------------------------------------------- case 6 --
hdr "6. a second schema is verified too, not silently ignored"
fresh_live
psql_prod -q -c "CREATE SCHEMA health; CREATE TABLE health.anchors(id int); INSERT INTO health.anchors SELECT generate_series(1,7);"
take_backup
check "the extra schema is in the counts" \
  "$(awk -F'|' '$1=="health.anchors"{print $2}' "$WORK/rowcounts.pre")" "7"
psql_prod -q -c "INSERT INTO health.anchors VALUES (99)"
restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" full >/dev/null 2>&1 \
  && ok "restore succeeded" || { warn "restore FAILED"; (( ++FAIL )); }
check "health.anchors rewound"  "$(q 'select count(*) from health.anchors')" "7"

# ---------------------------------------------------------------- case 7 --
hdr "7. empty row counts must refuse to swap (never verify nothing)"
fresh_live
take_backup
: > "$WORK/rowcounts.pre"
before="$(q 'select count(*) from users')"
( restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" full ) >/dev/null 2>&1
rc=$?
check "aborted with non-zero exit"  "$(( rc != 0 ))" "1"
check "live database untouched"     "$(q 'select count(*) from users')" "$before"

# ---------------------------------------------------------------- case 8 --
hdr "8. soft mode: telemetry for a vehicle removed by the revert"
fresh_live
psql_prod -q -c "CREATE TABLE vehicles(vin text primary key)"
psql_prod -q -c "INSERT INTO vehicles VALUES ('VIN1')"
psql_prod -q -c "ALTER TABLE telemetry_raw ADD COLUMN vin text REFERENCES vehicles(vin)"
psql_prod -q -c "UPDATE telemetry_raw SET vin='VIN1'"
dump_and_count_consistently "$WORK/db.dump" "$WORK/rowcounts.pre" soft >/dev/null 2>&1
# a vehicle onboarded AFTER the backup, with telemetry of its own
psql_prod -q -c "INSERT INTO vehicles VALUES ('VIN2')"
psql_prod -q -c "INSERT INTO telemetry_raw (payload, vin) SELECT 'new'||i,'VIN2' FROM generate_series(1,5) i"
psql_prod -q -c "INSERT INTO telemetry_raw (payload, vin) SELECT 'more'||i,'VIN1' FROM generate_series(1,5) i"
restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" soft >/dev/null 2>&1 \
  && ok "soft restore succeeded across a foreign key" || { warn "soft restore FAILED"; (( ++FAIL )); }
check "VIN1 telemetry all carried over (105)"  "$(q "select count(*) from telemetry_raw where vin='VIN1'")" "105"
check "VIN2 telemetry not resurrected"         "$(q "select count(*) from telemetry_raw where vin='VIN2'")" "0"
check "VIN2 vehicle removed by the revert"     "$(q "select count(*) from vehicles where vin='VIN2'")" "0"

# ---------------------------------------------------------------- case 9 --
# NULL-vin telemetry. `vin IN (...)` is NULL — i.e. not selected — for a NULL vin,
# and soft mode exempts telemetry_raw from row verification, so dropping these rows
# used to be completely silent: the carry-over's own count check used the same
# predicate and therefore agreed with itself. Case 8 sets vin on every row, so it
# cannot catch this.
hdr "9. soft mode: telemetry with a NULL vin must survive"
fresh_live
psql_prod -q -c "CREATE TABLE vehicles(vin text primary key)"
psql_prod -q -c "INSERT INTO vehicles VALUES ('VIN1')"
psql_prod -q -c "ALTER TABLE telemetry_raw ADD COLUMN vin text REFERENCES vehicles(vin)"
psql_prod -q -c "UPDATE telemetry_raw SET vin='VIN1'"
dump_and_count_consistently "$WORK/db.dump" "$WORK/rowcounts.pre" soft >/dev/null 2>&1
# rows that belong to no vehicle at all — legal, because the FK column is nullable
psql_prod -q -c "INSERT INTO telemetry_raw (payload, vin) SELECT 'orphan'||i, NULL FROM generate_series(1,7) i"
nullbefore="$(q "select count(*) from telemetry_raw where vin is null")"
check "live has 7 NULL-vin rows before the revert" "$nullbefore" "7"
restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" soft >/dev/null 2>&1 \
  && ok "soft restore succeeded with NULL-vin rows" || { warn "soft restore FAILED"; (( ++FAIL )); }
check "NULL-vin telemetry carried over, not dropped" \
  "$(q "select count(*) from telemetry_raw where vin is null")" "7"

# --------------------------------------------------------------- case 10 --
# The library must not install an EXIT trap: revert.sh's EXIT trap is the only
# thing that restarts the services and cron it stopped, and displacing it meant
# every aborted restore left production down with nothing saying so.
hdr "10. an aborted restore must leave the CALLER's EXIT trap intact"
fresh_live
take_backup
sed -i 's/^public\.users|10/public.users|999/' "$WORK/rowcounts.pre"
trap_marker="$WORK/caller-exit-trap-ran"
rm -f "$trap_marker"
(
  trap 'printf ran > "$trap_marker"' EXIT
  restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" full
) >/dev/null 2>&1
check "caller's EXIT trap still ran after the abort" \
  "$([[ -f "$trap_marker" ]] && echo yes || echo no)" "yes"
rm -f "$trap_marker"

# --------------------------------------------------------------- case 11 --
# The swap closes the live database to connections; both renames carry that
# property. If it is not reopened, every service fails to connect and the revert
# still reports success.
hdr "11. both databases accept connections again after a successful swap"
fresh_live
take_backup
restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.pre" full >/dev/null 2>&1 \
  && ok "restore_db_swap succeeded" || { warn "restore_db_swap FAILED"; (( ++FAIL )); }
check "live database accepts connections" \
  "$(psql_maint -tAc "select datallowconn from pg_database where datname='$PG_DB'")" "t"
check "aside database accepts connections" \
  "$(psql_maint -tAc "select datallowconn from pg_database where datname='$ASIDE_DB'")" "t"

# --------------------------------------------------------------- case 12 --
# rowcounts.pre must never be stored containing psql error text: stderr is merged
# into the counting stream, so a failed count used to land "ERROR: ..." in the file,
# pass the -s check, and produce a backup that every revert refuses.
hdr "12. a malformed row-count file must be rejected, not stored"
fresh_live
printf 'ERROR:  permission denied for table users\n' > "$WORK/rowcounts.bad"
( restore_db_swap "$WORK/db.dump" "$WORK/rowcounts.bad" full ) >/dev/null 2>&1
rc=$?
check "restore refused a malformed row-count file" "$(( rc != 0 ))" "1"
check "no side database left behind" \
  "$(psql_maint -tAc "select count(*) from pg_database where datname like 'evelio_restore_%'")" "0"

# --------------------------------------------------------------- case 13 --
# The breadcrumb blocks every later run until a human clears it, which is right
# when production's data might be under another name and pure noise otherwise.
# revert.sh writes it BEFORE the restore starts, but almost every abort happens in
# the long pre-swap phase (pg_restore, verification, telemetry carry-over) where
# production is provably untouched — so leaving it behind turned the EXPECTED
# failure path into "an earlier database swap did not finish", pointing the
# operator at evelio_prerevert_* databases that were never created. An operator who
# learns to delete that file reflexively will also delete it in the one case it
# exists for. restore_db_swap therefore publishes RDS_DB_STATE, and this asserts
# the two transitions revert.sh's on_abort keys on.
hdr "13. an abort BEFORE the swap must not leave a swap-in-progress breadcrumb"
BREADCRUMB="$WORK/.swap-in-progress"

# Exactly what revert.sh does: breadcrumb, restore, and on abort clear it only if
# the library says the data's location is known.
run_like_revert() {   # $1 = rowcounts file ; echoes the resulting RDS_DB_STATE
  breadcrumb_write <<<"a swap was in progress"
  (
    trap 'printf "%s" "${RDS_DB_STATE:-unset}" > "$WORK/state"
          [[ "${RDS_DB_STATE:-safe}" == "safe" ]] && breadcrumb_clear' EXIT
    restore_db_swap "$WORK/db.dump" "$1" full
  ) >/dev/null 2>&1
  cat "$WORK/state"
}

fresh_live
take_backup
cp "$WORK/rowcounts.pre" "$WORK/rowcounts.bad13"
sed -i 's/^public\.users|10/public.users|999/' "$WORK/rowcounts.bad13"
before="$(q 'select count(*) from users')"
state="$(run_like_revert "$WORK/rowcounts.bad13")"
check "row-count abort reports the data as located"  "$state" "safe"
check "no stale breadcrumb after a pre-swap abort" \
  "$([[ -f "$BREADCRUMB" ]] && echo present || echo gone)" "gone"
check "live database still untouched"                "$(q 'select count(*) from users')" "$before"

# A corrupt dump aborts even earlier — before the side database is even created.
fresh_live
take_backup
truncate -s "$(( $(stat -c%s "$WORK/db.dump") * 2 / 5 ))" "$WORK/db.dump"
state="$(run_like_revert "$WORK/rowcounts.pre")"
check "corrupt-dump abort reports the data as located" "$state" "safe"
check "no stale breadcrumb after a corrupt-dump abort" \
  "$([[ -f "$BREADCRUMB" ]] && echo present || echo gone)" "gone"

# And a SUCCESSFUL swap must end in the same state, or revert.sh would keep a
# breadcrumb on the happy path and block the next run.
fresh_live
take_backup
state="$(run_like_revert "$WORK/rowcounts.pre")"
check "successful swap reports the data as located"  "$state" "safe"
check "no breadcrumb after a successful swap" \
  "$([[ -f "$BREADCRUMB" ]] && echo present || echo gone)" "gone"
BREADCRUMB="$UPD_ROOT/.swap-in-progress"

# The three checks above prove the LIBRARY publishes the right state; they cannot
# prove revert.sh still acts on it, because run_like_revert re-implements the rule
# (driving the real on_abort would need the full prod layout and live services).
# So assert the wiring is present. Structural, but the alternative is a contract
# with a verified producer and an unverified consumer.
check "revert.sh's on_abort still keys the breadcrumb on RDS_DB_STATE" \
  "$(awk '/^on_abort\(\)/,/^}/' "$HERE/bin/revert.sh" \
     | grep -qE 'RDS_DB_STATE' && grep -qE 'breadcrumb_clear' <(awk '/^on_abort\(\)/,/^}/' "$HERE/bin/revert.sh") \
     && echo wired || echo MISSING)" "wired"

# ------------------------------------------------------------------ done --
hdr "$( (( FAIL )) && echo "${C_RED}selftest: $FAIL failed, $PASS passed${C_OFF}" || echo "${C_GRN}selftest: all $PASS checks passed${C_OFF}")"
exit $(( FAIL > 0 ))
