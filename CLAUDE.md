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
deployed backend file), `MANIFEST.pre` (the same, as of *before* this deploy —
`MANIFEST` is rewritten post-deploy, and without a separate copy there is no record
of which files existed pre-deploy, which is what lets `revert.sh` tell "this file
did not exist before, remove it" apart from "the snapshot is truncated, do NOT
delete production's copy"), `MANIFEST.ingest` (**every** deployed ingest file, not
just `fetch_odometer.py` — `ingest_from_dockerlogs.py` was deployed with no drift
gate at all), `FILES.new` / `FILES.prev` (the file
lists that drive restore), `backend/` (pre-deploy code snapshot),
`frontend/webroot.tgz`, `ingest/`, `caddy/Caddyfile`, `rowcounts.pre`, `db.dump`.

## Scripts

| script | what it does |
|---|---|
| `bin/adopt.sh` | one-time bootstrap: diffs live `/opt/tesla-oauth` against `origin/main`, shows every drift, records the first baseline once a human approves. Writes nothing to prod. **Refuses to run when `releases/current` holds a real deploy release** — re-baselining rewrote `meta.env` to `RELEASE_KIND=baseline`/`HAS_DB_DUMP=0`, so `revert.sh` then said "there has been no deploy to revert" while `db.dump` sat on disk. Clearing drift is not a reason to re-baseline. |
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
- **A library must never install an EXIT trap.** `restore_db_swap()` used to do
  `trap _rds_cleanup EXIT INT TERM`, which *replaced* `revert.sh`'s `on_abort` —
  the only thing that restarts the services and cron the revert stopped. Every
  aborted restore (row-count mismatch, corrupt dump, failed `CREATE DATABASE` —
  i.e. the expected path) therefore exited with production stopped and nothing
  saying so. It now traps signals only, and `on_abort` calls `_rds_cleanup`
  itself. `selftest.sh` case 10 asserts the caller's EXIT trap survives an abort.
- **Never end a function with `(( n )) && cmd`.** Under `set -e` a function whose
  last executed statement is a false `&&` guard returns non-zero, and that status
  becomes the status of the *call* — which is not exempt, so the caller dies on
  the spot. (At top level the same line is exempt and harmless, which is exactly
  why the pattern looks safe.) In `rollback_code` it would abandon production
  half-rolled-back. Both manifest-writing guards are now explicit `if` blocks;
  use `if`, or end the function with an explicit `return 0`.
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
  the one path here that could destroy data while printing `ok`), the filter must be
  `vin IS NULL OR vin IN (…)` — `vin IN (…)` is NULL, and so selects nothing, for a
  nullable FK column, and the carry-over's own count check used that same predicate
  and therefore agreed with itself while dropping every NULL-vin row
  (`selftest.sh` case 9), the `COPY` must **name its columns** on both sides because
  the source is the post-deploy table and the target the pre-deploy one, so ordinal
  matching would load telemetry into renamed or reordered columns unnoticed, and rows whose
  vehicle the revert removes are **filtered and reported**, because
  `telemetry_raw.vin` has a foreign key to `vehicles` and the restored vehicle
  list is rewound. Those rows remain in the kept pre-revert database.
- **A backup is a one-shot.** `revert.sh` refuses to run twice against the same
  release without `--force`, and points at the aside databases first. Reverting
  twice would restore the same dump on top and discard everything since. The gate
  keys on `REVERTED_MODE` — what was actually *consumed* — not merely on
  `REVERTED_AT`: a previous `--code-only` revert restored no dump, so warning that
  a later DB revert would "restore the SAME dump, discarding everything since" was
  simply false, and a guard that cries wolf is how `--force` becomes reflexive.
- **The row counts must be provably complete.** `dump_and_count_consistently`
  merges stderr into the counting stream, so a count that errored used to leave
  `ERROR: …` text in `rowcounts.pre`, pass the `-s` check, and store a "verified"
  backup that every later revert refused while blaming the dump. It now requires
  the `__COUNTS_END__` sentinel and that every line match `table|digits`.
- **A revert rewrites the MANIFEST**, and so does `rollback_code`. Otherwise the
  next `update.sh` sees the whole rollback as drift and refuses, telling the
  operator something false.
