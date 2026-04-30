# World-Class Release Spec

This project is world-class when a user can prove where every package came from,
install it directly from signed repositories or an offline bundle, and verify
that a clean runner can rebuild the same deterministic artifacts.

The headline release bar is L4: a release is not operationally complete until a
real VM or kind-backed cluster installs from the signed repository, upgrades from
the previous supported version when one exists, and records conformance smoke
evidence in the release passport.

The one-command proof entry point is:

```bash
./k8s-release prove v1.32.2 --previous v1.32.1 --policy docs/release-proof-policy.example.yaml
```

The proof command must fail if signed-repository install, airgap install,
cluster smoke, upgrade and rollback smoke, machine-readable proof JSON,
replayable proof signatures, or release passport generation fails.

Replayable audit verification is:

```bash
./k8s-release verify-proof release-artifacts/release-proof.json
```

Airgap import is a local ceremony:

```bash
./k8s-release airgap prepare v1.32.2 --require-l4 --require-upgrade
./k8s-release airgap verify k8s-v1.32.2-airgap.tar
./k8s-release airgap import k8s-v1.32.2-airgap.tar --repo /mnt/mirror
```

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
12. Every release publishes a release passport with install commands, package
    checksums, SBOMs, provenance, signatures, rebuild proof, conformance status,
    supported OS matrix, and upgrade evidence status.
13. Every release publishes an airgap bundle containing packages, signed package
    repositories, repository metadata, signatures, SBOMs, provenance evidence,
    install helpers, a verification policy, and bundle-level checksums.
14. The airgap bundle verifies offline and can optionally perform online
    GitHub attestation and keyless identity verification before import.
15. L4 release evidence records signed-repository install, upgrade, and
    conformance smoke results for the supported OS matrix.

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
|L4|A real VM/kind cluster installs from the signed repo or verified airgap bundle, upgrades across versions, runs conformance smoke tests, and publishes a release passport.|

Current target: L4.
