#!/usr/bin/env bash
# Runs the real scope, attested and carry-forward steps of claude-review.yml against a stub
# `gh` serving fixture JSON, and asserts the resulting review mode.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 -I - "${WORKFLOW:-$root/.github/workflows/claude-review.yml}" "$work/step" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = {s["name"]: s["run"] for s in wf["jobs"]["claude-review"]["steps"] if "run" in s}
steps.update({s["name"]: s["run"] for s in wf["jobs"]["resolve-pr"]["steps"] if "run" in s})
for name, key in (("Plan review scope", "scope"), ("Approve from local review attestation", "attested"),
                  ("Carry forward prior approval", "carry"), ("Resolve pull request", "resolve")):
    open(sys.argv[2] + "." + key, "w").write(steps[name])
PY

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${PR_JSON:-}" ]]; then echo "$PR_JSON"; exit 0; fi
case "$*" in
  *"-X POST"*) echo "$*" >> "$GH_LOG" ;;
  *"api graphql"*) cat "$FIXTURE"; [[ -z "${GRAPHQL_FAIL:-}" ]] || exit 1 ;;
  *"/reviews?"*) echo "${REVIEWS:-[]}" ;;
  *"head.sha"*) echo "${LIVE_HEAD:-}" ;;
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
    GH_LOG="$work/ghlog" REVIEWS="${REVIEWS:-[]}" PR_NUMBER=7 HEAD_SHA="$head" CI_GATES_PASSED=false \
    LOCAL_REVIEW_ATTESTERS="$3" LABEL_REREVIEW="${4:-false}" GRAPHQL_FAIL="${5:-}" \
    bash "$work/step.scope" >/dev/null 2>"$work/err") || { echo "FAIL $name: step errored"; cat "$work/err"; fail=1; return; }
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

fixture "$(nodes dwoolworth User "" "$good")"
REVIEWS="$(jq -nc --arg h "$head" '[[{user:{login:"bot[bot]"},submitted_at:"2026-01-01T00:00:00Z",state:"CHANGES_REQUESTED",commit_id:$h,body:"VERDICT: BLOCK"}]]')" \
  run "attested outranks prior CHANGES_REQUESTED" attested dwoolworth

post() { # name step live_head want_post(1|0) want_rc
  local name="$1" step="$2" live="$3" want="$4" wantrc="$5" rc=0 posts
  : > "$work/ghlog"
  rm -rf "$work/ws"; mkdir -p "$work/ws/.claude-review"
  echo '{"findings":[]}' > "$work/ws/.claude-review/prior-findings.json"
  : > "$work/ws/.claude-review/incremental-files.txt"
  (cd "$work/ws" && PATH="$work/bin:$PATH" GH_LOG="$work/ghlog" LIVE_HEAD="$live" \
    GITHUB_REPOSITORY=o/r PR_NUMBER=7 HEAD_SHA="$head" ATTESTER=dwoolworth ATTEST_URL=u \
    PREV_SHA="$other" DELTA_LINES=1 MAX_LINES=300 \
    bash "$work/step.$step" >/dev/null 2>&1) || rc=$?
  posts="$(grep -c "commit_id=$head .*event=APPROVE" "$work/ghlog" || true)"
  if [[ "$posts" == "$want" && ( ( "$wantrc" == 0 && "$rc" == 0 ) || ( "$wantrc" != 0 && "$rc" != 0 ) ) ]]; then
    echo "ok   $name"
  else echo "FAIL $name: posts=$posts rc=$rc"; fail=1; fi
}
post "attested approval pins commit_id"        attested "$head"  1 0
post "attested aborts when head moved"         attested "$other" 0 1
post "carry-forward approval pins commit_id"   carry    "$head"  1 0
post "carry-forward aborts when head moved"    carry    "$other" 0 1

resolve() { # name actor secrets_present want_rc want_can_review
  local name="$1" rc=0 got
  : > "$work/out"
  PATH="$work/bin:$PATH" GITHUB_OUTPUT="$work/out" GITHUB_REPOSITORY=o/r PR_NUMBER=7 \
    PR_JSON='{"number":7,"head":{"sha":"abc"},"user":{"login":"dependabot[bot]"},"base":{"ref":"main"},"draft":false}' \
    ACTOR="$2" SECRETS_PRESENT="$3" bash "$work/step.resolve" >/dev/null 2>&1 || rc=$?
  got="$(sed -n 's/^can_review=//p' "$work/out")"
  if [[ ( "$4" == 0 && "$rc" == 0 || "$4" != 0 && "$rc" != 0 ) && "$got" == "$5" ]]; then
    echo "ok   $name"
  else echo "FAIL $name: rc=$rc can_review=$got"; fail=1; fi
}
resolve "dependabot run without secrets skips"   'dependabot[bot]' false 0 false
resolve "dependabot run with secrets reviews"    'dependabot[bot]' true  0 true
resolve "human run without secrets fails"        alice             false 1 ""
resolve "human run with secrets reviews"         alice             true  0 true

exit "$fail"
