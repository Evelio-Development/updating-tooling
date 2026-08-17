# Evelio production updater

Deploy `main` to production with one command, and be able to put everything back
with another.

This replaces the manual checklist in the app repo's `DEPLOY.md` (pull → diff →
`.bak` → copy → migrate → build → chmod → restart). That checklist is correct,
but it is long, easy to get half-way through, and has no real way back. The
reason this tool exists is **the way back**: every deploy leaves behind one
complete, verified backup, and one command restores it.

If you have never used this before, read "First time here" below, then
"Deploying". You do not need to understand the internals to use it safely —
everything is a dry run until you type `--apply`, and every destructive step
asks you to type a word first.

---

## The five commands

```bash
cd /opt/evelio-updating/updating-tooling

sudo bin/status.sh          # where are we? (read-only)
sudo bin/update.sh          # dry run: the whole plan, nothing touched
sudo bin/update.sh --apply  # deploy
sudo bin/revert.sh          # dry run: what a revert would change and destroy
sudo bin/revert.sh --apply  # put it back
```

Plus `sudo lib/selftest.sh`, which rehearses the revert machinery against the
staging database and touches nothing real.

**Nothing is ever changed without `--apply`.** Run the bare command first, every
time. It is not a formality — it prints the exact commit range, the files that
will change, the migrations that will run, and how big the backup will be.

---

## First time here

### 1. Give it the production frontend build config

The React app bakes the API base and the Cloudflare Turnstile sitekey into the
bundle at build time. Those are production values and are deliberately not in
git.

```bash
sudo cp frontend-build.env.template /opt/evelio-updating/frontend-build.env
sudo chmod 600 /opt/evelio-updating/frontend-build.env
sudo nano /opt/evelio-updating/frontend-build.env
```

**Production is its own source of truth here.** Both values are baked into the
bundle that `$WEBROOT` is serving right now, so if this file is ever lost you
recover it rather than guess:

```bash
# the API base and the Turnstile sitekey currently in production
grep -rhoE 'https://[a-z0-9.-]*evelio\.net/api/v1' /var/www/evelio-app | sort -u
grep -rhoE '0x[A-Za-z0-9_-]{10,}'                  /var/www/evelio-app | sort -u
```

The Turnstile **site** key is public by design — it ships to every browser — which
is why it is recoverable this way. The *secret* key is not in the bundle, is not
recoverable this way, and is not this tool's business.

Two traps:

- **`VITE_API_BASE` is on `evelio.net`, not `app.evelio.net`.** Caddy's
  `app.evelio.net` block is `root /var/www/evelio-app` + `try_files {path}
  /index.html` with no `reverse_proxy`, so an API base pointed there answers every
  call with `index.html` and a **200**. The frontend is then completely broken
  while nothing reports an error, and the bundle gate cannot catch it — that gate
  only proves the bundle contains the base you passed *in*. The correct value,
  `https://evelio.net/api/v1`, is what the template now ships and what the app
  itself defaults to in `frontend/src/lib.js`.
- **The sitekey must be the real, domain-locked one.** The tool refuses to build
  if it is missing or looks like one of Cloudflare's testing keys (`1x…`, `2x…`,
  `3x…`), which the staging tooling uses on purpose. A testing key in a production
  bundle means the captcha verifies nothing.

### 2. Give the test gate the staging database password

The test suite runs against a throwaway database inside the **staging** Postgres
container. It needs that container's `evelio` password — never a production
credential:

```bash
printf '%s\n' 'THE-STAGING-PASSWORD' | sudo tee /opt/evelio-updating/staging-db.pass
sudo chmod 600 /opt/evelio-updating/staging-db.pass
```

`STAGING_PG_PASS` in the environment overrides the file. If neither is set the
tool falls back to `evelio`, which is **not** the current staging password — the
gate will then stop with "cannot connect to the throwaway test database … this is
an INFRASTRUCTURE failure, not a failing test" and **exit 2**. That distinction
matters: before this check existed, a wrong password made every
database-touching test die during collection, which was counted as a plain test
failure — so the tool told you to go fix tests in the app repo that were never
actually run.

### 3. Adopt the current production state as the baseline

`/opt/tesla-oauth` is not git-tracked and has drifted over the years. Before the
tool will deploy anything it needs to know what "unchanged" means. `adopt.sh`
shows you every difference between what is running and what is in `main`, and
writes nothing to production:

