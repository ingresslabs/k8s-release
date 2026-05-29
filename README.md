# K8s Release

K8s Release builds verifiable DEB and RPM packages for Kubernetes, etcd,
Flannel, Calico, and certificates. It is aimed at private, regulated, and
air-gapped environments where operators need more than binaries: they need
reproducible outputs, signed repositories, and evidence that the packages can
be installed and checked later.

For each supported version, the project can produce:

- DEB and RPM packages
- Signed apt and yum repositories
- Checksums and release manifests
- SPDX SBOMs and Sigstore bundles
- Release evidence and a release passport
- An offline airgap bundle

Basic usage:

```bash
make build PACKAGE_TYPE=all
```

Build one component:

```bash
./k8s-release build v1.36.1 --component kubelet --format deb,rpm
```

Verify a release:

```bash
./k8s-release verify-release v1.36.1 --repo kubekattle/k8s-release
```

Create and verify an airgap bundle:

```bash
./k8s-release bundle v1.36.1 --airgap
./k8s-release verify-bundle k8s-v1.36.1-airgap.tar
```

Generate a release passport:

```bash
./k8s-release passport v1.36.1
```

Project metadata:

Version: `1.0.0`

Spec: `docs/world-class-release-spec.md`

Release policy: `docs/release-policy.md`

License: GPL-3.0
