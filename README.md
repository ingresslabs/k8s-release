# K8s Release

K8s Release builds reproducible DEB and RPM packages for Kubernetes, etcd,
Flannel, Calico, Istio (`istioctl`), and certificates. It also creates signed
apt and yum repositories, SBOMs, checksums, release evidence, and offline
airgap bundles.

Use it when you need controlled Kubernetes package delivery for private,
regulated, or disconnected environments.

Prerequisites:

- `git`, `make`, Bash, and standard Unix command-line utilities.
- Docker Engine with the Compose plugin and Buildx enabled. The default build
  path uses Docker Buildx and Docker Compose.
- Network access to GitHub, container registries, and Debian snapshot mirrors
  when building packages from upstream source.
- For signed package repositories, airgap bundles, and release proof checks:
  `gpg`, `jq`, `dpkg-dev`/`dpkg-deb`, `rpm`, and `createrepo_c`.
- Optional release and lab helpers use the GitHub CLI (`gh`), `cosign`, `oras`,
  `terraform`, `ssh`, `scp`, `curl`, and `unzip`.

Common commands:

```bash
make build PACKAGE_TYPE=all
./k8s-release build v1.36.1 --component kubelet --format deb,rpm
./k8s-release build 1.30.0 --component istio --format deb,rpm
./k8s-release verify-release v1.36.1 --repo OWNER/REPO
./k8s-release bundle v1.36.1 --airgap
./k8s-release verify-bundle k8s-v1.36.1-airgap.tar
./k8s-release passport v1.36.1
```

Key files:

- `docs/world-class-release-spec.md`
- `docs/release-policy.md`
- `VERSION`

License: GPL-3.0
