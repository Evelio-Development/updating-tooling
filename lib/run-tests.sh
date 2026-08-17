#!/usr/bin/env bash
#
# run-tests.sh <repo-dir> — run the app's test suite as a pre-deploy gate.
#
# Two things matter here, and both are safety, not convenience:
#
#  1. The tests run against a THROWAWAY database inside the *staging* Postgres
#     container (:5433), never prod.
#  2. Several app modules default to PG_PORT=5432 / PG_DB=evelio (i.e. PROD)
#     when their vars are unset. So the test venv gets a `.pth` guard that wraps
#     psycopg2.connect and refuses port 5432, the shared `evelio` database, and
#     any non-local host — the same control the staging tooling installs. Env
#     vars alone are not a boundary; a module that ignores them would reach prod.
#
set -euo pipefail
# Exit codes: 0 = all passed, 1 = some test files failed, 2 = could not run at
# all. update.sh MUST distinguish 1 from 2 — treating an infrastructure failure
# as "zero tests failed" would silently blank the regression baseline.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./common.sh
source "$HERE/lib/common.sh"

# Infrastructure failure = exit 2 (see the header). Overrides common.sh's die.
die() { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 2; }

REPO="${1:?usage: run-tests.sh <repo-dir>}"
[[ -d "$REPO" ]] || die "no such repo dir: $REPO"

# update.sh tightens $LOG_DIR at backup time, but this runs BEFORE that on the
# very first deploy, and pytest output can carry fixture data. Own the mode here
# rather than inheriting whatever umask the operator's shell had.
mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR" 2>/dev/null || true

docker inspect "$STAGING_PG_CONTAINER" >/dev/null 2>&1 \
  || die "staging postgres container '$STAGING_PG_CONTAINER' not found.
       The test gate refuses to fall back to the prod container. Start staging and
       re-run — there is no bypass (--skip-tests was removed on purpose)."

export TESTDB="evelio_pretest_$(date -u +%Y%m%d%H%M%S)"
spg() { docker exec -i "$STAGING_PG_CONTAINER" psql -U evelio -d "${1:-postgres}" -v ON_ERROR_STOP=1 "${@:2}"; }