- **`status.sh --prune-aside` is a destructive command and is gated like one.**
  An `evelio_prerevert_*` database is not always the spare copy: between the two
  renames of a swap, and after any crash in that window, it **is** production's
  only data and no database named `evelio` exists. Pruning then destroyed prod
  irrecoverably, while the prompt's own wording ("the ONLY copies") read as
  reassurance. It now calls `assert_no_breadcrumb`, takes the lock, refuses when
  `$PG_DB` does not exist, and skips any candidate with live sessions.
- **Reopening the database after the swap is not optional.** The swap sets
  `ALLOW_CONNECTIONS false`, and *both* renames carry that property with the name.
  Swallowing the reopen with `|| true` meant `restart_all` could start every
  service against a database refusing connections while the revert printed
  success. Every printed recovery command therefore includes the
  `ALLOW_CONNECTIONS true` statement as well as the rename — without it the
  operator gets `database "evelio" is not currently accepting connections` and no
  hint why. `selftest.sh` case 11 asserts `datallowconn` on both databases.
- **The breadcrumb is not decoration.** The two renames have a moment between
  them where no database is named `evelio`. If the machine dies there, that file
  is the only thing on disk that says what happened. `assert_no_breadcrumb`
  blocks both scripts until a human resolves it, and `restart_all` refuses to
  start services when `evelio` does not exist — or when it exists but is still
  closed to connections, which is the same crash-loop with a more confusing log.
- **…but it must only exist when the data's location is actually unknown.**
  `revert.sh` writes the breadcrumb *before* the restore starts, yet almost every
  abort happens in the long pre-swap phase — `pg_restore` failed, the row counts
  did not match, the dump was corrupt, the telemetry carry-over failed — where
  production is provably bit-identical. Leaving it behind there turned the
  **expected** failure path into "an earlier database swap did not finish",
  blocked the next `update.sh`/`revert.sh`/`--prune-aside`, and sent the operator
  hunting for `evelio_prerevert_*` databases that were never created. That is the
  `--force`-cries-wolf problem again, and worse: an operator who learns to delete
  `.swap-in-progress` reflexively will also delete it in the one case it exists
  for. `restore_db_swap` therefore publishes **`RDS_DB_STATE`** (`safe` /
  `unresolved`), flipping to `unresolved` only after the *first rename succeeds*
  and back to `safe` once the data is provably under a known name again; `on_abort`
  clears the breadcrumb on `safe` and keeps it — loudly — on `unresolved`. A crash
  hard enough that no trap runs also leaves it in place, which is correct.
  `selftest.sh` case 13 asserts both transitions and that `on_abort` is still
  wired to them.

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
- **`legal/` needs `- legal/***` as well as `P legal/***`.** rsync's `P` stops a
  receiver-side file being *deleted*; it does **not** stop it being *overwritten*
  when the sender has one of the same name. The snapshot is a tar of the whole
  webroot, so it contains `legal/` — meaning a hand-republished PDF under a name
  that also existed at backup time (and the tracked `*-1.0.pdf` names are exactly
  the ones re-published in place) was silently rolled back. The deploy path
  publishes tracked PDFs in a separate `--ignore-existing` pass, so a genuinely new
  agreement version still ships but nothing published is ever replaced.
- **`legal/` is never deleted by a restore.** Published agreement PDFs live in
  `/var/www/evelio-app/legal`. Some versions *are* tracked in the app repo
  (`frontend/public/legal/*-1.0.pdf`, which Vite copies into `dist/`), but others
  — the hand-published ones — exist only on the server and are legally operative.
  `restore_webroot()` therefore uses `--filter='P legal/***'`, and the revert dry
  run lists every webroot file the restore *would* remove.
- **Frontend publish is staged and then applied with ONE rsync pass**, not
  `rm -rf assets` followed by a slow `cp` (that leaves an `index.html` referencing
  JS which is not there yet — a white-screened production site, permanently if
  interrupted) and not "move the live tree aside, then move the new one in"
  either: that had a window between the two loops where the webroot held no
  `index.html` and no `assets/` at all, and it discarded every `mv` error before
  unconditionally `rm -rf`ing the retired copy — so one failed rename (EACCES, or
  `assets/` nesting into `assets/assets/`) deleted the live webroot, hand-published
  `legal/` PDFs included. rsync replaces in place and never empties the directory;
  the result is asserted (`index.html` + `assets/`) before anything is cleaned up.
- **`origin/main` tip only.** Resolved as the remote ref explicitly — a bare
  `main` resolves to a local branch that `git fetch` never advances, the
  stale-checkout trap the staging tooling documents. There is intentionally no
  `--ref`.