```bash
sudo bin/adopt.sh            # read the report
sudo bin/adopt.sh --apply    # record the baseline
```

Read the diffs properly. Three things to look for:

- **A file that differs because production has a hotfix that never reached
  `main`.** Stop and merge it first, or your first deploy silently reverts it.
- **Files in `main` that were never deployed.** They will be added on the first
  deploy. As of 2026-08-07 there are ten, including `build_charging_sessions.py`
  and `soh_calculator.py` — the first deploy will be a big one.
- **Files on the server that git has never heard of** (`recover_token.py`,
  `get_access_token*.sh`). These are never deleted, but they are also never
  updated. If they matter, get them into the app repo. The scan is recursive, so
  server-only code in subdirectories is surfaced too.

`adopt.sh --apply` **refuses to run once a real deploy backup exists.**
`releases/current/` is the single backup; re-baselining rewrites its `meta.env` to
`RELEASE_KIND=baseline` / `HAS_DB_DUMP=0`, and `revert.sh` would then tell you
"there has been no deploy to revert" while `db.dump` was still sitting on disk.
Note that the drift error message suggests re-baselining — that advice is for
drift you have decided to discard, **not** a way to clear drift you still might
need to revert. Merge the hand-edit into `main` instead.

### 4. Prove the revert works before you need it

```bash
sudo lib/selftest.sh
```

33 checks, about a minute, entirely inside the **staging** Postgres container on
throwaway databases. See "Proving it works" below.

---

## Deploying

```bash
sudo bin/update.sh              # dry run
sudo bin/update.sh --apply
```

Order of operations. Everything up to step 5 can fail without production being
touched — but note step 4 has already replaced your previous backup:

1. **Pre-flight** — a baseline exists; build config is valid; `git fetch` and
   check out `origin/main`; **drift check** on `/opt/tesla-oauth` and
   `/opt/telemetry-ingest`; **env-var check** (does the new code read a variable
   `/etc/tesla-oauth.env` does not define?); **the test suite**; disk space.
2. **Plan** — commit range, files changing, files being removed, migrations,
   backup size. A dry run stops here.
3. **Confirm** — including a loud warning that **the previous backup is about to
   be deleted**. You type `DEPLOY`.
4. **Backup** — code snapshot, webroot tarball, `fetch_odometer.py`, Caddyfile,
   and a `pg_dump` taken together with per-table row counts **in one database
   snapshot**, then read back with `pg_restore --list` to prove it works.
5. **Build** — `npm run build`, then the **whole `dist/` tree** is checked: it must
   contain the prod API base, must not reference a dev/staging host, and must not
   contain a Cloudflare *testing* sitekey. That last check is applied to the built
   artifact, not just to `frontend-build.env` — the env file only proves what was
   passed *in*, so an app repo shipping its own `frontend/.env*` could otherwise
   put a testing sitekey into production while the gate reported success.
6. **cron is stopped** — three root cron jobs run code out of `/opt/tesla-oauth`
   and write to the database. Stopping the services is not enough.
7. **Migrate** — every `migrate_*.sql`, before the code, always.
8. **Backend code** → `/opt/tesla-oauth` (CRLF normalised), **odometer script** →
   `/opt/telemetry-ingest`, **frontend** → `/var/www/evelio-app`. The frontend is
   staged and then applied in a single `rsync` pass, so the webroot is never
   momentarily empty and a failure cannot leave `index.html` pointing at JS that is
   not there. Tracked `legal/` PDFs are published in a separate add-only pass:
   a genuinely new agreement version ships, but nothing already published is ever
   replaced or deleted.
9. **Restart** `tesla-oauth` and `onboarding-worker`; **cron resumes**.
10. **Verify** — services active and *still* active 10s later, HTTP health, the
    frontend index plus its main JS asset, and a traceback scan of the journal.

Only after verification passes does the tool record that production is running
the new commit.

The HTTP probes are `https://evelio.net/health` and
`https://evelio.net/api/v1/vehicle-brands`, and both must return 2xx **with a
non-HTML content-type**. That last condition is not fussiness: the probe used to
be `https://app.evelio.net/api/v1/health`, and because `app.evelio.net` is static
with a `try_files … /index.html` fallback, it answered `200 text/html` — so it
passed unconditionally and would have gone on passing with the backend stopped.
An HTML body on an API path means the static fallback served it and the request
never reached the application. (`/api/v1/health` does not exist; the app mounts
`/health` at the root, so proving the `/api/v1` prefix needs a real route.)

