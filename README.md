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

You need the **real, domain-locked** Turnstile sitekey — the one used on
`app.evelio.net`. The tool refuses to build if it is missing, or if it looks like
one of Cloudflare's testing keys (`1x…`, `2x…`, `3x…`), which the staging tooling
uses on purpose. A testing key in a production bundle means the captcha verifies
nothing.

### 2. Adopt the current production state as the baseline

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
  updated. If they matter, get them into the app repo.

### 3. Prove the revert works before you need it

```bash
sudo lib/selftest.sh
```

26 checks, about a minute, entirely inside the **staging** Postgres container on
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
5. **Build** — `npm run build`, then the bundle is checked for the prod API base
   and against dev/staging hosts.
6. **cron is stopped** — three root cron jobs run code out of `/opt/tesla-oauth`
   and write to the database. Stopping the services is not enough.
7. **Migrate** — every `migrate_*.sql`, before the code, always.
8. **Backend code** → `/opt/tesla-oauth` (CRLF normalised), **odometer script** →
   `/opt/telemetry-ingest`, **frontend** → `/var/www/evelio-app`.
9. **Restart** `tesla-oauth` and `onboarding-worker`; **cron resumes**.
10. **Verify** — services active and *still* active 10s later, HTTP health, the
    frontend index plus its main JS asset, and a traceback scan of the journal.

Only after verification passes does the tool record that production is running
the new commit.

### Flags

| flag | effect |
|---|---|
| `--apply` | actually do it |
| `--soft-db-backup` | dump everything except `telemetry_raw` rows (instant instead of ~30s; see below) |
| `--with-caddy` | also sync `server-config/Caddyfile` (backup → validate → reload) |
| `--with-ingest-daemon` | also deploy `ingest_from_dockerlogs.py` and restart `telemetry-ingest` |
| `--no-log-gate` | tracebacks in the journal don't fail the deploy |

There is no `--skip-tests`. See below.

### The test gate

The app's test suite must be **green**. A failing test is fixed or deleted in the
app repo; it is never bypassed here. There is deliberately no escape hatch,
because an escape hatch on a deploy gate gets used every time and then the gate
is decoration.

Two things worth knowing:

- Tests run **one process per file**. Several of the app's test modules stub each
  other in `sys.modules` (fake `auth`, `agreement`), so a single shared pytest
  process fails on pollution alone, on files that pass perfectly in isolation.
- They run against a **throwaway database in the staging container** (`:5433`),
  and the test venv carries a guard that refuses any connection to port 5432 or
  database `evelio`. The tool asserts that guard is actually working before
  running anything — several app modules default to production when `PG_*` is
  unset, so environment variables alone are not a boundary.

**As of 2026-08-07, 9 of the app's 14 test files fail on `main`** and therefore
block deploys until they are dealt with:

```
test_combined_fleet_driver.py   test_fleet_master_link.py
test_fleet_naming.py            test_fleet_onboarding.py
test_fleet_pending_members.py   test_nonfleet_onboarding.py
test_notify_outage_integration.py  test_outage_detector.py
test_repush_active.py
```

Some are genuine assertion failures (`test_outage_detector.py` disagrees with
`outage_detector.classify`), others need setup the suite does not do. Per-file
output is in `/opt/evelio-updating/logs/test-*.log`.

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
clean error.

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
   the manual recovery if the machine dies anyway.
6. Services and cron start; health checks run.

`evelio_prerevert_<ts>` is **kept**. That is your undo-the-undo: the exact data
production had a moment before the revert. `sudo bin/status.sh` lists these, and
`--prune-aside` drops them once you are sure (about 6.5 GB each).

A backup is a **one-shot**. Once reverted, running `revert.sh` again would
restore the same dump on top and discard everything since — so it refuses unless
you pass `--force`, and it points you at the aside database first.

### What a revert does *not* undo

- **Emails already sent.** Verification mails, agreement re-consent notices.
- **Tesla and Enode API calls already made**, and tokens refreshed on disk.
- **Anything another system did** in response to the new code.
- **Files that were never in the backup** — nothing outside `/opt/tesla-oauth`,
  `/var/www/evelio-app`, `fetch_odometer.py` and (with `--with-caddy`) the
  Caddyfile.
- **Legal PDFs published after the deploy are preserved, not reverted.** The
  webroot restore never deletes anything in `legal/`, because some of those PDFs
  exist only on the server and are legally operative. If a revert *should* remove
  a PDF, do it by hand.

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
8. soft mode handles telemetry whose vehicle the revert removes.

26 checks, ~1 minute, never touches production. Run it after any change to the
revert path. It has already caught three real bugs, including one where the
verification that gates the swap was silently checking only the first table.

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

Then either merge the change into `main`, or re-baseline with
`sudo bin/adopt.sh --apply`.

**"another update/revert is already running"** — there is a lock. If you are
certain the other run is dead: `sudo fuser -k /opt/evelio-updating/.lock`.

**"A DATABASE SWAP DID NOT FINISH"** — the machine died mid-swap. The file
`/opt/evelio-updating/.swap-in-progress` contains the exact recovery command.
Your data is intact under an `evelio_prerevert_*` database. Both scripts refuse
to run until you resolve it and delete that file.

**"no database named evelio exists"** — the same situation. Do **not** start the
services. Rename the `evelio_prerevert_*` database back first.

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
clone), `releases/current/` (the one backup), `frontend-build.env`, `logs/`.

`CLAUDE.md` holds the reasoning behind every constraint — read it before changing
any of them.
