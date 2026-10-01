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
    secrets: inherit
    permissions:
      contents: read
      pull-requests: read
```

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

### Releasing changes

Callers pin `@v1`, so a prompt or model change reaches every repo when `v1` moves.

1. Merge the change to `main`.
2. Tag `v1.x.y`.
3. Move `v1`: `git tag -f v1 && git push -f origin v1`.

Breaking input changes go to `v2`.
