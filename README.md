# K8s Release

Build Kubernetes release packages with Docker, Docker Compose, and Docker Buildx.

The project builds DEB/RPM packages for:

- Kubernetes components: `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `kube-proxy`, `kubelet`, `kubectl`
- etcd and `etcdctl`
- Flannel
- Calico
- generated Kubernetes certificates

## Quick Start

```bash
make check-tools
make build
```

Build RPMs:

```bash
make build PACKAGE_TYPE=rpm
```

Build both DEB and RPM packages:

```bash
make build PACKAGE_TYPE=all
```

Build one component:

```bash
make build-kubelet
make build-etcd
make build-calico PACKAGE_TYPE=rpm
```

Or use the small CLI:

```bash
./k8s-release build v1.32.2 --component kubelet --format deb,rpm
```

Packages are written to `output/`.

## Key Variables

|Variable|Default|Purpose|
|---|---:|---|
|`KUBE_VERSION`|`v1.32.2`|Kubernetes version to build.|
|`ETCD_VERSION`|`v3.5.9`|etcd version to build.|
|`FLANNEL_VERSION`|`v0.26.4`|Flannel version to build.|
|`CALICO_VERSION`|`v3.28.0`|Calico version to build.|
|`PACKAGE_TYPE`|`deb`|`deb`, `rpm`, or `all`.|
|`KUBE_BUILDER`|`0`|Use a Kubernetes Buildx builder named `kube-build-farm`.|
|`KUBE_BUILDER_ARM64`|`0`|Use a Kubernetes ARM64 Buildx builder named `kube-build-farm-arm64`.|
|`DEBIAN_SNAPSHOT`|`20260401T000000Z`|Debian snapshot used by `apt-get`.|
|`SOURCE_DATE_EPOCH`|latest commit time|Timestamp used to normalize package metadata.|

Build images are digest-pinned and can be overridden with:

- `KUBE_GO_IMAGE`
- `ETCD_GO_IMAGE`
- `FLANNEL_GO_IMAGE`
- `CALICO_GO_IMAGE`
- `RUNTIME_IMAGE`

## Supply Chain Checks

CI performs the release hardening checks that matter for these packages:

- verifies Docker build inputs are digest-pinned
- builds every component
- rebuilds a deterministic sample twice and compares checksums
- installs generated packages in clean DEB/RPM containers
- starts installed packages in GitHub-hosted node smoke containers
- verifies DEB/RPM metadata
- writes checksums and release manifests
- generates SPDX SBOMs
- creates GitHub artifact attestations
- signs packages with keyless Sigstore bundles
- creates signed apt/yum repository metadata
- publishes release assets, evidence, and an OCI repository bundle to GHCR
- certificate packages contain fresh key material, so their contents are intentionally unique per build

Run the local static check:

```bash
make check-pinned-inputs
```

Verify locally generated packages:

```bash
make verify-packages
make smoke-install-packages
make node-start-smoke
```

## GitHub Actions

- `Build Kubernetes Packages`: normal CI and manual builds.
- `Create Release`: runs on `v*` tags and uploads packages, checksums, SBOMs, and signatures to GitHub Releases.
- `Publish Packages`: manual package publishing with selectable component versions and package type.

Manual builds also accept `version_matrix`, a JSON array of Kubernetes/etcd/Flannel/Calico version sets.

## GHCR Bundle

Release and publish workflows push a compressed repository bundle as an OCI artifact:

```bash
oras pull ghcr.io/kubekattle/k8s-release/kubernetes-packages:1.32.2
tar -xzf kubernetes-package-repositories.tar.gz
sha256sum -c SHA256SUMS
```

## Kubernetes Buildx Builder

Create a Kubernetes-backed Buildx builder:

```bash
kubectl create namespace buildx

docker buildx create \
  --name kube-build-farm \
  --driver kubernetes \
  --driver-opt namespace=buildx \
  --driver-opt replicas=2 \
  --driver-opt loadbalance=random \
  --config config-remote.toml \
  --bootstrap
```

Then build with:

```bash
make build KUBE_BUILDER=1
```

## License

GPL-3.0
