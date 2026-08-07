# CLAUDE.md — `updating-tooling` (production deploy + revert for app.evelio)

This repo deploys **production**. That is the opposite of its sibling
`/opt/evelio-staging/staging-tooling`, whose entire purpose is to never touch
prod. Do not copy guards between the two without reading what they actually do:
here, reaching prod is the job. The safety comes from **dry-run by default, a
verified backup taken before the first mutation, and a revert path that never
destroys the thing it is replacing.**

It replaces the manual process in the app repo's `DEPLOY.md`. That process is
correct but long, and it has no way back beyond scattered `.bak.*` files. This
tool's reason to exist is the **way back**.

## The one rule that matters

**The revert must never be the thing that loses data.** Every database operation
is therefore restore-aside-then-swap: the dump is restored into a *side*
database, verified against row counts captured in the same snapshot as the dump,
and only then renamed into place — and the database being replaced is **renamed
aside, not dropped**. There is always an answer to "where is the data right now",
and it is never "nowhere". Do not "simplify" this into `dropdb && pg_restore`.

## Layout

```
/opt/evelio-updating/
  updating-tooling/     this git repo (bin/, lib/, docs)
  src/                  private clone of app.evelio — ONLY this tool touches it
  releases/current/     THE backup. Exactly one. Replaced by each deploy.
  frontend-build.env    untracked; prod VITE_* build values
  logs/                 npm, migration and per-test-file logs
  .testvenv/            venv for the test gate
  .lock                 flock; one update/revert at a time
  .swap-in-progress     breadcrumb; exists only during a database swap
```

A release directory holds: `meta.env`, `MANIFEST` (CRLF-normalised sha256 per
deployed backend file), `MANIFEST.ingest`, `FILES.new` / `FILES.prev` (the file
lists that drive restore), `backend/` (pre-deploy code snapshot),
`frontend/webroot.tgz`, `ingest/`, `caddy/Caddyfile`, `rowcounts.pre`, `db.dump`.

## Scripts

| script | what it does |
|---|---|
| `bin/adopt.sh` | one-time bootstrap: diffs live `/opt/tesla-oauth` against `origin/main`, shows every drift, records the first baseline once a human approves. Writes nothing to prod. |
| `bin/update.sh` | pre-flight → plan → confirm → backup → build → migrate → code → frontend → restart → verify. Dry-run unless `--apply`. |
| `bin/revert.sh` | restores the single kept release. Dry-run unless `--apply`. |
| `bin/status.sh` | what's deployed, what the backup holds, drift, kept aside-databases, breadcrumbs. |
| `lib/db-restore.sh` | `restore_db_swap()` — the database half of a revert, isolated so it can be rehearsed. |
| `lib/run-tests.sh` | the test gate. Exits 0 / 1 (tests failed) / 2 (could not run). |
| `lib/selftest.sh` | rehearses `restore_db_swap()` against the staging container. **Run it after touching anything in the revert path.** |

## Hard constraints for anyone (human or Claude) editing this repo

### Process

- **DRY-RUN IS THE DEFAULT.** `update.sh` and `revert.sh` print and exit unless
  `--apply`. Same convention as the staging tooling — deliberately, so muscle
  memory transfers.
- **One run at a time (`take_lock`).** Without a lock, "I wasn't sure it
  finished, let me run it again" becomes two runs interleaving migrations and the
  second destroying the backup the first needs for its rollback.
- **Signals must be handled, not just errors.** A bash script killed by a signal
  runs its EXIT trap with `$? == 0`. Without the `INTERRUPTED` flag that
  `on_signal` sets, a Ctrl-C or dropped SSH mid-deploy would look like success
  and skip the rollback entirely. Every trap in this repo checks it. Signals are
  additionally **blocked** (`trap '' INT TERM HUP`) across the database swap.
- **Never auto-revert the database.** A failed deploy rolls back *code* on its
  own and then re-verifies that production came back. For the database it prompts
  (`ROLLBACK_PROMPT_TIMEOUT`, **300s**) and, on timeout or with no TTY, takes the
  code-only branch and says loudly that the DB was not reverted. It does **not**
  `exec` into `revert.sh` — the failed deploy must still exit non-zero.

### Backups

- **The backup is taken before the first prod mutation, and verified.** The dump
  is read back with `pg_restore --list` *before* any migration runs. If that
  fails the deploy aborts having changed nothing.
- **The dump and the row counts must come from ONE snapshot.**
  `dump_and_count_consistently()` opens a `REPEATABLE READ` transaction, exports
  its snapshot, counts inside it, and passes `--snapshot` to `pg_dump`. Counting
  first and dumping afterwards — the obvious way — is broken: production writes
  ~220 telemetry rows/minute, so the dump legitimately contains more rows than
  the counts, and the restore then fails its own verification and calls a perfect
  backup corrupt. **Every full revert would have aborted.** `selftest.sh` case 5
  exists to keep this fixed.
