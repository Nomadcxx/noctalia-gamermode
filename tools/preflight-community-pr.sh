#!/usr/bin/env bash
# Pre-flight for a community-plugins PR.
#
# Runs the upstream repo's OWN gates locally, against the exact ref the PR will
# target, before anything is opened. PR #330 was auto-closed because its body was
# written against a PR template read from a stale fork checkout; this script reads
# every rule from upstream/main instead, so that class of failure cannot recur.
#
#   ./tools/preflight-community-pr.sh <path-to-community-plugins-checkout> <pr-body.md>
#
# Exits non-zero if anything the bot checks would fail.
set -uo pipefail

CP="${1:?usage: preflight-community-pr.sh <community-plugins-checkout> <pr-body.md>}"
BODY="${2:?usage: preflight-community-pr.sh <community-plugins-checkout> <pr-body.md>}"
PLUGIN_DIR="gamer-mode"
fail=0
note() { printf '%-14s %s\n' "$1" "$2"; }

cd "$CP" || exit 2

# The gates must come from upstream, not from whatever the fork last synced.
git fetch -q upstream 2>/dev/null || { note "FETCH" "cannot reach upstream remote"; exit 2; }

# 1. PR body against the enforcement script, using upstream's copy of both.
git show upstream/main:.github/workflows/scripts/enforce-pr-template.py > /tmp/_enforce.py 2>/dev/null \
  || { note "ENFORCE" "upstream has no enforcement script at the expected path"; fail=1; }
if [ -s /tmp/_enforce.py ]; then
  out=$(python3 - "$BODY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("enf", "/tmp/_enforce.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
missing = m.missing_requirements(open(sys.argv[1]).read())
print("\n".join(missing))
PY
)
  if [ -n "$out" ]; then
    note "ENFORCE" "FAIL — the bot would close this PR:"
    printf '%s\n' "$out" | sed 's/^/               - /'
    fail=1
  else
    note "ENFORCE" "pass — body carries the marker, headings, fields and checklist"
  fi
fi

# 2. Manifest/content validation. The validator derives the repo root from its own
#    path, so it has to run from inside the checkout -- but the checkout's copy could be
#    stale, which is the exact trap that sank #330. So diff it against upstream first and
#    refuse to trust a copy that has drifted.
VAL=.github/workflows/scripts/validate-plugins.py
if ! git show "upstream/main:$VAL" > /tmp/_validate_upstream.py 2>/dev/null; then
  note "VALIDATE" "FAIL — upstream has no validator at $VAL"; fail=1
elif ! cmp -s /tmp/_validate_upstream.py "$VAL"; then
  note "VALIDATE" "FAIL — local $VAL differs from upstream/main; rebase onto upstream/main"; fail=1
elif python3 "$VAL" >/tmp/_validate.out 2>&1; then
  note "VALIDATE" "pass — $(tail -1 /tmp/_validate.out)"
else
  note "VALIDATE" "FAIL:"; sed 's/^/               /' /tmp/_validate.out; fail=1
fi

# 3. Scope: exactly one plugin directory, and never catalog.toml.
changed=$(git diff --name-only upstream/main...HEAD)
dirs=$(printf '%s\n' "$changed" | cut -d/ -f1 | sort -u)
if [ "$dirs" != "$PLUGIN_DIR" ]; then
  note "SCOPE" "FAIL — touches more than $PLUGIN_DIR:"; printf '%s\n' "$dirs" | sed 's/^/               /'; fail=1
else
  note "SCOPE" "pass — only $PLUGIN_DIR/"
fi
if printf '%s\n' "$changed" | grep -qx "catalog.toml"; then
  note "CATALOG" "FAIL — catalog.toml is CI-generated and must never be committed"; fail=1
else
  note "CATALOG" "pass — untouched"
fi

# 4. Version must be bumped against what upstream currently ships.
new=$(grep -m1 '^version' "$PLUGIN_DIR/plugin.toml" | cut -d'"' -f2)
old=$(git show "upstream/main:$PLUGIN_DIR/plugin.toml" 2>/dev/null | grep -m1 '^version' | cut -d'"' -f2)
if [ -z "$old" ]; then
  note "VERSION" "new plugin — $new"
elif [ "$new" = "$old" ]; then
  note "VERSION" "FAIL — still $old; every change needs a bump"; fail=1
else
  note "VERSION" "pass — $old -> $new"
fi

# 5. Required files.
for f in plugin.toml README.md thumbnail.webp translations/en.json; do
  [ -f "$PLUGIN_DIR/$f" ] || { note "FILES" "FAIL — missing $f"; fail=1; }
done
[ "$fail" -eq 0 ] && note "FILES" "pass — manifest, README, thumbnail and en.json present"

echo
[ "$fail" -eq 0 ] && echo "PRE-FLIGHT PASSED — safe to open the PR" || echo "PRE-FLIGHT FAILED — do not open the PR"
exit "$fail"
