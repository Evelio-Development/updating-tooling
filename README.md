# Evelio production updater

Pull `main`, deploy it to production, and be able to put everything back.

This replaces the manual checklist in the app repo's `DEPLOY.md`. The point is
not that deploying is hard — it's that **stopping half-way through and going
home is currently impossible**. With this tool, every deploy leaves behind one
complete, verified backup, and one command puts production back the way it was.

```
sudo bin/status.sh          # where are we?
sudo bin/update.sh          # dry run: the whole plan, nothing touched
sudo bin/update.sh --apply  # deploy
sudo bin/revert.sh          # dry run: exactly what a revert would change/lose
sudo bin/revert.sh --apply  # put it back
```

Everything is **dry-run by default**. Nothing changes without `--apply`.

---

## One-time setup

**1. Build config for the frontend.** The React build bakes in the API base and
the Cloudflare Turnstile sitekey. Those are production values and are not in git.

```bash
sudo cp frontend-build.env.template /opt/evelio-updating/frontend-build.env
sudo chmod 600 /opt/evelio-updating/frontend-build.env
sudo nano /opt/evelio-updating/frontend-build.env     # fill in the real sitekey
```

**2. Adopt the current production state as the baseline.**

`/opt/tesla-oauth` is not git-tracked and has drifted over the years. Before the
tool will deploy anything, it wants to know what "unchanged" means. `adopt.sh`
shows you every difference between what's running and what's in `main`, and
writes nothing to production:

```bash
sudo bin/adopt.sh            # read the report carefully
sudo bin/adopt.sh --apply    # record the baseline
```

Read the diffs. If one of them is a **server-side hotfix that never made it into
main**, stop and merge it first — otherwise your first deploy silently reverts
it. The report also lists files that exist on the server but not in git
(`recover_token.py`, `get_access_token*.sh`, …). Those are never deleted, but
they will also never be updated; get them into the repo if they matter.

---

## Deploying

```bash
sudo bin/update.sh              # dry run
sudo bin/update.sh --apply
```

What happens, in order. Everything up to step 5 can fail harmlessly —
production isn't touched until step 6:

