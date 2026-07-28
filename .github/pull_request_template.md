## Summary

-

## Validation

- [ ] `ruby test`
- [ ] `ruby scripts/validate_sites.rb`
- [ ] `ruby scripts/check_agent_diff.rb`

## Agent-created PR checklist

- [ ] Source Issue was created by the repository owner and has the `approved` label.
- [ ] Base branch is `jekyll`.
- [ ] Changes are limited to the workflow allowlist (`_data/sites.yml`, `assets/image/logo/`, and agent metadata where applicable).
- [ ] No deployment credential, including `TOKEN`, was read, printed, or modified.
- [ ] The PR title and commit message are deterministic and reference the source Issue.
