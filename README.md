# ci-workflows

Shared GitHub Actions workflows for MnemoShare repositories.

## claude-review

`.github/workflows/claude-review.yml` is the org-wide Claude PR review. Each repo
keeps a small caller that decides **when** a review runs. This file decides
**how**: prompt, model, allowed tools, checkout, incremental re-review, and
posting.

### Adopting it

Copy [`templates/claude-code-review.yml`](templates/claude-code-review.yml) to
`.github/workflows/claude-code-review.yml`. Then adjust the `branches:` list and
`paths-ignore:` for the repo. Nothing else needs to change per repo.

To run the review only after the repo's own CI passes, call it as the last job of
the CI workflow:

```yaml
  claude-review:
    needs: [build, lint, test]
    if: github.event_name == 'pull_request'
    uses: MnemoShare/ci-workflows/.github/workflows/claude-review.yml@v1
    with:
      pr_number: ${{ github.event.pull_request.number }}
      ci_gates_passed: true
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      AUTO_APPROVE_PRIVATE_KEY: ${{ secrets.AUTO_APPROVE_PRIVATE_KEY }}
    permissions:
      contents: read
      pull-requests: read
```

Pass only the two secrets the review needs rather than `secrets: inherit`.
Callers pin the movable `v1` tag, and that tag shouldn't carry every org
secret with it.

### Inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `pr_number` | required | PR to review |
| `runner` | `ubuntu-latest` | Runner label. The runner needs `gh`, `jq` and `git` |
| `ci_gates_passed` | `false` | Tells the model CI already passed on this head, so it skips re-deriving build and test results |

### Repo-specific review rules

Put them in `.github/claude-review.md`. The workflow reads that file from the
PR's **base** branch and adds it to the prompt. Changes to the file take effect
only after they merge, so a PR can never rewrite the rules for its own review.

### Requirements (already set at org level)

- Org secret `ANTHROPIC_API_KEY`
- Org secret `AUTO_APPROVE_PRIVATE_KEY` and org variable `AUTO_APPROVE_APP_CLIENT_ID`
  for the `mnemoshare-auto-approve` GitHub App. The App is installed on all repos,
  and reviews post as `mnemoshare-auto-approve[bot]`.
- Branch protection on the target branch requires one approving review and
  dismisses stale approvals. The bot's formal review is the merge gate.
- Optional variable `LOCAL_REVIEW_ATTESTERS` (see Local-review attestations).

### Token scope (MSC-713)

The review agent processes untrusted PR content (diff, files, description) while
holding a token minted from the App. The App installation has
`contents: write`, `pull_requests: write` and `metadata: read` on every org
repo; `contents: write` exists for the `mnemoshare` repo's Dependabot auto-merge
and demo-to-dev backflow jobs, not for review. The review therefore narrows the
token it mints:

- `repositories:` limits it to the calling repository.
- `permission-contents: read` and `permission-pull-requests: write` are the only
  permissions on it; the token can post reviews and comments but cannot write
  contents, merge, or reach other repos.
- The agent's `gh api` grant is a single read-only endpoint,
  `repos/<repo>/pulls/<n>/files`. Never widen it back to `Bash(gh api:*)`:
  with a write-capable token that is a prompt-injection path to self-approval.

`gh pr review` and `gh pr comment` remain allowed because posting the formal
verdict is the bot's job; they only reach the PR under review.

### Local-review attestations

A local adversarial review can stand in for the hosted model run. The
`pr-attest` skill posts an issue comment that starts with
`<!-- local-review head=<full sha> model=... rounds=... -->`. When the comment
meets every condition below, the workflow approves that head as the App bot
("Approval from local review", quoting the comment link) and runs no model.
This "attested" mode outranks carry-forward and a full review.

- The author is a human (not a bot) listed in `LOCAL_REVIEW_ATTESTERS`.
- The comment starts with the marker and names exactly the PR head SHA being reviewed.
- The comment was never edited (`lastEditedAt` is null), since any write
  collaborator can edit another user's comment.
- The PR does not carry the `claude-rereview` label, which forces a hosted review.

A push after the attestation changes the head, so the attestation no longer
matches and the normal modes apply. If the lookup fails, the normal review runs.

`LOCAL_REVIEW_ATTESTERS` is an org or repo variable holding comma-separated
logins (case-insensitive). Default `dwoolworth`; `off` disables attestations; an
empty value falls back to the default. In a reusable workflow `vars` resolve in
the caller's context, so callers need no change: set the variable on the org or
the repo. The lookup reads comments through GraphQL with the job's read-only
`GITHUB_TOKEN` (`pull-requests: read`); no permission or tool grant changed.

Run the harness for this logic locally with `tests/attestation.sh` (needs
`python3` with PyYAML and `jq`); it executes the workflow's real scope step
against a stub `gh` and fixture comments.

### Releasing changes

Callers pin `@v1`, so a prompt or model change reaches every repo when `v1` moves.

1. Merge the change to `main`.
2. Tag `v1.x.y`.
3. Move `v1`: `git tag -f v1 && git push -f origin v1`.

Breaking input changes go to `v2`.
