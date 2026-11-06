#!/usr/bin/env bash
# Runs the real "Plan review scope" step from claude-review.yml against a stub
# `gh` serving fixture JSON, and asserts the resulting review mode.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 -I - "${WORKFLOW:-$root/.github/workflows/claude-review.yml}" "$work/step.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"]["claude-review"]["steps"] if s.get("id") == "scope")
open(sys.argv[2], "w").write(step["run"])
PY

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"api graphql"*) cat "$FIXTURE"; [[ -z "${GRAPHQL_FAIL:-}" ]] || exit 1 ;;
  *"/reviews?"*) echo '[]' ;;
  *"/pulls/"*) echo "${LABEL_REREVIEW:-false}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"

head=1111111111111111111111111111111111111111
other=2222222222222222222222222222222222222222
fail=0

nodes() { # login type edited body
  jq -nc --arg l "$1" --arg t "$2" --arg e "$3" --arg b "$4" '
    {author:{__typename:$t,login:$l}, body:$b, createdAt:"2026-01-01T00:00:00Z",
     lastEditedAt:(if $e == "" then null else $e end), url:"https://example.test/c/1"}'
}
fixture() { jq -nc --argjson n "[$1]" '{data:{repository:{pullRequest:{comments:{nodes:$n}}}}}' > "$work/fixture.json"; }

run() { # name want attesters rereview graphql_fail
  local name="$1" want="$2" out
  : > "$work/out"; : > "$work/summary"
  rm -rf "$work/ws"; mkdir "$work/ws"
  (cd "$work/ws" && PATH="$work/bin:$PATH" FIXTURE="$work/fixture.json" \
    GITHUB_REPOSITORY=o/r REVIEW_BOT_LOGIN="bot[bot]" GITHUB_OUTPUT="$work/out" GITHUB_STEP_SUMMARY="$work/summary" \
    PR_NUMBER=7 HEAD_SHA="$head" CI_GATES_PASSED=false \
    LOCAL_REVIEW_ATTESTERS="$3" LABEL_REREVIEW="${4:-false}" GRAPHQL_FAIL="${5:-}" \
    bash "$work/step.sh" >/dev/null 2>"$work/err") || { echo "FAIL $name: step errored"; cat "$work/err"; fail=1; return; }
  out="$(sed -n 's/^mode=//p' "$work/out")"
  if [[ "$out" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: want $want got $out"; fail=1; fi
}

good="<!-- local-review head=$head model=m rounds=1 -->
## Local adversarial review"

fixture "$(nodes dwoolworth User "" "$good")"
run "valid, default attester"            attested dwoolworth
run "valid, attester case-insensitive"   attested "Other, DWoolworth"
run "label override"                     full dwoolworth true
run "attesters off"                      full off
run "attesters OFF (case)"               full OFF
run "login not allow-listed"             full someoneelse
run "lookup failure falls back"          full dwoolworth false 1

fixture "$(nodes dwoolworth User "2026-01-02T00:00:00Z" "$good")"
run "edited comment"                     full dwoolworth

fixture "$(nodes dwoolworth User "" "<!-- local-review head=$other model=m rounds=1 -->")"
run "wrong head"                         full dwoolworth

fixture "$(nodes dwoolworth User "" "x $good")"
run "marker not at start"                full dwoolworth

fixture "$(nodes dwoolworth User "" "<!-- local-review head=${head}abc model=m -->")"
run "head prefix is not a match"         full dwoolworth

fixture "$(nodes dwoolworth Bot "" "$good")"
run "bot author"                         full dwoolworth

fixture "$(nodes mallory User "" "$good"),$(nodes dwoolworth User "" "<!-- local-review head=$other -->")"
run "pasted marker by non-listed user"   full dwoolworth

exit "$fail"
