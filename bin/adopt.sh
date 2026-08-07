#!/usr/bin/env bash
#
# adopt.sh — ONE-TIME bootstrap.
#
# /opt/tesla-oauth is not git-tracked and has drifted from main over the years
# (hand-edited files, .bak.* leftovers, files that exist only on the server).
# update.sh refuses to run without a baseline manifest to compare against, so
# this script builds that baseline — but only after showing you, file by file,
# exactly how the live run-dir differs from origin/main.
#
# It writes NOTHING to production. Its only side effects are inside
# /opt/evelio-updating: the private clone and releases/current/.
#
#   sudo bin/adopt.sh              # show the drift report, change nothing
#   sudo bin/adopt.sh --apply      # after reviewing: record the baseline
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/lib/common.sh"

APPLY=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done

assert_root
assert_prod_layout

hdr "Evelio prod updater — bootstrap (adopt current production as the baseline)"
(( APPLY )) || log "${C_YEL}DRY RUN${C_OFF} — nothing will be written. Re-run with --apply to record the baseline."

# ------------------------------------------------------- 1. private clone --
hdr "1. Private clone of the app repo"
if [[ -d "$SRC_REPO/.git" ]]; then
  ok "clone exists at $SRC_REPO"
  run git -C "$SRC_REPO" fetch --prune origin
else
  info "cloning $GIT_URL -> $SRC_REPO"
  run git clone "$GIT_URL" "$SRC_REPO"
fi

if [[ ! -d "$SRC_REPO/.git" ]]; then
  warn "no clone yet (dry run) — the drift report below cannot be produced."
  log "Run: sudo $0 --apply   (it will clone, then show the report before writing anything else)"
  exit 0
fi

# Always resolve the REMOTE ref explicitly. A bare 'main' would resolve to a
# local branch that git fetch never advances — the stale-checkout trap.
info "checking out $GIT_REF"
git -C "$SRC_REPO" fetch --prune origin >/dev/null 2>&1 || die "git fetch failed (SSH key?)"
git -C "$SRC_REPO" checkout -q --detach "$GIT_REF" || die "cannot check out $GIT_REF"
COMMIT="$(git -C "$SRC_REPO" rev-parse HEAD)"
ok "$GIT_REF = ${COMMIT:0:8}  $(git -C "$SRC_REPO" log -1 --format=%s)"

# ------------------------------------------------------- 2. drift report --
hdr "2. Drift: live $BACKEND_DIR  vs  $GIT_REF"

mapfile -t FILES < <(backend_deploy_files "$SRC_REPO")
(( ${#FILES[@]} )) || die "no deployable files found in the repo — refusing."

same=0; differs=(); missing_live=();
for f in "${FILES[@]}"; do
  if [[ ! -e "$BACKEND_DIR/$f" ]]; then
    missing_live+=("$f")
  elif same_content "$BACKEND_DIR/$f" "$SRC_REPO/$f"; then
    (( ++same ))
  else
    differs+=("$f")
  fi
done

# Files living in the run-dir that git does not know about and that are not on
# the protected list. These are the ones a human must classify.
unknown=()
while IFS= read -r -d '' p; do
  rel="${p#"$BACKEND_DIR"/}"
  is_protected "$rel" && continue
  printf '%s\n' "${FILES[@]}" | grep -qxF "$rel" && continue
  unknown+=("$rel")
done < <(find "$BACKEND_DIR" -mindepth 1 -maxdepth 1 -print0)

log "  identical to main : $same"
log "  differ from main  : ${#differs[@]}"
log "  missing on server : ${#missing_live[@]}"
log "  unknown to git    : ${#unknown[@]}"

if (( ${#differs[@]} )); then
  hdr "Files that DIFFER (live -> main). Read these: they are your server-side hotfixes."
  for f in "${differs[@]}"; do
    log "${C_BLD}--- $f ---${C_OFF}"
    diff -u <(norm_cat "$BACKEND_DIR/$f") <(norm_cat "$SRC_REPO/$f") \
      --label "LIVE  $f" --label "MAIN  $f" | head -60 || true
    log ""
  done
fi
if (( ${#missing_live[@]} )); then
  hdr "In main but NOT deployed (the first update.sh will ADD these):"
  printf '  %s\n' "${missing_live[@]}"
fi
if (( ${#unknown[@]} )); then
  hdr "Live files git does not know about (never deleted; classify them):"
  for f in "${unknown[@]}"; do log "  $f"; done
  log ""
  log "If any of these is real code you rely on, get it into the repo — otherwise"
  log "it will never be updated, and a future run-dir rebuild would not recreate it."
fi

# ------------------------------------------------------- 3. write baseline --
hdr "3. Record the baseline"

if (( ! APPLY )); then
  log "${C_YEL}DRY RUN${C_OFF} — no baseline written."
  log "Review the diffs above. When you are satisfied that everything live is"
  log "either (a) also in main, or (b) intentionally server-only, run:"
  log "    sudo $0 --apply"
  exit 0
fi

if (( ${#differs[@]} )); then
  log ""
  warn "${#differs[@]} live file(s) differ from main."
  log "Adopting means: 'the code running right now is my baseline.' The next"
  log "update.sh will OVERWRITE these with main's version (after backing them up)."
  log "If any diff above is a hotfix that is NOT in main, stop and merge it first —"
  log "otherwise the next deploy silently reverts that fix."
  confirm "" "ADOPT" || die "aborted — nothing written."
fi

mkdir -p "$RELEASE_DIR" "$LOG_DIR"

# The baseline manifest describes what is LIVE right now, not what main holds.
sha_dir_manifest "$BACKEND_DIR" "${FILES[@]}" > "$RELEASE_DIR/MANIFEST"
if [[ -f "$INGEST_DIR/fetch_odometer.py" ]]; then
  sha_dir_manifest "$INGEST_DIR" fetch_odometer.py > "$RELEASE_DIR/MANIFEST.ingest"
fi

cat > "$RELEASE_DIR/meta.env" <<EOF
# Baseline recorded by adopt.sh — NOT a real release.
RELEASE_ID=baseline-$(now_id)
RELEASE_KIND=baseline
# What production is running right now (unknown: the run-dir predates this tool).
RUNNING_COMMIT=unknown
# What a revert would go back to. A baseline has nothing to revert to.
PREV_COMMIT=unknown
CREATED_AT=$(date -u +%FT%TZ)
HAS_DB_DUMP=0
DB_DUMP_MODE=none
EOF

ok "baseline manifest written to $RELEASE_DIR"
log ""
log "There is NO database backup in a baseline — adopt.sh never touches the DB."
log "The first real 'update.sh --apply' takes one before it changes anything."
log ""
log "Next: sudo bin/update.sh            (dry run — shows the full plan)"