- **Only ONE release is kept** (the human chose this). The swap is
  `mv current old.$$; mv new current; rm -rf old.$$` — two renames on one
  filesystem, so a complete backup always exists. `rm -rf current; mv new
  current` has a window with none. `update.sh` also warns explicitly, before
  doing anything, that the previous backup will be destroyed.
- **Snapshot the UNION of the new file list and the previously deployed one.**
  Snapshotting only the new list leaves a file that `main` has *deleted* absent
  from the backup — so the deploy removes it from production and the revert,
  finding nothing to restore, removes it again. It would be gone permanently.

### The revert

- **`revert.sh` never drops the live database.** Side-restore → close to
  connections → verify → `ALTER DATABASE evelio RENAME TO evelio_prerevert_<ts>`
  → rename the restored copy into place. If the second rename fails it renames
  the original back. The aside copy is retained until a human runs
  `status.sh --prune-aside`. This is what makes a revert itself revertible.
- **The side database is created from `template0`** with production's exact
  encoding and locale — otherwise anything sitting in `template1` rides along
  into production at the swap. `_copy_database_level_state()` carries across the
  per-database settings, connection limit and ACL that `pg_dump` does **not**
  contain, and warns if database-level GRANTs exist that it cannot reproduce.
- **The verification must actually run.** It refuses to swap if it verified zero
  tables. It enumerates **all non-system schemas** (prod has `health` as well as
  `public`) and `relkind IN ('r','p')`. And it reads its input into an array
  first: a `docker exec -i` inside a `while read` loop consumes the loop's own
  stdin and silently skips every table after the first — that shipped once, and
  `selftest.sh` caught it.
- **`ALLOW_CONNECTIONS false`, not a hopeful `pg_terminate_backend`.** Stopping
  the services is not enough: root's crontab runs `fetch_odometer.py` and
  `run_outage_check.sh` every 15 minutes and `run_notifier.sh` hourly, all of
  which connect to the prod DB, and two of which execute code out of
  `/opt/tesla-oauth`. `pause_cron` stops cron for the duration of both deploy and
  revert; the database is additionally closed to connections across the swap.
- **Soft-mode telemetry carry-over runs BEFORE the database is closed** — it has
  to read from the live database. Two traps in it: `bash -o pipefail` is
  load-bearing (without it only `psql`'s status is seen, so a `COPY` that dies
  mid-stream looks like success — and soft mode exempts `telemetry_raw` from row
  verification, so the swap would silently truncate production's telemetry; it is
  the one path here that could destroy data while printing `ok`), and rows whose
  vehicle the revert removes are **filtered and reported**, because
  `telemetry_raw.vin` has a foreign key to `vehicles` and the restored vehicle
  list is rewound. Those rows remain in the kept pre-revert database.
- **A backup is a one-shot.** `revert.sh` refuses to run twice against the same
  release without `--force`, and points at the aside databases first. Reverting
  twice would restore the same dump on top and discard everything since.
- **A revert rewrites the MANIFEST**, and so does `rollback_code`. Otherwise the
  next `update.sh` sees the whole rollback as drift and refuses, telling the
  operator something false.
- **The breadcrumb is not decoration.** The two renames have a moment between
  them where no database is named `evelio`. If the machine dies there, that file
  is the only thing on disk that says what happened. `assert_no_breadcrumb`
  blocks both scripts until a human resolves it, and `restart_all` refuses to
  start services when `evelio` does not exist.

### Files

- **Drift check is a gate, not a warning**, and it covers `/opt/telemetry-ingest`
  as well as the run-dir. The run-dir is not git-tracked and has historically
  absorbed hand-edits; deploying over one silently reverts a hotfix.
- **Comparisons must ignore line endings.** The live run-dir holds **CRLF** files
  (deployed from a Windows checkout); the repo is LF. Every diff, drift check and
  manifest hash goes through `norm_cat`/`norm_sha`/`same_content`. Without this
  every file reads as changed and the gate is pure noise. Relatedly, the MANIFEST
  is written **from `$BACKEND_DIR` after the copy**, not from the repo — the two
  differ whenever normalisation kicked in.
- **The PROTECTED list is load-bearing.** `tokens/` (live Tesla OAuth tokens),
  `.venv/`, `*.env`, `pending_registrations.json`, `_bak_archive/`, `*.bak.*` are
  never mirrored, never deleted, never counted as drift. A "true mirror" that
  deletes anything not in git would delete the OAuth tokens. Files unknown to git
  and not protected are **reported, never removed**.