1. **Pre-flight** — a baseline exists; the build config is present and is not a
   testing sitekey; `git fetch` and check out `origin/main`; **drift check** on
   `/opt/tesla-oauth`; **env-var check** (does the new code read a variable
   `/etc/tesla-oauth.env` doesn't define?); **test suite**; disk space.
2. **Plan** — commit range, which files change, which migrations will replay,
   backup size. In a dry run it stops here.
3. **Confirm** — including a loud warning that **the previous backup is about to
   be deleted**. You type `DEPLOY`.
4. **Backup** — code snapshot, webroot tarball, `fetch_odometer.py`, Caddyfile,
   per-table row counts, and a full `pg_dump` (~30s, ~390 MB) which is then read
   back with `pg_restore --list` to prove it works. The new backup is completed
   *before* the old one is removed.
5. **Build** — `npm ci && npm run build`, then the bundle is checked for the prod
   API base and against dev/staging hosts.
6. **Migrate** — all `migrate_*.sql`, before the code, always.
7. **Backend code** → `/opt/tesla-oauth` (CRLF normalised), **odometer script** →
   `/opt/telemetry-ingest`, **frontend** → `/var/www/evelio-app` + `chmod a+rX`.
8. **Restart** `tesla-oauth`, `onboarding-worker`.
9. **Verify** — services active and *still* active 10s later, `/health`, the
   frontend index and its main JS asset, and a traceback scan of the journal.

### Flags

| flag | effect |
|---|---|
| `--apply` | actually do it |
| `--soft-db-backup` | dump everything except `telemetry_raw` rows (instant instead of ~30s; see the trade-off below) |
| `--skip-tests` | skip the test gate (recorded in the release metadata) |
| `--no-log-gate` | tracebacks in the journal don't fail the deploy |
| `--with-caddy` | also sync `server-config/Caddyfile` (backup → validate → reload) |
| `--with-ingest-daemon` | also deploy `ingest_from_dockerlogs.py` and restart `telemetry-ingest` |

### About the test gate

It is a **regression** gate, not a pass/fail gate. Right now **9 of the app's 14
test files fail on `main`** for pre-existing reasons (real assertion failures in
the outage detector, plus modules that need setup the suite doesn't do). A gate
that blocked every deploy would just be bypassed with `--skip-tests` every time.

So the first `--apply` records today's failing set in
`/opt/evelio-updating/tests.baseline`, and from then on the gate blocks **only if
a test file that used to pass starts failing**. If a file gets fixed, the
baseline tightens automatically. Per-file logs land in
`/opt/evelio-updating/logs/test-*.log`.

Tests run **one process per file** — several of the app's test modules stub each
other (`auth`, `agreement`) and poison a shared pytest process.

### If a deploy fails

Code is rolled back automatically. For the **database** you get a prompt:

```
1) code only  — restore code/frontend/services, leave the database alone (SAFE)
2) code + db  — also restore the database
3) nothing    — leave it, investigate by hand
```

It waits **300 seconds**. If nobody answers — or it isn't running on a terminal —
it takes **option 1**: code is restored, the database is left alone, and it exits
non-zero saying so. A script running unattended must never decide on its own to
rewind production data.

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
sign-ups, new charging sessions, new telemetry. Read it. Row counts don't show
`UPDATE`s, so edited records revert too.

You then type `REVERT-DATABASE` (or `REVERT` for `--code-only`).

### How the database restore works, and why it's safe

Nothing is dropped.

1. Services (including `telemetry-ingest`) are stopped, so nothing is writing.
2. The dump is restored into a **new** database, `evelio_restore_<ts>`. If this
   fails, production is exactly as it was — the live DB was never opened.
3. The restored copy is verified: every table's row count must match the counts
   recorded at backup time. A mismatch aborts, live DB still untouched.
4. Swap: `evelio` is **renamed** to `evelio_prerevert_<ts>`, and the restored
   copy is renamed to `evelio`. If the second rename fails, the first is undone.
5. Services start; health checks run.

`evelio_prerevert_<ts>` is **kept**. That is your undo-the-undo: the exact data
production had a moment before the revert. `sudo bin/status.sh` lists these and
`--prune-aside` drops them once you're sure (they cost ~6.5 GB each).

### Proving it works, before you need it

```bash
sudo lib/selftest.sh
```

This runs the **real** restore-and-swap code against the staging Postgres on
throwaway databases and asserts the things you actually care about: a good dump
restores exactly, the pre-revert data is kept, a mismatched or truncated dump
aborts **without touching the live database**, and a soft dump preserves
telemetry. 17 checks, ~30 seconds, never touches production.

Run it after any change to the revert path. It already caught one real bug: the
row-count verification was silently checking only the first table, so the swap
could have proceeded on a check that never ran.

### What a revert does *not* undo

Emails already sent. Tesla API calls already made. Tokens refreshed on disk.
Anything another system did in response to the new code. A revert restores *your*
state, not the world's.

### `--soft-db-backup`

`telemetry_raw` is 6.5 GB of the 6.55 GB database; everything else — every user,
fleet, vehicle, contract, session — is about 8 MB. A soft backup skips the
telemetry rows, so it's near-instant.

The trade-off moves to revert time: the restored database has no telemetry, so
before the swap the tool copies the *current* `telemetry_raw` across. Nothing is
lost, but that copy takes several minutes with services down. Use a soft backup
when you want a fast deploy and accept a slower, telemetry-preserving revert.
The default full backup is the reverse: 30s to take, seconds to restore, and it
rewinds telemetry to the backup point.

---

## Only one backup is kept

By design. Each deploy destroys the previous backup and replaces it — you can
always go back exactly one deploy, never two. `update.sh` warns about this before
it starts, and the new backup is completed before the old one is deleted, so
there is never a moment with no backup at all.

Practically: **don't stack deploys while debugging one.** If yesterday's deploy
is still suspect, revert it or bless it before deploying again.

---

## Drift

If `update.sh` says:

```
DRIFT DETECTED in /opt/tesla-oauth
  api_fleet.py  (modified since last deploy)
```

someone edited production code outside this tool. Deploying would overwrite it.
Look at it (`diff -u /opt/tesla-oauth/api_fleet.py /opt/evelio-updating/src/api_fleet.py`),
then either merge the change into `main` or re-baseline with `sudo bin/adopt.sh --apply`.

Files that are runtime state rather than code — `tokens/`, `.venv/`, `*.env`,
`pending_registrations.json`, `_bak_archive/`, `*.bak.*` — are protected: never
copied over, never deleted, never counted as drift.

---

## Out of scope on purpose

- **Agreement/legal publishing** (`DEPLOY.md` §D) — it emails every user. Keep it
  a deliberate manual act.
- **The marketing site** (`evelio.net`) — separate repo, separate process.
- **Deploying anything other than `origin/main`** — production runs main.

---

## Files

```
bin/adopt.sh     one-time baseline
bin/update.sh    deploy
bin/revert.sh    undo
bin/status.sh    where are we / prune kept databases
lib/common.sh    paths, guards, health checks
lib/run-tests.sh pre-deploy test gate (staging DB only, with a prod-connect guard)
```

`CLAUDE.md` holds the reasoning behind each constraint — read it before changing
any of them.
