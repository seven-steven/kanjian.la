You maintain the navigation data for this repository.

Read and obey `.github/prompts/navigation-agent-policy.md` before taking any action.

The triggering Issue is #${{ github.event.issue.number }}. Extract only the submitted navigation fields. Add or update the corresponding entry in `_data/sites.yml`, and optionally fetch exactly one logo with `ruby scripts/fetch_logo.rb` into `assets/image/logo/` when needed.

Before committing, run:

1. `ruby test`
2. `ruby scripts/validate_sites.rb`
3. `ruby scripts/check_agent_diff.rb`
4. `git diff --check`

If validation fails, do not commit or create a PR; report the failure in the Issue. If the diff includes a path outside `_data/sites.yml` or `assets/image/logo/`, stop without committing.

Commit exactly once with `chore(navigation): process issue #${{ github.event.issue.number }}`. Push only the newly created `claude/navigation-*` branch, then open or update a PR targeting `jekyll` with the same deterministic title and `Closes #${{ github.event.issue.number }}`. Never push directly to `jekyll` or an existing branch.