### Flags

| flag | effect |
|---|---|
| `--apply` | actually do it |
| `--soft-db-backup` | dump everything except `telemetry_raw` rows (instant instead of ~30s; see below) |
| `--with-caddy` | also sync `server-config/Caddyfile` (backup → **validate the new file** → install → reload; nothing is installed if it does not validate) |
| `--with-ingest-daemon` | also deploy `ingest_from_dockerlogs.py` and restart `telemetry-ingest` |
| `--no-log-gate` | tracebacks in the journal don't fail the deploy |

There is no `--skip-tests`. See below.

### The test gate

The app's test suite must be **green**. A failing test is fixed or deleted in the
app repo; it is never bypassed here. There is deliberately no escape hatch,
because an escape hatch on a deploy gate gets used every time and then the gate
is decoration.

Things worth knowing:

- Tests run **one process per file**. Several of the app's test modules stub each
  other in `sys.modules` (fake `auth`, `agreement`), so a single shared pytest
  process fails on pollution alone, on files that pass perfectly in isolation.
- They run against a **throwaway database in the staging container** (`:5433`),
  and the test venv carries a guard that refuses any connection to port 5432,
  database `evelio`, or a non-local host. The guard **parses** connection strings
  (URI and `key=value` forms) rather than substring-matching them — a DSN like
  `postgresql://evelio:pw@host/evelio` contains no literal `5432` and no
  `dbname=`, so it used to slip straight through. The tool asserts the guard is
  live, in both the keyword and the URI form, before running anything: several app
  modules default to production when `PG_*` is unset, so environment variables
  alone are not a boundary.
- **An empty suite is not a passing suite.** The runner requires at least
  `MIN_TEST_FILES` (14) files matching `test_*.py` in the repo root, or it exits 2.
  The glob is non-recursive, so a repo that moved its tests into `tests/` or
  renamed them `*_test.py` would otherwise have turned the one gate with no bypass
  into a silent no-op that printed "all tests passed". If the app repo
  legitimately has fewer test files, lower that number in `lib/run-tests.sh` —
  deliberately, as an edit someone reviews.
- **Exit 1 means tests failed; exit 2 means they could not run.** Anything
  environmental — no staging container, an unreachable test database, a dead
  guard, a migration that will not apply to the throwaway database — is exit 2 and
  never reads as "nothing failed".
- **That applies per file, too.** pytest exit `1` is a real failure, but `5`
  (collected no tests), `2`/`3` (INTERNALERROR) and `4` (usage) mean the file
  never ran. Those are reported as `DID NOT RUN`, not `FAIL`, and any of them
  makes the whole gate exit 2 — even alongside genuine failures, because a suite
  that partly did not execute has no verdict to give. `MIN_TEST_FILES` counts
  files; this counts whether they actually ran.
- **Migrations are replayed in the order production replays them** (git
  add-order, via `migration_files()` in `lib/common.sh`), not alphabetically.
  They are not independent, so the two orders build different schemas.

**As of 2026-08-17 the gate exits 2 on `main`: it cannot give a verdict.** There
are two independent reasons, and neither is "nine tests are broken" — that older
reading counted files that never executed as failures.

**1. The throwaway test database cannot be built.** `migrate_fleets.sql` needs a
`users` table that no `migrate_*.sql` in the app repo creates, in either replay
order. Production already has `users`, so deploys are unaffected — but the gate
stops here until the app repo's migrations apply cleanly to an empty database.

**2. Seven of the 14 files assert nothing.** They are standalone
`python3 test_x.py` scripts rather than pytest modules:

```
no tests collected (pytest exit 5)      module-scope sys.exit() (INTERNALERROR)
  test_combined_fleet_driver.py           test_fleet_naming.py
  test_fleet_master_link.py               test_fleet_pending_members.py
  test_fleet_onboarding.py
  test_nonfleet_onboarding.py
  test_repush_active.py
```

Both INTERNALERROR files exit **0** — they run their own checks and pass, and the
old gate recorded them as failing tests. They need pytest-collectable `test_*`
functions (or removal from the repo, with `MIN_TEST_FILES` lowered to match).