cleanup() {
  docker exec -i "$STAGING_PG_CONTAINER" psql -U evelio -d postgres \
    -c "DROP DATABASE IF EXISTS \"$TESTDB\" WITH (FORCE)" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "creating throwaway test db $TESTDB in $STAGING_PG_CONTAINER"
spg postgres -c "CREATE DATABASE \"$TESTDB\" OWNER evelio" >/dev/null

# Schema for the tests = the branch's own migrations, replayed in the SAME order
# production gets them (add-order, not alphabetical — see migration_files()).
#
# This is BEST-EFFORT on purpose, and must not be fatal. The app repo's
# migrations are not self-contained: nothing in migrate_*.sql creates the `users`
# table (it exists only in production, predating them), so migrate_fleets.sql
# cannot apply to an empty database in ANY order. Making a failed replay exit 2
# therefore blocks every deploy forever, on a requirement that cannot be met — and
# the tests do not actually need it: the files that touch the database build their
# own schema.
#
# The original worry — that an incomplete schema makes tests die in collection and
# get blamed on the app repo — is real, but it is handled properly further down:
# a collection error is a pytest exit 2, which the classifier reports as DID NOT
# RUN and turns into this script's exit 2. So the infrastructure/test distinction
# is preserved without a gate nobody can pass.
mapfile -t MIGRATIONS < <(migration_files "$REPO")
mig_failed=()
if (( ${#MIGRATIONS[@]} )); then
  for m in "${MIGRATIONS[@]}"; do
    [[ -f "$REPO/$m" ]] || continue
    merr="$(spg "$TESTDB" < "$REPO/$m" 2>&1 >/dev/null)" \
      || mig_failed+=("$m: $(printf '%s' "${merr:-(no output)}" | grep -m1 -oE 'ERROR:.*' || printf 'failed')")
  done
  if (( ${#mig_failed[@]} )); then
    warn "${#mig_failed[@]} of ${#MIGRATIONS[@]} migration(s) did not apply to $TESTDB:"
    printf '       %s\n' "${mig_failed[@]}" >&2
    log "  The test schema is therefore partial. This is NOT counted as a test"
    log "  failure: the app repo's migrations are not self-contained (no migrate_*.sql"
    log "  creates 'users'), and the database-touching tests build their own schema."
    log "  If a test file dies in collection because of this, it is reported as"
    log "  DID NOT RUN and exits 2 — infrastructure, not a regression."
  else
    ok "${#MIGRATIONS[@]} migration(s) applied to $TESTDB in add-order"
  fi
fi

# ------------------------------------------------------------- test venv --
PROD_SITE="$(ls -d "$BACKEND_DIR"/.venv/lib/python*/site-packages 2>/dev/null | head -1)"
[[ -n "$PROD_SITE" ]] || die "cannot locate the prod venv's site-packages under $BACKEND_DIR/.venv"

if [[ ! -x "$TESTVENV/bin/python" ]]; then
  info "creating test venv"
  python3 -m venv "$TESTVENV" || die "could not create the test venv"
fi

SITE="$(ls -d "$TESTVENV"/lib/python*/site-packages 2>/dev/null | head -1)"
[[ -n "$SITE" ]] || die "test venv has no site-packages"

# Reuse the prod venv's libraries (fastapi, psycopg2, …) READ-ONLY by putting its
# site-packages on the path. A venv created *from* the prod venv would not
# inherit them (--system-site-packages means the *system* interpreter's), and
# pip-installing into the prod venv is not something a deploy tool may do.
# Sorts before the guard below, which needs psycopg2 importable.
printf '%s\n' "$PROD_SITE" > "$SITE/za-prod-site.pth"

# ---------------------------------------------------------------------------
# Prod-connection guard.
#
# TWO mistakes are easy here and both make the guard silently inert:
#   * a venv-local sitecustomize.py is shadowed by Debian's
#     /usr/lib/python3/dist-packages/sitecustomize.py, and
#   * a .pth file is processed LINE BY LINE and only lines starting with
#     `import` are executed — a multi-line program in a .pth does nothing at
#     all, with no error. (An earlier version of this file made exactly that
#     mistake; the guard it advertised never ran.)
# So: a real module, plus a one-line import-only .pth. Verified below.
# ---------------------------------------------------------------------------
cat > "$SITE/evelio_prod_guard.py" <<'PYGUARD'
"""Refuse, at connect time, any psycopg2 connection that points at production.

Installed into the pre-deploy test venv. Several app modules default to
PG_PORT=5432 / PG_DB=evelio (PROD) when their vars are unset, so environment
variables alone are not a boundary.
"""
import os
import sys

_LOCAL = ("localhost", "127.0.0.1", "::1", "")


def _install():
    try:
        import psycopg2
    except Exception:
        return
    if getattr(psycopg2.connect, "_evelio_guarded", False):
        return
    _real = psycopg2.connect

    def _check(args, kwargs):
        port = str(kwargs.get("port") or os.environ.get("PG_PORT") or "5432")
        db = (kwargs.get("dbname") or kwargs.get("database")
              or os.environ.get("PG_DB") or "evelio")
        host = str(kwargs.get("host") or os.environ.get("PG_HOST") or "localhost")
        # A connection string must be PARSED, not substring-matched.
        # `psycopg2.connect("postgresql://evelio:pw@db.internal/evelio")` contains
        # no "5432" (the port is implicit) and no "dbname=", so the old check let
        # it through and then fell back to the *test* env values — which pass.
        # Parse both the URI and keyword/value forms, and fail closed.
        #
        # It must be taken from the KEYWORD form as well as the positional one.
        # psycopg2's signature is connect(dsn=None, connection_factory=None, ...),
        # so `connect(dsn="host=... port=5432 dbname=evelio")` put the string in
        # kwargs, left dsn empty here, and fell back to the test env values — which
        # pass. That reached the production socket; only a wrong password stopped
        # it. Same class as the URI hole, one call-form over.
        dsn = ""
        if args and isinstance(args[0], str):
            dsn = args[0]
        elif isinstance(kwargs.get("dsn"), str):
            dsn = kwargs["dsn"]
        if dsn:
            try:
                if dsn.startswith(("postgres://", "postgresql://")):
                    from urllib.parse import urlparse
                    u = urlparse(dsn)
                    host = str(u.hostname or "")
                    port = str(u.port or 5432)
                    db = (u.path or "/").lstrip("/") or db
                else:
                    kv = dict(p.split("=", 1) for p in dsn.split() if "=" in p)
                    host = str(kv.get("host", host))
                    port = str(kv.get("port", port))
                    db = kv.get("dbname", kv.get("database", db))
            except Exception:
                sys.stderr.write(
                    "\n*** BLOCKED: could not parse the connection string, so it "
                    "cannot be proven non-prod.\n\n")
                raise SystemExit(3)
        if port == "5432" or db == "evelio" or host not in _LOCAL:
            sys.stderr.write(
                "\n*** BLOCKED: the pre-deploy test suite tried to connect to "
                "port=%s db=%s host=%s.\n*** That is the PRODUCTION database. "
                "Tests never talk to prod.\n\n" % (port, db, host))
            raise SystemExit(3)

    def connect(*args, **kwargs):
        _check(args, kwargs)
        return _real(*args, **kwargs)

    connect._evelio_guarded = True
    psycopg2.connect = connect

    # psycopg2.extensions.connection is the underlying class and accepts the same
    # DSN directly, so `extensions.connection("host=... port=5432 dbname=evelio")`
    # bypassed a guard that only wrapped the module-level connect().
    try:
        import psycopg2.extensions as _ext
        _real_conn = _ext.connection
        if not getattr(_real_conn, "_evelio_guarded", False):
            class _GuardedConnection(_real_conn):
                _evelio_guarded = True

                def __init__(self, *args, **kwargs):
                    _check(args, kwargs)
                    super().__init__(*args, **kwargs)

            _ext.connection = _GuardedConnection
    except Exception:
        pass


_install()
PYGUARD

# One line, starting with `import` — the only form a .pth actually executes.
printf 'import evelio_prod_guard\n' > "$SITE/zz-evelio-prod-guard.pth"

"$TESTVENV/bin/python" -c 'import pytest' 2>/dev/null \
  || { info "installing pytest into the test venv"; "$TESTVENV/bin/pip" install -q pytest || die "could not install pytest"; }

# Prove the guard is live. A guard nobody verifies is a comment, not a control:
# this exact assertion is what would have caught the inert-.pth bug.
guard_rc=0
"$TESTVENV/bin/python" -c \
  'import psycopg2; psycopg2.connect(host="127.0.0.1", port=5432, dbname="evelio", user="x")' \
  >/dev/null 2>&1 || guard_rc=$?
# Exit 3 is the guard refusing. Anything else (0 = it connected, 1 = it merely
# failed to connect, 2 = import error) means the guard is not doing its job.
if [[ "$guard_rc" != "3" ]]; then
  die "the prod-connection guard is NOT active in $TESTVENV (got exit $guard_rc, want 3).
       A connection to port 5432 / db evelio must be refused by the guard, not
       merely fail. Refusing to run the test suite without it — several app
       modules default to prod when PG_* is unset."
fi
# The kwargs assertion above cannot detect a guard that is blind to connection
# STRINGS, which is how a URI-form connect to prod slipped past. Assert that form
# too — a remote host on the implicit port, which names nothing the substring
# check would have matched.
guard_rc=0
PG_HOST=127.0.0.1 PG_PORT=5433 PG_DB=notprod \
"$TESTVENV/bin/python" -c \
  'import psycopg2; psycopg2.connect("postgresql://evelio:pw@db.internal/evelio")' \
  >/dev/null 2>&1 || guard_rc=$?
if [[ "$guard_rc" != "3" ]]; then
  die "the prod-connection guard does not inspect connection STRINGS (got exit
       $guard_rc, want 3). A URI naming a non-local host must be refused by the
       guard, not merely fail to connect."
fi
# The two assertions above could not see a guard that reads the DSN only when it
# arrives POSITIONALLY — and `connect(dsn=...)` is a perfectly ordinary call that
# reached the production socket. Assert the keyword form explicitly, and the
# underlying extensions.connection class, which takes the same string directly.
guard_rc=0
PG_HOST=127.0.0.1 PG_PORT=5433 PG_DB=notprod \
"$TESTVENV/bin/python" -c \
  'import psycopg2; psycopg2.connect(dsn="host=127.0.0.1 port=5432 dbname=evelio user=evelio")' \
  >/dev/null 2>&1 || guard_rc=$?
if [[ "$guard_rc" != "3" ]]; then
  die "the prod-connection guard misses the dsn= KEYWORD form (got exit $guard_rc,
       want 3). psycopg2.connect(dsn='…port=5432 dbname=evelio') must be refused:
       that call reaches production, and only a wrong password would stop it."
fi
guard_rc=0
PG_HOST=127.0.0.1 PG_PORT=5433 PG_DB=notprod \
"$TESTVENV/bin/python" -c \
  'import psycopg2.extensions as e; e.connection("host=127.0.0.1 port=5432 dbname=evelio user=evelio")' \
  >/dev/null 2>&1 || guard_rc=$?
if [[ "$guard_rc" != "3" ]]; then
  die "the prod-connection guard does not cover psycopg2.extensions.connection
       (got exit $guard_rc, want 3) — the class underneath connect() takes the same
       DSN and would bypass a guard that only wraps the module-level function."
fi
ok "prod-connection guard verified active (port-5432 kwargs, remote URI, dsn= keyword, extensions.connection)"

# ---------------------------------------------------------------- run it --
# ONE PROCESS PER TEST FILE. The suite's modules stub each other in sys.modules
# (several inject fake `auth`/`agreement` modules), so a single pytest process
# collecting all of them fails on pollution alone — files that pass perfectly
# well in isolation. Do not "optimise" this back into one invocation: it would
# turn the gate into a permanent false alarm, and a gate everyone bypasses with
# --skip-tests protects nothing.
shopt -s nullglob
TESTS=( "$REPO"/test_*.py )
shopt -u nullglob
# An empty (or shrunken) suite must NEVER read as "all passed". This glob is
# root-only and non-recursive, so a repo that moves tests into tests/, renames
# them *_test.py, or an incomplete checkout would otherwise turn the one gate
# with no bypass into a silent no-op — exit 0, "all tests passed", deploy.
# Exit 2 = could not run, which is what this is.
MIN_TEST_FILES="${MIN_TEST_FILES:-14}"
(( ${#TESTS[@]} )) || die "no test files matched $REPO/test_*.py — the gate will not
       pass a suite that does not exist. Check the checkout and the test layout."
(( ${#TESTS[@]} >= MIN_TEST_FILES )) || die "found only ${#TESTS[@]} test file(s) in $REPO,
       expected at least $MIN_TEST_FILES. Either the checkout is incomplete or the
       suite moved; refusing to pass a gate on a suite this small. If the app repo
       legitimately has fewer files now, lower MIN_TEST_FILES in lib/run-tests.sh."

# Prove the tests can actually REACH the throwaway database with the very
# credentials they will be handed. Without this, a wrong/missing STAGING_PG_PASS
# surfaces as a pytest collection error, which the loop below counts as a plain
# FAIL — so run-tests.sh exits 1 ("tests failed") and update.sh tells the operator
# to go fix tests in the app repo. That is exit-1-vs-exit-2 conflation in the one
# place the distinction exists for: this is infrastructure, so it must be exit 2.
if ! PGPASSWORD="$STAGING_PG_PASS" "$TESTVENV/bin/python" - <<'PYCHECK' 2>/dev/null
import os, sys
try:
    import psycopg2
except Exception:
    sys.exit(0)          # tests that need no driver are fine
try:
    psycopg2.connect(host="127.0.0.1", port=5433,
                     dbname=os.environ["TESTDB"], user="evelio",
                     password=os.environ.get("PGPASSWORD", "")).close()
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)
PYCHECK
then
  die "cannot connect to the throwaway test database $TESTDB in
       $STAGING_PG_CONTAINER (127.0.0.1:5433, user evelio) with the password the
       tests will use. This is an INFRASTRUCTURE failure, not a failing test —
       every test that touches the database would report a collection error and
       be blamed on the app repo.
       Set STAGING_PG_PASS to the staging container's evelio password (see
       lib/common.sh) and re-run."
fi
ok "staging test database reachable with the test credentials"

info "pytest — ${#TESTS[@]} test file(s), one process each"
# pytest's exit code says WHICH of the two things happened, and the distinction is
# the whole point of this script's 1-vs-2 contract:
#
#   0  all collected tests passed
#   1  tests ran and some FAILED            -> a real regression signal, exit 1
#   2  interrupted / INTERNALERROR          -> the file never ran, exit 2
#   3  internal error                       -> the file never ran, exit 2
#   4  usage error                          -> the file never ran, exit 2
#   5  NO TESTS COLLECTED                   -> the file never ran, exit 2
#
# Counting 2/3/4/5 as "FAIL" was the same conflation the STAGING_PG_PASS check
# exists to prevent, one level down: update.sh printed "fix or delete the failing
# tests in the app repo" about files in which nothing failed because nothing ran.
# Exit 5 in particular is how a file that is a standalone `python3 test_x.py`
# script rather than a pytest module reports itself, and exit 2 is what a
# module-scope sys.exit() produces — a file that ran its own checks, passed them,
# and exited 0 was still recorded as a failing test.
failed=(); unrunnable=()
for t in "${TESTS[@]}"; do
  name="$(basename "$t")"
  trc=0
  ( cd "$REPO" && \
    PG_HOST=127.0.0.1 PG_PORT=5433 PG_DB="$TESTDB" PG_USER=evelio PG_PASS="$STAGING_PG_PASS" \
    PGPASSWORD="$STAGING_PG_PASS" \
    PGHOST=127.0.0.1 PGPORT=5433 PGDATABASE="$TESTDB" PGUSER=evelio \
    JWT_SECRET=pretest-not-a-real-secret \
    PG_CONTAINER="$STAGING_PG_CONTAINER" \
    TESLA_ENV_FILE=/dev/null TESLA_TOKEN_DIR="$UPD_ROOT/.testtokens" \
    "$TESTVENV/bin/python" -m pytest -q "$name" >"$LOG_DIR/test-$name.log" 2>&1 ) || trc=$?
  case "$trc" in
    0) printf '  %-46s %sPASS%s\n' "$name" "$C_GRN" "$C_OFF" ;;
    1) printf '  %-46s %sFAIL%s\n' "$name" "$C_RED" "$C_OFF"
       failed+=("$name") ;;
    5) printf '  %-46s %sDID NOT RUN%s  (pytest collected no tests)\n' "$name" "$C_YEL" "$C_OFF"
       unrunnable+=("$name (no tests collected — not a pytest module?)") ;;
    2|3) printf '  %-46s %sDID NOT RUN%s  (pytest internal error)\n' "$name" "$C_YEL" "$C_OFF"
       unrunnable+=("$name (pytest INTERNALERROR — module-scope sys.exit()?)") ;;
    *) printf '  %-46s %sDID NOT RUN%s  (pytest exit %s)\n' "$name" "$C_YEL" "$C_OFF" "$trc"
       unrunnable+=("$name (pytest exit $trc)") ;;
  esac
done

if (( ${#unrunnable[@]} )); then
  log ""
  warn "${#unrunnable[@]}/${#TESTS[@]} test file(s) did NOT run at all:"
  printf '       %s\n' "${unrunnable[@]}" >&2
  (( ${#failed[@]} )) && printf '       (%s other file(s) ran and failed: %s)\n' \
       "${#failed[@]}" "${failed[*]}" >&2
  # Exit 2 even when some files also genuinely failed: if part of the gate did not
  # execute, its green files do not add up to a verdict, and "some tests failed"
  # would understate that.
  die "part of the test suite did not execute, so the gate has no verdict to give.
       These files assert nothing at present — a green run would not mean what it
       says. Each needs to expose pytest-collectable test_* functions in the app
       repo (or be removed from it, and MIN_TEST_FILES lowered to match).
       Logs: $LOG_DIR/test-*.log"
fi

if (( ${#failed[@]} )); then
  warn "${#failed[@]}/${#TESTS[@]} test file(s) failed (logs in $LOG_DIR/test-*.log)"
  exit 1
fi
ok "all ${#TESTS[@]} test file(s) passed"
exit 0
