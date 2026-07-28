## Summary

-

## Validation

- [ ] `find test -type f -name '*_test.rb' -print0 | sort -z | xargs -0 -r -n1 ruby`
- [ ] `ruby scripts/validate_sites.rb`
- [ ] `ruby scripts/check_agent_diff.rb --base origin/jekyll`（仅 agent PR）

## Agent-created PR checklist

- [ ] Source Issue was created by the repository owner and has the `navigation-request` and `agent:approved` labels.
- [ ] Base branch is `jekyll`.
- [ ] Changes are limited to the workflow allowlist (`_data/sites.yml` and direct children of `assets/image/logo/`).
- [ ] No deployment credential, including `TOKEN`, was read, printed, or modified.
- [ ] The PR title and commit message are deterministic and reference the source Issue.