### The test gate

- **An empty suite is not a passing suite.** `TESTS=( "$REPO"/test_*.py )` with
  `exit 0` on no matches was the last remaining bypass, and it needed no flag: a
  repo that moved tests into `tests/`, renamed them `*_test.py`, or an incomplete
  checkout turned the hard gate into a silent no-op that printed "all tests
  passed". The glob must find at least `MIN_TEST_FILES` files or the gate exits 2.
- **Infrastructure failures must not be reported as failing tests.** A wrong or
  missing `STAGING_PG_PASS` made every database-touching test die in collection,
  which the runner counted as a plain FAIL — so it exited 1 and `update.sh` told
  the operator to go fix tests in the app repo. `run-tests.sh` now proves it can
  reach the throwaway database with the credentials the tests will use, and exits
  2 if it cannot. Some of the documented "9 of 14 failing" was this.
- **The prod-connection guard must PARSE connection strings.** Substring-matching
  for `5432`/`dbname=evelio ` missed
  `psycopg2.connect("postgresql://evelio:pw@host/evelio")` entirely — no literal
  port, no `dbname=` — and then fell back to the *test* env values, which pass. It
  parses URI and keyword/value forms and fails closed, and the liveness assertion
  covers the URI form too, because the kwargs-only assertion could not see this gap.
