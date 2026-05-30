# Release Policy

Project releases start at `1.0.0`.

Use semantic versioning for the project itself:

- Major: release model, artifact format, verification contract, repository layout, or compatibility break changes.
- Minor: backwards-compatible features, supported version matrix expansion, or new checks.
- Patch: fixes, documentation, and CI hardening that do not change the public contract.

## Branch Rule

Keep only long-lived `devel` and `main` branches.
Work may happen on short-lived branches, but every finished change must be
committed and tested on `devel` before the work branch is deleted.
Merge `devel` into `main` only after the user explicitly approves that merge.
Keep `devel` aligned with the latest tested work so it remains the integration
branch for the next change.
Never hard-code sensitive host data such as IP addresses, SSH targets, or
machine-specific paths in tracked repo files.
Store repo-local sensitive or host-specific values in ignored `.env` files
instead of hard-coding them or putting them in HashiCorp Vault for this repo.

For every major project change:

```bash
make bump-major
git tag -a "project-v$(cat VERSION)" -m "Project release $(cat VERSION)"
git push origin "project-v$(cat VERSION)"
```

Package release tags use Kubernetes versions such as `v1.36.1`. Project
release tags use `project-v*` so project versions do not collide with
Kubernetes package versions.
