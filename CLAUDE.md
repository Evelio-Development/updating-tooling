# CLAUDE.md — `updating-tooling` (production deploy + revert for app.evelio)

This repo deploys **production**. That is the opposite of its sibling
`/opt/evelio-staging/staging-tooling`, whose entire purpose is to never touch
prod. Do not copy guards between the two without reading what they actually do:
here, reaching prod is the job; the safety comes from **dry-run by default, a
verified backup taken before the first mutation, and a revert path that never
destroys the thing it is replacing.**

It replaces the manual process in the app repo's `DEPLOY.md` (pull → diff →
`.bak` → copy → migrate → build → chmod → restart). That process is correct but
long, and it has no way back beyond scattered `.bak.*` files. This tool's reason
to exist is the **way back**.

## The one rule that matters

**The revert must never be the thing that loses data.** Every DB operation is
therefore additive-then-swap: the dump is restored into a *side* database,
verified against recorded row counts, and only then renamed into place — and the
database being replaced is **renamed aside, not dropped**. There is always a
moment-by-moment answer to "where is the data right now", and it is never
"nowhere". Do not "simplify" this into `dropdb && pg_restore`.

## Layout

```
/opt/evelio-updating/
  updating-tooling/     this git repo (bin/, lib/, docs)
  src/                  private clone of app.evelio — ONLY this tool touches it
  releases/current/     THE backup. Exactly one. Replaced by each deploy.
  frontend-build.env    untracked; prod VITE_* build values
  logs/                 npm/migration logs
  .testvenv/            venv for the pre-deploy test gate
```

A release directory holds: `meta.env`, `MANIFEST` (sha256 per deployed backend
file), `backend/` (pre-deploy code snapshot), `frontend/webroot.tgz`,
`ingest/`, `caddy/Caddyfile`, `rowcounts.pre`, `db.dump`.

## Scripts

| script | what it does |
|---|---|
| `bin/adopt.sh` | one-time bootstrap: diffs live `/opt/tesla-oauth` against `origin/main`, shows every drift, and records the first baseline manifest once a human approves. Writes nothing to prod. |
| `bin/update.sh` | pre-flight → plan → confirm → backup → build → migrate → code → frontend → restart → verify. Dry-run unless `--apply`. |
| `bin/revert.sh` | restores the single kept release. Dry-run unless `--apply`. |
| `bin/status.sh` | what's deployed, what the backup holds, drift, kept aside-databases. |
| `lib/db-restore.sh` | `restore_db_swap()` — the database half of a revert, isolated so it can be rehearsed. |
| `lib/run-tests.sh` | pre-deploy test gate against a throwaway DB in the **staging** container. |
| `lib/selftest.sh` | rehearses `restore_db_swap()` against the staging container. Run it after touching anything in the revert path. |

## Hard constraints for anyone (human or Claude) editing this repo

- **DRY-RUN IS THE DEFAULT.** `update.sh` and `revert.sh` print and exit unless
  `--apply`. Same convention as the staging tooling — deliberately, so muscle
  memory transfers.
- **The backup is taken before the first prod mutation, and verified.** `pg_dump`
  runs, is copied out, and is read back with `pg_restore --list` *before* any
  migration runs. If that verification fails the deploy aborts having changed
  nothing. Never move the backup step later "for speed".
- **Only ONE release is kept** (the human chose this). `update.sh` therefore
  builds the new backup completely in `releases/new.$$`, and only then removes
  the old one and renames the new into place — there is never a window with zero
  backups. It also warns explicitly, before doing anything, that the previous
  backup will be destroyed. Keep both properties.
- **`revert.sh` never drops the live database.** Side-restore → verify row counts
  → `ALTER DATABASE evelio RENAME TO evelio_prerevert_<ts>` → rename the restored
  copy into place. If the second rename fails, it renames the original back and
  aborts. The aside copy is retained until a human runs
  `status.sh --prune-aside`. This is what makes a revert itself revertible.
- **Never auto-revert the database.** A failed deploy rolls back *code* on its
  own. For the database it prompts (`ROLLBACK_PROMPT_TIMEOUT`, **300s**) and, on
  timeout or with no TTY, takes the code-only branch and says loudly that the DB
  was not reverted. An unattended process must never decide by itself to rewind
  production data.
- **Migrations run before code, and are never undone.** All `migrate_*.sql` are
  replayed each deploy (they are idempotent `CREATE … IF NOT EXISTS` by the app's
  convention). `revert.sh --code-only` leaves the added columns in place — old
  code ignores them. Only the full DB restore rewinds the schema, and it does so
  by restoring a whole database, never by `DROP`ping anything in the live one.
  Ordering caveat: files are applied in the order git first added them, the same
  heuristic (and the same sharp edge) documented in the staging tooling.
- **Drift check is a gate, not a warning.** If any file in `/opt/tesla-oauth`
  differs from the last deploy's manifest, `update.sh` refuses. The run-dir is
  not git-tracked and has historically absorbed hand-edits; deploying over one
  silently reverts a hotfix. Resolve by merging the change into main, or
  re-baselining with `adopt.sh --apply`.
- **The PROTECTED list is load-bearing.** `tokens/` (live Tesla OAuth tokens),
  `.venv/`, `*.env`, `pending_registrations.json`, `_bak_archive/`, `*.bak.*` are
  never mirrored, never deleted, never counted as drift. A "true mirror" that
  deletes anything not in git would delete the OAuth tokens. Files unknown to git
  and not protected are **reported, never removed**.
