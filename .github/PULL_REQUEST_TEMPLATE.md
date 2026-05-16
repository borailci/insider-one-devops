## Summary

<!-- One or two sentences. What changed and why. -->

## Spec traceability

- Touches FR/NFR/AC: <!-- e.g. FR-1, AC-1, NFR-2 -->

## Checks

- [ ] `go test ./... -race -cover` passes locally
- [ ] `golangci-lint run` is clean
- [ ] `helm lint charts/app` is clean (if chart touched)
- [ ] Conventional commit subject (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `ci:`)
- [ ] No secrets, keys, or tokens in diff
- [ ] Docs updated if behavior changed
