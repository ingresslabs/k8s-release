# K8s Release

K8s Release builds verifiable, reproducible, airgap-ready DEB and RPM packages
for Kubernetes, etcd, Flannel, and Calico.

## Why This Exists

Running Kubernetes from packages is still common in real operations: regulated
platforms, private clouds, edge environments, bare-metal clusters, disconnected
sites, and teams that need explicit control over every binary installed on a
node. Those users do not only need packages. They need proof.

A Kubernetes node package is part of the control plane supply chain. If an
operator cannot prove where it came from, which source revision produced it,
which container image built it, which dependencies were present, whether another
runner can rebuild the same artifact, and whether the final package was signed
by the expected workflow, then the package is difficult to defend in production.
That is especially true in air-gapped and regulated environments where artifacts
are imported once, copied widely, and audited later.

This project exists to make that trust contract concrete. A release is not just
a collection of `.deb` and `.rpm` files. It is a complete evidence set: pinned
inputs, deterministic rebuild checks, install smoke tests, node startup checks,
SBOMs, provenance, Sigstore signatures, signed apt/yum repository metadata,
release evidence, a release passport, and an offline bundle that can be verified
before import.

The intended users are platform teams, SRE groups, distribution builders,
security reviewers, and infrastructure vendors who need Kubernetes packages
that can survive change control, incident review, and later audit. The goal is
not to replace upstream Kubernetes. The goal is to make packaged Kubernetes
artifacts easier to trust, mirror, install, and explain.

## What It Produces

For each supported Kubernetes version, the project can produce:

- DEB and RPM packages for core Kubernetes components.
- Packages for etcd, Flannel, Calico, and certificate material.
- Signed apt and yum repository metadata.
- Package checksums and release manifests.
- SPDX SBOMs.
- Sigstore bundle signatures.
- GitHub provenance attestations.
- A release evidence file linking source refs, versions, tests, and artifacts.
- A release passport with install commands, checksums, evidence inventory,
  supported OS matrix, rebuild status, and L4/upgrade evidence status.
- An airgap bundle containing packages, repositories, install helpers,
  verification policy, and bundle-level checksums.

Certificate packages are intentionally non-deterministic because they contain
fresh key material. The release checks keep that exception explicit rather than
hiding it inside the reproducibility story.

## Basic Usage

Build all package formats:

```bash
make build PACKAGE_TYPE=all
```

Build one component for a selected version:

```bash
./k8s-release build v1.32.2 --component kubelet --format deb,rpm
```

Verify a published release:

```bash
./k8s-release verify-release v1.32.2 --repo kubekattle/k8s-release
```

Create and verify an offline bundle:

```bash
./k8s-release bundle v1.32.2 --airgap
./k8s-release verify-bundle k8s-v1.32.2-airgap.tar
```

Generate a release passport:

```bash
./k8s-release passport v1.32.2
```

## Release Bar

The current target is L4. A release is operationally complete only when a real
VM or kind-backed cluster installs from the signed repository or verified
airgap bundle, upgrades from the previous supported version when one exists,
runs conformance smoke tests, and records the evidence in the release passport.

CI currently proves pinned inputs, package reproducibility, clean installs,
node startup, SBOM generation, provenance, Sigstore signatures, signed
repository metadata, release evidence, release passport generation, and offline
airgap bundle verification.

## Project Metadata

Version: `1.0.0`

Spec: `docs/world-class-release-spec.md`

Release policy: `docs/release-policy.md`

License: GPL-3.0
