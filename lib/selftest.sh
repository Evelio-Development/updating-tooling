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

# ------------------------------------------------------------------ done --
hdr "$( (( FAIL )) && echo "${C_RED}selftest: $FAIL failed, $PASS passed${C_OFF}" || echo "${C_GRN}selftest: all $PASS checks passed${C_OFF}")"
exit $(( FAIL > 0 ))