**Only two files hold genuine failures**, and all three assertions are about
outage severity classification — one behaviour change, not nine:
`test_outage_detector.py` (1 of 17) and `test_notify_outage_integration.py`
(2 of 10). `outage_detector.classify({"total_eligible": 4, "silent_count": 2})`
returns `healthy` where the tests expect `partial`.

Per-file output is in `/opt/evelio-updating/logs/test-*.log`. Set up
`staging-db.pass` (step 2 above) before judging any of this — a wrong password
makes every database-touching file fail for reasons that have nothing to do with
the app repo, which is why that case is its own exit-2 error.

### If a deploy fails

Code is rolled back automatically, and the tool then re-verifies that production
came back up. For the **database** you get a prompt:

```
1) code only  — restore code/frontend/services, leave the database alone (SAFE)
2) code + db  — also restore the database
3) nothing    — leave it, investigate by hand
```

It waits **300 seconds**. If nobody answers — or it is not running on a terminal
— it takes **option 1**: code is restored, the database is left alone, and it
exits non-zero saying so. An unattended process must never decide on its own to
rewind production data.

This also fires on **Ctrl-C, SIGTERM, and a dropped SSH session**, not only on a
clean error. Interrupting the prompt itself takes option 1 rather than exiting
with production half-deployed and nothing rolled back.

---

## Reverting

```bash
sudo bin/revert.sh              # dry run — read this before you --apply
sudo bin/revert.sh --apply      # code + frontend + full database restore
sudo bin/revert.sh --apply --code-only   # no data touched at all
sudo bin/revert.sh --apply --db-only     # database only
```

The dry run prints a **per-table row delta**: how many rows exist now versus in
the backup. A positive number is rows that will be *gone* afterwards — new
sign-ups, new charging sessions, new telemetry. It also lists the webroot files
that will be removed. Read both. Row counts do not show `UPDATE`s, so edited
records revert too.

You then type `REVERT-DATABASE` (or `REVERT` for `--code-only`).

### How the database restore works, and why it is safe

Nothing is dropped.

1. Services **and cron** are stopped, so nothing is writing.
2. The dump is restored into a **new** database, `evelio_restore_<ts>`, created
   from `template0` with production's exact encoding and locale. If this fails,
   production is untouched — the live database was never opened for writing.
3. The live database is closed to new connections (`ALLOW_CONNECTIONS false`), so
   nothing can sneak in during the swap.
4. The restored copy is verified: every table in every schema must match the row
   counts captured in the same snapshot as the dump. A mismatch aborts, live DB
   still untouched. It also refuses to swap if it verified zero tables.
5. Swap: `evelio` is **renamed** to `evelio_prerevert_<ts>`, and the restored
   copy is renamed to `evelio`. If the second rename fails, the first is undone.
   Signals are blocked across this window, and a breadcrumb file on disk explains
   the manual recovery if the machine dies anyway. Both databases are then reopened
   to connections — the rename carries `ALLOW_CONNECTIONS false` with it, and if
   that cannot be undone the revert **fails loudly** rather than starting services
   against a database that refuses to talk to them.
6. Services and cron start; health checks run.

If any step before the swap aborts, production's services are restarted before the
command exits. (They used to be left stopped and silent: the restore function
installed its own `EXIT` trap, which displaced the one that brings production
back up.)

`evelio_prerevert_<ts>` is **kept**. That is your undo-the-undo: the exact data
production had a moment before the revert. `sudo bin/status.sh` lists these, and
`--prune-aside` drops them once you are sure (about 6.5 GB each).

**`--prune-aside` is destructive and now behaves like it.** An
`evelio_prerevert_*` database is not always the spare copy — mid-swap, or after a
crash in that window, it *is* production's only data and no database named
`evelio` exists. Pruning then destroyed production irrecoverably, while the
prompt's own wording ("these are the ONLY copies") read as reassurance. It now
refuses while a swap breadcrumb exists, refuses if `evelio` is missing, takes the
same lock as a deploy, and skips any database that still has sessions attached.

A backup is a **one-shot**. Once reverted, running `revert.sh` again would
restore the same dump on top and discard everything since — so it refuses unless
you pass `--force`, and it points you at the aside database first. The check keys
on what was actually *consumed*: a previous `--code-only` revert restored no dump,
so it no longer blocks (and no longer mis-describes) a later database revert.

If the code snapshot in the backup is incomplete — a deploy interrupted while
writing it — `revert.sh` now **refuses** instead of treating "absent from the
snapshot" as "this file did not exist before the deploy" and deleting production's
copy of every backend file. It cross-checks the snapshot against `MANIFEST.pre`,
the pre-deploy fingerprint.

