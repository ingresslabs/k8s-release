# K8s Release

Reproducible Kubernetes DEB/RPM packages for Kubernetes, etcd, Flannel, and Calico.

```bash
make build PACKAGE_TYPE=all
./k8s-release build v1.32.2 --component kubelet --format deb,rpm
./k8s-release verify-release v1.32.2 --repo kubekattle/k8s-release
```

CI proves pinned inputs, reproducibility, clean installs, node smoke starts, SBOMs, provenance, Sigstore signatures, signed repo metadata, and release evidence. Cert packages are intentionally non-deterministic.

Version: `1.0.0`; Spec: `docs/world-class-release-spec.md`; Release policy: `docs/release-policy.md`; License: GPL-3.0
