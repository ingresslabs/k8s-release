# Repo Rules

- Keep only long-lived `devel` and `main` branches.
- Work may happen on short-lived branches, but every finished change must be
  committed and tested on `devel` before the work branch is deleted.
- Merge `devel` into `main` only after the user explicitly approves that merge.
- Keep `devel` aligned with the latest tested work so it remains the integration
  branch for the next change.
- Never hard-code sensitive host data such as IP addresses, SSH targets, or
  machine-specific paths in tracked repo files.
- Store repo-local sensitive or host-specific values in ignored `.env` files
  instead of hard-coding them or putting them in HashiCorp Vault for this repo.