- **`origin/main` tip only.** Resolved as the remote ref explicitly — a bare
  `main` resolves to a local branch that `git fetch` never advances, which is the
  stale-checkout trap the staging tooling documents. There is intentionally no
  `--ref`: production runs what main says.
- **`lib/selftest.sh` is the proof, and it must stay green.** It runs the real
  `restore_db_swap()` against the staging container and asserts: a good dump
  restores exactly; the pre-revert data is kept; a row-count mismatch aborts with
  the live DB untouched; a truncated dump aborts with the live DB untouched; and
  a soft dump preserves telemetry. It found a real bug during development — a
  `docker exec -i` inside the verification's `while read` loop was eating the
  loop's own stdin, so all but the first table went unverified and the swap
  proceeded on a check that had not run. That is why the verifier now reads its
  input into an array, passes `</dev/null` to the inner command, and **refuses to
  swap if it verified zero tables**. Run `sudo lib/selftest.sh` after any change
  to the revert path.
- **The test gate is a REGRESSION gate, not a pass/fail gate.** As of 2026-08-07,
  9 of the app's 14 test files fail on `main` for pre-existing reasons. A gate
  that blocks every deploy would be bypassed with `--skip-tests` every time and
  would protect nothing. So the failing set is recorded in
  `$UPD_ROOT/tests.baseline` on the first `--apply`, and the gate blocks only when
  a file that used to pass starts failing. A newly-passing file tightens the
  baseline automatically. Do not "fix" this by making it strict again unless the
  suite is green.
- **Tests run one process per file.** Several of the app's test modules stub each
  other in `sys.modules` (fake `auth`, `agreement`), so a single pytest process
  fails on pollution alone — on files that pass fine in isolation. Do not merge
  them back into one invocation.
- **Comparisons must ignore line endings.** The live run-dir holds **CRLF** files
  (deployed from a Windows checkout); the repo is LF. Every diff, drift check and
  manifest hash goes through `norm_cat`/`norm_sha`/`same_content`. Without this,
  every file reads as changed and the drift gate is pure noise. Relatedly, the
  MANIFEST is written **from `$BACKEND_DIR` after the copy**, not from the repo —
  the two differ whenever normalisation kicked in, and a manifest that doesn't
  describe what is actually on disk makes the next deploy see phantom drift.
- **A revert rewrites the MANIFEST too.** Otherwise the next `update.sh` would see
  the whole rollback as drift and refuse.
- **The test gate never talks to prod.** It runs against a throwaway DB in
  `telemetry-postgres-staging` (`:5433`) *and* installs a `.pth` guard in the test
  venv that wraps `psycopg2.connect` and exits 3 on port 5432 / db `evelio` /
  non-local host — because several app modules default to prod when `PG_*` is
  unset. Env vars are not a boundary. It must stay a `.pth` (Debian's
  `sitecustomize.py` shadows a venv-local one).
- **Never commit a rendered `frontend-build.env`, a dump, a release dir, or any
  secret.** Only the template is tracked. The tool reads the *names* of env keys
  from `/etc/tesla-oauth.env` for its pre-flight check and never their values.
- **The bundle is verified before publishing.** The built assets must contain the
  configured prod API base and must not reference a dev/staging host; a
  Cloudflare *testing* sitekey (`1x…/2x…/3x…`) is rejected outright. Staging uses
  testing keys on purpose — one leaking into a prod build means the captcha
  verifies nothing.
- **`legal/` in the webroot is not ours.** Published agreement PDFs live in
  `/var/www/evelio-app/legal` and are not in the app repo. The frontend publish
  removes `assets/` and copies `dist/` over the top; it must never `rm -rf` the
  whole webroot. (The revert restores the webroot from its own snapshot, which
  does include `legal/` as it was.)
- **Agreement publishing (`DEPLOY.md` §D) is deliberately out of scope.** It
  emails every user. A deploy tool must not do that as a side effect.
- **Caddy is opt-in (`--with-caddy`) and always backup → `caddy validate` →
  reload.** If validate fails the old config keeps running.
- **Never add any of this to a timer, cron, or `systemctl enable`.** Deploys are
  deliberate manual acts, same as the parent stack.

## What a revert can and cannot undo

Can: backend code, `fetch_odometer.py`, the whole webroot, the Caddyfile (if it
was deployed by the same run), and — on the default path — the entire database
including schema and telemetry.

Cannot: anything outside those. Specifically **emails already sent**, Tesla API
calls already made, tokens already refreshed on disk, and any write a *third*
system made in response to the new code. State that plainly rather than implying
the revert is total.

Also note the cost that is inherent, not a bug: a full DB restore rewinds
`telemetry_raw` to the backup, so telemetry ingested since the deploy is
discarded. `revert.sh` prints the exact per-table row delta and requires
`REVERT-DATABASE` to be typed. `--code-only` avoids it entirely and loses
nothing. `--soft-db-backup` at deploy time skips telemetry rows in the dump; the
revert then copies the *live* telemetry across into the restored database before
the swap, so telemetry survives — at the cost of several minutes of downtime.

## Relationship to the staging tooling

Different repos, different rules, one shared idea: **guards live in code, not in
a README.** If you find another way for this tool to damage prod, block it in
`lib/common.sh` and note it here — do not just write a warning.
