# K8s Release

Build reproducible Kubernetes DEB/RPM packages with Docker Buildx.

Packages include Kubernetes control-plane binaries, `kubelet`, `kube-proxy`,
`kubectl`, etcd, Flannel, Calico, and optional generated certificate packages.

## Build

```bash
make check-tools
make build
make build PACKAGE_TYPE=rpm
make build PACKAGE_TYPE=all
./k8s-release build v1.32.2 --component kubelet --format deb,rpm
```

Artifacts are written to `output/`.

Main inputs: `KUBE_VERSION`, `ETCD_VERSION`, `FLANNEL_VERSION`,
`CALICO_VERSION`, and `PACKAGE_TYPE=deb|rpm|all`.

## Verification

```bash
make check-pinned-inputs
make verify-packages
make smoke-install-packages
make node-start-smoke
make continuous-improvement
```

CI verifies pinned inputs, package metadata, reproducibility checksums, clean DEB/RPM installs, GitHub-hosted node smoke starts, SBOMs, attestations, Sigstore signatures, signed apt/yum repository metadata, and release evidence.

## CI and Releases

- `Build Kubernetes Packages`: PR/manual package builds.
- `Continuous Improvement`: scheduled and PR release-readiness scoring.
- `Create Release`: tag release assets, evidence, SBOMs, and signatures.
- `Publish Packages`: manual signed repo and GHCR bundle publishing.

Certificate packages contain fresh key material and are intentionally excluded
from deterministic checksum comparisons. The release bar is documented in
`docs/world-class-release-spec.md`.

## License

GPL-3.0
