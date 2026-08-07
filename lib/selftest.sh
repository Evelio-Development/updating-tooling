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
  capture_rowcounts "$WORK/rowcounts.pre"
  docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc -Z1 -f /tmp/st.dump
  docker cp "$PG_CONTAINER":/tmp/st.dump "$WORK/db.dump" >/dev/null
  docker exec "$PG_CONTAINER" rm -f /tmp/st.dump
}

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
sed -i 's/^users|10/users|999/' "$WORK/rowcounts.pre"
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

# ------------------------------------------------------------------ done --
hdr "$( (( FAIL )) && echo "${C_RED}selftest: $FAIL failed, $PASS passed${C_OFF}" || echo "${C_GRN}selftest: all $PASS checks passed${C_OFF}")"
exit $(( FAIL > 0 ))