- **`legal/` is never deleted by a restore.** Published agreement PDFs live in
  `/var/www/evelio-app/legal`. Some versions *are* tracked in the app repo
  (`frontend/public/legal/*-1.0.pdf`, which Vite copies into `dist/`), but others
  — the hand-published ones — exist only on the server and are legally operative.
  `restore_webroot()` therefore uses `--filter='P legal/***'`, and the revert dry
  run lists every webroot file the restore *would* remove.
- **Frontend publish is staged and swapped**, not `rm -rf assets` followed by a
  slow `cp`: that leaves an `index.html` referencing JS that is not there yet — a
  white-screened production site, permanently if interrupted.
- **`origin/main` tip only.** Resolved as the remote ref explicitly — a bare
  `main` resolves to a local branch that `git fetch` never advances, the
  stale-checkout trap the staging tooling documents. There is intentionally no
  `--ref`.

### The test gate

- **It is strict and has no bypass.** A failing test is fixed or deleted in the
  app repo. `--skip-tests` was removed on purpose (the human's call): an escape
  hatch on a deploy gate gets used every time, and then the gate is decoration.
  As of 2026-08-07, 9 of 14 test files fail on `main`, so this currently blocks
  deploys — that is the intended pressure, not a bug in this tool.
- **`run-tests.sh` distinguishes exit 1 (tests failed) from exit 2 (could not
  run).** Conflating them would let an infrastructure failure read as "nothing
  failed" and deploy on the strength of a suite that never ran.
- **One process per test file.** Several app test modules stub each other in
  `sys.modules`; a shared pytest process fails on pollution alone.
- **The prod-connection guard must be a real module plus a ONE-LINE `import`
  `.pth`.** Python processes a `.pth` line by line and only executes lines
  starting with `import` — a multi-line program in a `.pth` does nothing at all,
  silently. That exact mistake shipped here once and the guard never ran. (A
  venv-local `sitecustomize.py` does not work either: Debian's system one shadows
  it.) `run-tests.sh` now **asserts the guard is live**, requiring exit 3 from a
  deliberate port-5432 connection attempt, before running anything.

### General

- **Never commit** a rendered `frontend-build.env`, a dump, a release dir, or any
  secret. Only the template is tracked. The tool reads the *names* of env keys
  from `/etc/tesla-oauth.env` for its pre-flight check, never their values, and
  it parses only `VITE_*` lines out of the build config rather than sourcing it
  (a stray line in a sourced file could redefine `WEBROOT` or `PG_DB`).
- **The bundle is verified before publishing**: it must contain the configured
  prod API base and must not reference a dev/staging host, and a Cloudflare
  *testing* sitekey (`1x…/2x…/3x…`) is rejected outright.
- **Agreement publishing (`DEPLOY.md` §D) is deliberately out of scope.** It
  emails every user. A deploy tool must not do that as a side effect.
- **Caddy is opt-in (`--with-caddy`)** and always backup → `caddy validate` →
  reload. If validate fails the old config keeps running.
- **Never add any of this to a timer, cron, or `systemctl enable`.** Deploys are
  deliberate manual acts, same as the parent stack.

## What a revert can and cannot undo

**Can:** backend code (including files `main` deleted), `fetch_odometer.py`, the
webroot, the Caddyfile (if the same run deployed it), and — on the default path —
the entire database including schema and telemetry.

**Cannot:** emails already sent, Tesla/Enode API calls already made, tokens
refreshed on disk, anything a third system did in response to the new code, and
anything outside the paths listed above. **Legal PDFs published since the deploy
are preserved rather than reverted** — deliberately.

Also inherent, not a bug: a full DB restore rewinds `telemetry_raw` to the
backup, discarding telemetry ingested since. `revert.sh` prints the exact
per-table row delta and requires `REVERT-DATABASE` to be typed. `--code-only`
avoids it entirely.

## Known upstream problems this tool surfaces

These are the app repo's to fix, not this one's:

1. **9 of 14 test files fail on `main`** — blocks every deploy under the strict
   gate.
2. **`package-lock.json` is gitignored**, so `npm ci` can never work and the
   build falls back to `npm install`. Production builds are not reproducible
   until a lockfile is committed.
3. **The run-dir holds CRLF files and server-only scripts** (`recover_token.py`,
   `get_access_token*.sh`) that git has never seen.

## Relationship to the staging tooling

Different repos, different rules, one shared idea: **guards live in code, not in
a README.** If you find another way for this tool to damage prod, block it in
`lib/common.sh` or `lib/db-restore.sh`, add a `selftest.sh` case, and note it
here — do not just write a warning.