### What a revert does *not* undo

- **Emails already sent.** Verification mails, agreement re-consent notices.
- **Tesla and Enode API calls already made**, and tokens refreshed on disk.
- **Anything another system did** in response to the new code.
- **Files that were never in the backup** — nothing outside `/opt/tesla-oauth`,
  `/var/www/evelio-app`, `fetch_odometer.py` and (with `--with-caddy`) the
  Caddyfile.
- **Legal PDFs published after the deploy are preserved, not reverted.** The
  webroot restore never deletes *or overwrites* anything in `legal/`, because some
  of those PDFs exist only on the server and are legally operative. (Protecting
  them from deletion was not enough: rsync's `P` rule still let the snapshot's
  older copy overwrite a PDF republished under the same name — and the tracked
  `*-1.0.pdf` names are exactly the ones re-published in place.) If a revert
  *should* remove a PDF, do it by hand.

### `--soft-db-backup`

`telemetry_raw` is 6536 MB of the 6553 MB database; everything else — every user,
fleet, vehicle, contract, session — is about 8 MB. A soft backup skips the
telemetry rows, so it is near-instant.

The trade-off moves to revert time: the restored database has no telemetry, so
before the swap the tool copies the *current* `telemetry_raw` across. Nothing is
lost, but that copy is several GB and takes minutes with services down. Telemetry
belonging to a vehicle onboarded *after* the backup cannot come across (the
revert is removing that vehicle, and the foreign key would reject it) — those
rows stay in the kept pre-revert database, and the tool tells you how many.

This is the one path in the tool that could destroy data while printing `ok`,
because soft mode deliberately exempts `telemetry_raw` from row verification. Two
things guard it, both learned the hard way:

- Rows with a **NULL** `vin` are carried across explicitly. `vin IN (…)` evaluates
  to NULL — and therefore selects nothing — for a nullable foreign key, and the
  copy's own count check used that same predicate, so it agreed with itself while
  silently dropping every such row.
- The `COPY` **names its columns** on both sides. The source is the post-deploy
  table and the target the pre-deploy one, so matching by ordinal position would
  load telemetry into renamed or reordered columns unnoticed. A soft revert across
  a change to `telemetry_raw`'s columns now stops with an explanation and points
  you at `--code-only` or a full restore.

The default full backup is the reverse: ~30 s to take, seconds to restore, and it
rewinds telemetry to the backup point.

---

## Proving it works

```bash
sudo lib/selftest.sh
```

This runs the **real** restore-and-swap code — the same function `revert.sh`
calls — against the staging Postgres on throwaway databases, and asserts:

1. a good dump restores exactly, and the pre-revert data is kept;
2. a row-count mismatch aborts **without touching the live database**;
3. a truncated dump aborts without touching the live database;
4. a soft dump preserves telemetry;
5. **writes landing during the backup do not break the restore**;
6. a second schema (`health`) is verified, not silently ignored;
7. empty row counts refuse to swap rather than verifying nothing;
8. soft mode handles telemetry whose vehicle the revert removes;
9. soft mode carries across telemetry with a **NULL** `vin`;
10. an aborted restore leaves the **caller's** `EXIT` trap intact, so production's
    services still get restarted;
11. both databases accept connections again after a successful swap;
12. a malformed row-count file is rejected rather than restored against.

33 checks, ~1 minute, never touches production. Run it after any change to the
revert path. It has already caught five real bugs, including one where the
verification that gates the swap was silently checking only the first table, one
where soft-mode reverts silently discarded all NULL-`vin` telemetry, and one where
every failed revert left production stopped without saying so.

---

## Only one backup is kept

By design. Each deploy destroys the previous backup and replaces it — you can
always go back exactly one deploy, never two. The swap is two renames, so a
complete backup always exists on disk.

Practically: **do not stack deploys while debugging one.** If yesterday's deploy
is still suspect, revert it or bless it before deploying again. Note that a
*failed* deploy also consumes the backup slot.

---

## Troubleshooting

**"DRIFT DETECTED"** — someone edited production code outside this tool.
Deploying would overwrite it. Inspect it (the run-dir is CRLF and the repo is LF,
so a plain `diff` shows every line as changed):

