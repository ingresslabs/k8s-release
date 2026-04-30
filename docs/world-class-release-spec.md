# World-Class Release Spec

This project is world-class when a user can prove where every package came from,
install it directly from signed repositories, and verify that a clean runner can
rebuild the same deterministic artifacts.

## Release Promise

Every supported Kubernetes version must satisfy these gates before release:

1. Inputs are pinned by digest, version, or immutable source reference.
2. Deterministic packages rebuild twice on separate GitHub runners with identical checksums.
3. Certificate and key packages are explicitly marked as intentionally non-deterministic.
4. DEB and RPM packages install in clean OS images.
5. Installed packages start core components in GitHub-hosted node smoke containers.
6. Signed apt and yum repository metadata is produced.
7. Every package has checksums, SBOM, provenance, and signature evidence.
8. Release evidence links source refs, image digests, versions, tests, and artifacts.
9. The CLI can build a single component for a selected Kubernetes version.
10. A version matrix proves the workflow across supported Kubernetes releases.
11. One command verifies checksums, SBOMs, signatures, provenance, source refs,
    and GitHub workflow identity for a release.

## Continuous Improvement Loop

Run this loop on every PR, on a schedule, and before every release:

```bash
make continuous-improvement
```

The loop produces `continuous-improvement-report.md`. A release is ready only
when the report has no failed gates and the GitHub package workflow is green:

```bash
./scripts/continuous-improvement.sh --strict --require-green-package-workflow
```

## Maturity Levels

|Level|Bar|
|---|---|
|L0|Packages build locally.|
|L1|CI builds all components and verifies package metadata.|
|L2|CI proves reproducibility, installability, SBOMs, signatures, and signed repos.|
|L3|CI starts installed packages, publishes release evidence, and supports one-command release verification.|
|L4|A real VM/kind cluster installs from the signed repo, upgrades across versions, and runs conformance smoke tests.|

Current target: L3. The next major jump is L4.