- **It is strict and has no bypass.** A failing test is fixed or deleted in the
  app repo. `--skip-tests` was removed on purpose (the human's call): an escape
  hatch on a deploy gate gets used every time, and then the gate is decoration.
  As of 2026-08-07, 9 of 14 test files fail on `main`, so this currently blocks
  deploys — that is the intended pressure, not a bug in this tool.
- **`run-tests.sh` distinguishes exit 1 (tests failed) from exit 2 (could not
  run).** Conflating them would let an infrastructure failure read as "nothing
  failed" and deploy on the strength of a suite that never ran.
- **That distinction is per FILE, not just per run.** pytest's exit code says
  which happened: `1` is a real regression signal, but `5` (collected no tests),
  `2`/`3` (INTERNALERROR) and `4` (usage) all mean *this file never ran*. Counting
  those as `FAIL` was the same conflation one level down — `update.sh` printed
  "fix or delete the failing tests in the app repo" about files in which nothing
  failed because nothing executed. Exit `5` is how a standalone
  `python3 test_x.py` script reports itself when run under pytest, and exit `2` is
  what a module-scope `sys.exit()` produces; two such files were reporting
  `SystemExit: 0` — they ran their own checks, **passed**, and were recorded as
  failing tests. Any unrunnable file now makes the whole gate exit 2, even when
  other files genuinely failed: if part of the suite did not execute, the green
  files do not add up to a verdict.
- **`MIN_TEST_FILES` counts files, not assertions.** It proves the suite exists;
  it cannot prove the suite *runs*. The per-file classification above is what
  closes the rest of that gap — without it, fixing the two genuinely failing
  files would have turned the gate green while half of it asserted nothing.
- **A migration that will not apply to the throwaway database is exit 2.** It was
  a bare `warn`, so the run carried on against a schema-incomplete database and
  every test touching the missing tables errored in collection — reported as
  failing tests, blamed on the app repo. Infrastructure is infrastructure.
- **The gate replays migrations in the SAME order production does.** Both callers
  now go through `migration_files()` in `lib/common.sh` (git add-order). The gate
  used to use a plain `migrate_*.sql` glob, i.e. alphabetical, so the schema it
  tested against was assembled differently from the one production gets — and
  these migrations are *not* independent (`migrate_fleets.sql` needs `users`).
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
- **The API is on `evelio.net`; `app.evelio.net` is static-only.** Caddy's
  `app.evelio.net` block is `root /var/www/evelio-app` plus
  `try_files {path} /index.html`, with **no `reverse_proxy` at all**. Only
  `evelio.net` proxies `/health*`, `/api/v1/*`, `/tesla/*` and `/enode/callback*`
  to `127.0.0.1:8080`. This one fact caused two separate bugs, so it is written
  down rather than re-derived:
  - `frontend-build.env.template` shipped
    `VITE_API_BASE=https://app.evelio.net/api/v1`. A bundle built from that gets
    `index.html` and a **200** back for every API call — a frontend that is
    completely broken while nothing anywhere reports an error, and the bundle gate
    cannot catch it because that gate only proves the bundle contains the base we
    passed *in*. The correct value is `https://evelio.net/api/v1`, which is also
    the app's own default in `frontend/src/lib.js` and what the deployed bundle
    has always contained.
  - `check_http()` probed `https://app.evelio.net/api/v1/health`, which the SPA
    fallback answers `200 text/html`. That probe **could not fail** — it would
    have passed with the backend stopped, leaving post-deploy backend
    verification resting on `evelio.net/health` alone. It now probes
    `evelio.net/health` and `evelio.net/api/v1/vehicle-brands` (a real
    unauthenticated JSON GET) and **fails on a `text/html` content-type**,
    because HTML there means the static fallback served it and the request never
    reached the application. Note `/api/v1/health` does not exist — the app mounts
    `/health` at the root — so the `/api/v1` prefix needs a real route to prove it.
- **Recovering the frontend build values:** both live in the deployed bundle under
  `$WEBROOT`, so production is its own source of truth if `frontend-build.env` is
  ever lost. The Turnstile **site** key is public by design (it ships to every
  browser); the *secret* key is not in the bundle, is not recoverable this way,
  and is not this tool's business.
- **The bundle is verified before publishing**: it must contain the configured
  prod API base and must not reference a dev/staging host, and a Cloudflare
  *testing* sitekey (`1x…/2x…/3x…`) is rejected outright — checked on the **built
  artifact**, not only on `frontend-build.env`, which proves only what we passed
  *in*; the app repo shipping its own `frontend/.env*` could otherwise put a
  testing sitekey into production while the gate said "bundle verified". Scan the
  whole `dist/` tree, not just `dist/assets/`, and **without** `2>/dev/null`: a
  renamed `assets/` dir made the dev-host grep exit non-zero, which read as "no dev
  host found" and silently passed.
- **A release directory is mode 700 and `db.dump` is created mode 600.** It holds a
  full `pg_dump` of production — PII, password hashes, token columns — and under the
  default `0022` umask that was world-readable. The dump is created with
  `install -m 600` *before* data goes into it; chmod-ing afterwards leaves a window.
- **Agreement publishing (`DEPLOY.md` §D) is deliberately out of scope.** It
  emails every user. A deploy tool must not do that as a side effect.
- **Caddy is opt-in (`--with-caddy`)** and always backup → `caddy validate` the
  **source** → install → reload. If validate fails nothing is installed. Installing
  first and validating after looked contained — the running Caddy keeps its
  in-memory config — but left an invalid file at `/etc/caddy/Caddyfile`, so the next
  reload, package upgrade or reboot took TLS and the proxy down for production.
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

1. **The test suite does not currently give the gate a verdict** (measured
   2026-08-17, `origin/main`). The old "9 of 14 fail" reading was wrong: of those
   nine, **seven never executed a single assertion** — they are standalone
   `python3 test_x.py` scripts, not pytest modules (`combined_fleet_driver`,
   `fleet_master_link`, `fleet_onboarding`, `nonfleet_onboarding`,
   `repush_active` collect no tests; `fleet_naming` and `fleet_pending_members`
   call `sys.exit()` at module scope and both exit **0**, i.e. their own checks
   pass). Only **two** files hold genuine failures: `test_outage_detector.py`
   (1 of 17) and `test_notify_outage_integration.py` (2 of 10), all three about
   outage severity classification — consistent with one behaviour change, not
   nine. The app repo needs to expose pytest-collectable `test_*` functions in
   those seven files (or drop them and lower `MIN_TEST_FILES`), and fix the
   outage classifier or its tests.
2. **`migrate_fleets.sql` does not apply to an empty database** — it needs a
   `users` table that **no** `migrate_*.sql` in the repo creates, in either
   replay order. Production has `users` already, so deploys are unaffected; the
   throwaway test database cannot be built at all, which is now exit 2.
3. **`package-lock.json` is gitignored**, so `npm ci` can never work and the
   build falls back to `npm install`. Production builds are not reproducible
   until a lockfile is committed.
4. **The run-dir holds CRLF files and server-only scripts** (`recover_token.py`,
   `get_access_token*.sh`) that git has never seen.

## Relationship to the staging tooling

Different repos, different rules, one shared idea: **guards live in code, not in
a README.** If you find another way for this tool to damage prod, block it in
`lib/common.sh` or `lib/db-restore.sh`, add a `selftest.sh` case, and note it
here — do not just write a warning.
