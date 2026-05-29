# Release Policy

Project releases start at `1.0.0`.

Use semantic versioning for the project itself:

- Major: release model, artifact format, verification contract, repository layout, or compatibility break changes.
- Minor: backwards-compatible features, supported version matrix expansion, or new checks.
- Patch: fixes, documentation, and CI hardening that do not change the public contract.

## Branch Rule

Keep only long-lived `main`, `devel`, and `master` branches when they exist.
Work may happen on short-lived branches, but tested work must be merged into `main` before the work branch is deleted.
Keep `devel` aligned with tested work so it remains the integration branch for
the next change.

For every major project change:

```bash
make bump-major
git tag -a "project-v$(cat VERSION)" -m "Project release $(cat VERSION)"
git push origin "project-v$(cat VERSION)"
```

Package release tags use Kubernetes versions such as `v1.36.1`. Project
release tags use `project-v*` so project versions do not collide with
Kubernetes package versions.