```bash
diff -u <(sed 's/\r$//' /opt/tesla-oauth/api_fleet.py) \
        <(sed 's/\r$//' /opt/evelio-updating/src/api_fleet.py)
```

Then merge the change into `main` and deploy. Re-baselining with
`sudo bin/adopt.sh --apply` also clears drift, but it **discards your ability to
revert the last deploy** — so `adopt.sh` refuses while a real deploy backup exists.
Only re-baseline once you no longer need that backup.

The drift gate covers `ingest_from_dockerlogs.py` as well as `fetch_odometer.py`.
It previously fingerprinted only the odometer script, so a hand-fix to the ingest
daemon passed the gate and was silently overwritten by the next
`--with-ingest-daemon` deploy.

**"another update/revert is already running"** — there is a lock. If you are
certain the other run is dead: `sudo fuser -k /opt/evelio-updating/.lock`.

**"A DATABASE SWAP DID NOT FINISH"** — the machine died mid-swap. The file
`/opt/evelio-updating/.swap-in-progress` contains the exact recovery command.
Your data is intact under an `evelio_prerevert_*` database. Both scripts refuse
to run until you resolve it and delete that file.

This message means what it says: a revert that aborts *before* the swap — a
failed `pg_restore`, a row-count mismatch, a corrupt dump, a failed telemetry
carry-over — removes the breadcrumb on its way out, because production was never
touched. If you see it, the swap really did reach the rename window. Do not get
into the habit of deleting that file.

**"no database named evelio exists"** — the same situation. Do **not** start the
services, and do **not** run `--prune-aside` (it will refuse, but do not try):
that `evelio_prerevert_*` database is your production data. Rename it back first,
and run **both** statements — the rename carries `ALLOW_CONNECTIONS false` with it:

```bash
docker exec -i telemetry-postgres psql -U evelio -d postgres \
  -c 'ALTER DATABASE "evelio_prerevert_<ts>" RENAME TO "evelio"' \
  -c 'ALTER DATABASE "evelio" WITH ALLOW_CONNECTIONS true'
```

Without the second one every service fails with `database "evelio" is not
currently accepting connections`.

**"database is not currently accepting connections"** — a swap was interrupted, or
a rename was done by hand without the `ALLOW_CONNECTIONS true` statement above.
The data is fine; run that statement.

**"cannot connect to the throwaway test database"** — infrastructure, not tests.
See step 2 of "First time here": `staging-db.pass`.

**"found only N test file(s)"** — the runner found fewer than `MIN_TEST_FILES`
test files. Either the checkout is incomplete or the app repo moved its tests. It
refuses rather than reporting an empty suite as green.

**A leftover `evelio_restore_*` database** — scratch from an interrupted revert.
`bin/status.sh` shows it and whether anything is connected to it. It is never
pruned automatically, precisely because it might belong to a revert running in
another terminal.

**`npm ci` warning about no lockfile** — the app repo gitignores
`package-lock.json`, so the build falls back to `npm install` and dependency
versions are resolved fresh. Committing a lockfile in the app repo fixes it.

---

## Out of scope on purpose

- **Agreement/legal publishing** (`DEPLOY.md` §D) — it emails every user. That
  should stay a deliberate manual act, not a deploy side effect.
- **The marketing site** (`evelio.net`) — separate repo, separate process.
- **Deploying anything other than `origin/main`** — production runs main. There
  is no `--ref`.

---

## Files

```
bin/adopt.sh      one-time baseline
bin/update.sh     deploy
bin/revert.sh     undo
bin/status.sh     where are we / prune kept databases
lib/common.sh     paths, guards, locking, health checks
lib/db-restore.sh the database half of a revert (side-restore, verify, swap)
lib/run-tests.sh  the test gate (staging DB only, with a verified prod guard)
lib/selftest.sh   rehearses the revert against staging
```

State lives outside the repo, in `/opt/evelio-updating/`: `src/` (the private
clone), `releases/current/` (the one backup), `frontend-build.env`,
`staging-db.pass`, `logs/`.

A release directory holds a full `pg_dump` of production — user PII, password
hashes, token columns — so `releases/` is mode `700` and `db.dump` is created mode
`600` before any data goes into it. None of it is ever committed: `.gitignore`
covers `releases/`, `logs/`, `*.dump` and `*.env`, and only the
`frontend-build.env.template` is tracked.

`CLAUDE.md` holds the reasoning behind every constraint — read it before changing
any of them.
