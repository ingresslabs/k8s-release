#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import logging
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from typing import Any


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[1]
DEFAULT_KUBEADM_ENGINE_NAME = "k2vm-kubeadm-engine.sh"
DEFAULT_K3S_ENGINE = REPO_ROOT / "scripts" / "k2vm-k3s-engine.sh"
DEFAULT_K8S_RELEASE_ROOT = Path.home() / "work" / "k8s-release"
DEFAULT_KERNEL_BOOT_ARGS = (
    "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw "
    "random.trust_cpu=on systemd.mask=serial-getty@ttyS0.service "
    "systemd.mask=systemd-random-seed.service"
)
DEFAULT_KUBEADM_ARTIFACT_COMPONENTS = [
    "certificates",
    "etcd",
    "kube-apiserver",
    "kube-controller-manager",
    "kubelet",
    "kube-proxy",
    "kube-scheduler",
    "kubectl",
]
EMBEDDED_KUBEADM_ENGINE_GZ_B64 = """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"""


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(record.created)),
            "level": record.levelname,
            "message": record.getMessage(),
        }
        if hasattr(record, "event"):
            payload["event"] = getattr(record, "event")
        return json.dumps(payload, sort_keys=True)


def configure_logging(level: str, fmt: str, log_file: Path | None) -> None:
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(getattr(logging, level.upper(), logging.INFO))
    formatter: logging.Formatter
    if fmt == "json":
      formatter = JsonFormatter()
    else:
      formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%dT%H:%M:%S")
    stream = logging.StreamHandler()
    stream.setFormatter(formatter)
    root.addHandler(stream)
    if log_file:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_file, encoding="utf-8")
        file_handler.setFormatter(formatter)
        root.addHandler(file_handler)


log = logging.getLogger("k2vm")


def load_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    log.debug("exec %s", shlex.join(args))
    return subprocess.run(
        args,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        check=True,
        capture_output=capture,
    )


def stream_shell(command: str, *, cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    log.info("run %s", command)
    proc = subprocess.Popen(
        ["bash", "-lc", command],
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        log.info(line.rstrip())
    rc = proc.wait()
    if rc != 0:
        raise subprocess.CalledProcessError(rc, command)


def shell_quote_env(env: dict[str, str]) -> str:
    return " ".join(f"{key}={shlex.quote(str(value))}" for key, value in env.items())


def ensure_cmd(cmd: str) -> None:
    if shutil.which(cmd) is None:
        raise SystemExit(f"missing required command: {cmd}")


def render_embedded_kubeadm_engine_text() -> str:
    text = gzip.decompress(base64.b64decode(EMBEDDED_KUBEADM_ENGINE_GZ_B64)).decode("utf-8")
    kernel_block = 'LINUXKIT_KERNEL_IMAGE="${LINUXKIT_KERNEL_IMAGE:-linuxkit/kernel:6.12.59}"'
    kernel_block_replacement = f"""LINUXKIT_KERNEL_IMAGE="${{LINUXKIT_KERNEL_IMAGE:-linuxkit/kernel:6.12.59}}"
INITRD_PATH="${{INITRD_PATH:-}}"
DEFAULT_KERNEL_BOOT_ARGS="${{DEFAULT_KERNEL_BOOT_ARGS:-{DEFAULT_KERNEL_BOOT_ARGS}}}"
KERNEL_BOOT_ARGS="${{KERNEL_BOOT_ARGS:-${{DEFAULT_KERNEL_BOOT_ARGS}}}}"
KERNEL_BOOT_ARGS_EXTRA="${{KERNEL_BOOT_ARGS_EXTRA:-}}"
if [[ -n "${{KERNEL_BOOT_ARGS_EXTRA}}" ]]; then
  KERNEL_BOOT_ARGS="${{KERNEL_BOOT_ARGS}} ${{KERNEL_BOOT_ARGS_EXTRA}}"
fi"""
    if kernel_block not in text:
        raise RuntimeError("failed to locate LinuxKit kernel block in embedded kubeadm engine")
    text = text.replace(kernel_block, kernel_block_replacement, 1)
    boot_args = (
        '"boot_args":"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw '
        'random.trust_cpu=on systemd.mask=serial-getty@ttyS0.service '
        'systemd.mask=systemd-random-seed.service"'
    )
    if boot_args not in text:
        raise RuntimeError("failed to locate Firecracker boot args in embedded kubeadm engine")
    text = text.replace(boot_args, '"boot_args":"${KERNEL_BOOT_ARGS}"', 1)
    containerd_selinux_line = "  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \"${mnt}/etc/containerd/config.toml\""
    containerd_selinux_replacement = """  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${mnt}/etc/containerd/config.toml"
  sed -i 's/enable_selinux = false/enable_selinux = true/' "${mnt}/etc/containerd/config.toml" || true"""
    if containerd_selinux_line not in text:
        raise RuntimeError("failed to locate containerd SystemdCgroup config in embedded kubeadm engine")
    text = text.replace(containerd_selinux_line, containerd_selinux_replacement, 1)
    cni_archive_line = '  local cni_archive="${CACHE_ROOT}/downloads/cni-plugins-linux-${cni_arch_value}-${CNI_PLUGINS_VERSION}.tgz"'
    cni_archive_replacement = (
        '  mkdir -p "${CACHE_ROOT}/downloads"\n'
        '  local cni_archive="${CACHE_ROOT}/downloads/cni-plugins-linux-${cni_arch_value}-${CNI_PLUGINS_VERSION}.tgz"'
    )
    if cni_archive_line not in text:
        raise RuntimeError("failed to locate CNI archive cache path in embedded kubeadm engine")
    text = text.replace(cni_archive_line, cni_archive_replacement, 1)
    prepared_rootfs_block = (
        '  cleanup_mounts\n'
        '  trap - RETURN ERR\n'
        '  mv "${tmp}" "${prepared}"\n'
        '  PREPARED_ROOTFS_PATH="${prepared}"'
    )
    prepared_rootfs_replacement = (
        '  cleanup_mounts\n'
        '  if [[ -f "${mnt}/etc/selinux/config" ]] && grep -Eq \'^SELINUX=(enforcing|permissive)$\' "${mnt}/etc/selinux/config"; then\n'
        '    if ! chroot "${mnt}" /sbin/setfiles -F /etc/selinux/default/contexts/files/file_contexts / >"${CACHE_ROOT}/selinux-relabel-${key}.log" 2>&1; then\n'
        '      cat "${CACHE_ROOT}/selinux-relabel-${key}.log" >&2\n'
        '      prepare_failed="1"\n'
        '      return 1\n'
        '    fi\n'
        '    rm -f "${mnt}/.autorelabel"\n'
        '  fi\n'
        '  trap - RETURN ERR\n'
        '  mv "${tmp}" "${prepared}"\n'
        '  PREPARED_ROOTFS_PATH="${prepared}"'
    )
    if prepared_rootfs_block not in text:
        raise RuntimeError("failed to locate prepared rootfs finalize block in embedded kubeadm engine")
    text = text.replace(prepared_rootfs_block, prepared_rootfs_replacement, 1)
    vm_json_block = """  cat >"${vm_dir}/vm.json" <<EOF
{"boot-source":{"kernel_image_path":"${KERNEL_PATH}","boot_args":"${KERNEL_BOOT_ARGS}"},"drives":[{"drive_id":"rootfs","path_on_host":"${vm_dir}/rootfs.ext4","is_root_device":true,"is_read_only":false}],"machine-config":{"vcpu_count":${VCPU_COUNT},"mem_size_mib":${mem}},"network-interfaces":[{"iface_id":"eth0","host_dev_name":"${tap}","guest_mac":"${mac}"}],"logger":{"log_path":"${vm_dir}/firecracker.log","level":"Info","show_level":true,"show_log_origin":true}}
EOF"""
    vm_json_replacement = """  if [[ -n "${INITRD_PATH}" ]]; then
    cat >"${vm_dir}/vm.json" <<EOF
{"boot-source":{"kernel_image_path":"${KERNEL_PATH}","initrd_path":"${INITRD_PATH}","boot_args":"${KERNEL_BOOT_ARGS}"},"drives":[{"drive_id":"rootfs","path_on_host":"${vm_dir}/rootfs.ext4","is_root_device":true,"is_read_only":false}],"machine-config":{"vcpu_count":${VCPU_COUNT},"mem_size_mib":${mem}},"network-interfaces":[{"iface_id":"eth0","host_dev_name":"${tap}","guest_mac":"${mac}"}],"logger":{"log_path":"${vm_dir}/firecracker.log","level":"Info","show_level":true,"show_log_origin":true}}
EOF
  else
    cat >"${vm_dir}/vm.json" <<EOF
{"boot-source":{"kernel_image_path":"${KERNEL_PATH}","boot_args":"${KERNEL_BOOT_ARGS}"},"drives":[{"drive_id":"rootfs","path_on_host":"${vm_dir}/rootfs.ext4","is_root_device":true,"is_read_only":false}],"machine-config":{"vcpu_count":${VCPU_COUNT},"mem_size_mib":${mem}},"network-interfaces":[{"iface_id":"eth0","host_dev_name":"${tap}","guest_mac":"${mac}"}],"logger":{"log_path":"${vm_dir}/firecracker.log","level":"Info","show_level":true,"show_log_origin":true}}
EOF
  fi"""
    if vm_json_block not in text:
        raise RuntimeError("failed to locate Firecracker vm.json generation block in embedded kubeadm engine")
    return text.replace(vm_json_block, vm_json_replacement, 1)


def materialize_embedded_kubeadm_engine(output_dir: Path) -> Path:
    engine_dir = output_dir / ".generated-engines"
    engine_dir.mkdir(parents=True, exist_ok=True)
    engine_path = engine_dir / DEFAULT_KUBEADM_ENGINE_NAME
    content = render_embedded_kubeadm_engine_text().encode("utf-8")
    if not engine_path.exists() or engine_path.read_bytes() != content:
        engine_path.write_bytes(content)
        engine_path.chmod(0o755)
    return engine_path


def resolve_engine_path(spec: dict[str, Any], output_dir: Path) -> Path:
    if spec["cluster"]["distribution"] == "kubeadm":
        return materialize_embedded_kubeadm_engine(output_dir)
    return DEFAULT_K3S_ENGINE


def deep_get(doc: dict[str, Any], path: str, default: Any = None) -> Any:
    cur: Any = doc
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def kube_minor(version: str) -> str:
    match = re.match(r"^(v\d+\.\d+)", version)
    if not match:
        raise ValueError(f"cannot derive Kubernetes minor from {version}")
    return match.group(1)


def default_output_dir(spec: dict[str, Any]) -> Path:
    name = spec.get("name", "k2vm")
    timestamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    return REPO_ROOT / "runtime" / "k2vm" / f"{name}-{timestamp}"


def normalize_spec(spec: dict[str, Any], output_dir: Path) -> dict[str, Any]:
    spec = json.loads(json.dumps(spec))
    spec.setdefault("schema_version", "k2vm.spec.v1")
    spec.setdefault("name", "k2vm")
    spec.setdefault("target", {})
    spec.setdefault("cluster", {})
    spec.setdefault("firecracker", {})
    spec.setdefault("paths", {})
    spec.setdefault("logging", {})
    spec.setdefault("release", {})
    spec.setdefault("addons", {})

    distro = spec["cluster"].setdefault("distribution", "kubeadm")
    if distro not in {"kubeadm", "k3s"}:
        raise ValueError("cluster.distribution must be kubeadm or k3s")

    target = spec["target"]
    target.setdefault("host", "")
    target.setdefault("user", "root")
    target.setdefault("workdir", f"/root/k2vm/{spec['name']}")

    fc = spec["firecracker"]
    fc.setdefault("binary", "/usr/local/bin/firecracker")
    fc.setdefault("linuxkit_kernel_image", "linuxkit/kernel:6.12.59")
    fc.setdefault("bridge_name", "k2vm198")
    fc.setdefault("tap_prefix", "k2vm198")
    fc.setdefault("vcpu_count", 2)
    fc.setdefault("kernel_boot_args", "")
    fc.setdefault("initrd_path", "")
    if "kernel_source" not in fc:
        fc["kernel_source"] = "provided" if distro == "k3s" else "linuxkit"
    kernel_source = str(fc["kernel_source"]).strip().lower()
    if kernel_source == "firecracker":
        kernel_source = "provided"
    fc["kernel_source"] = kernel_source
    kernel_params = fc.get("kernel_params", [])
    if kernel_params is None:
        kernel_params = []
    elif isinstance(kernel_params, str):
        kernel_params = shlex.split(kernel_params)
    fc["kernel_params"] = kernel_params

    paths = spec["paths"]
    if distro == "kubeadm":
        paths.setdefault("run_root", "/var/lib/k2vm-kubeadm-ha")
        paths.setdefault("cache_root", "/var/cache/k2vm-kubeadm-ha")
    else:
        paths.setdefault("run_root", "/var/lib/k2vm-k3s")
        paths.setdefault("cache_root", "/var/cache/k2vm-k3s")
    paths.setdefault("local_output_dir", str(output_dir))

    cluster = spec["cluster"]
    cluster.setdefault("subnet_prefix", "198.19.0" if distro == "kubeadm" else "172.31.240")
    cluster.setdefault("network_plugin", "flannel")
    cluster.setdefault("pod_cidr", "10.244.0.0/16")
    cluster.setdefault("service_cidr", "10.96.0.0/12")
    if distro == "kubeadm":
        cluster.setdefault("control_plane_count", 3)
        cluster.setdefault("worker_count", 0)
        cluster.setdefault("api_lb_ip", f"{cluster['subnet_prefix']}.5")
        cluster.setdefault("api_lb_port", 6443)
        if "kubernetes_version" in cluster:
            cluster.setdefault("kubernetes_minor", kube_minor(cluster["kubernetes_version"]))
        else:
            cluster.setdefault("kubernetes_minor", "v1.36")
    else:
        cluster.setdefault("server_count", 1)
        cluster.setdefault("agent_count", 2)
        cluster.setdefault("k3s_version", "")
        fc.setdefault("kernel_path", "/opt/firecracker-sandbox-lab/vmlinux.bin")
        fc.setdefault("base_rootfs_path", "/opt/firecracker-sandbox-lab/rootfs.ext4")

    logging_cfg = spec["logging"]
    logging_cfg.setdefault("level", "INFO")
    logging_cfg.setdefault("format", "text")
    logging_cfg.setdefault("file", str(output_dir / "client.log"))

    release = spec["release"]
    release.setdefault("enabled", False)
    release.setdefault("repo_root", str(DEFAULT_K8S_RELEASE_ROOT))
    release.setdefault("github_repo", "ingresslabs/k8s-release")
    release.setdefault("package_repository", {})
    package_repo = release["package_repository"]
    package_repo.setdefault("artifact_layout", "auto")
    package_repo.setdefault("artifact_name", "package-repositories")
    package_repo.setdefault("artifact_names", [])
    package_repo.setdefault("artifact_components", [])
    package_repo.setdefault("artifact_components_exclude", [])
    package_repo.setdefault("local_dir", "")
    package_repo.setdefault("remote_root", "")
    package_repo.setdefault("mode", "hybrid")
    package_repo.setdefault("trusted", None)
    if "source" not in package_repo:
        if package_repo["local_dir"]:
            package_repo["source"] = "local_dir"
        elif package_repo["remote_root"]:
            package_repo["source"] = "remote_existing"
        elif deep_get(spec, "release.github_run.run_id"):
            package_repo["source"] = "github_run_artifact"
        else:
            package_repo["source"] = "none"

    addons = spec["addons"]
    addons.setdefault("istio", {})
    istio = addons["istio"]
    istio.setdefault("enabled", False)
    istio.setdefault("profile", "minimal")
    istio.setdefault("istioctl_path", "")
    return spec


def enrich_from_github_run(spec: dict[str, Any], output_dir: Path) -> None:
    run_id = deep_get(spec, "release.github_run.run_id")
    if not run_id:
        return
    ensure_cmd("gh")
    repo = deep_get(spec, "release.github_run.repo", spec["release"]["github_repo"])
    cmd = [
        "gh",
        "api",
        f"repos/{repo}/actions/runs/{run_id}/artifacts",
        "--paginate",
    ]
    result = run(cmd, capture=True)
    payload = json.loads(result.stdout)
    artifacts = payload.get("artifacts", [])
    spec["release"]["github_run_artifacts"] = {
        artifact["name"]: {
            "id": artifact["id"],
            "size_in_bytes": artifact.get("size_in_bytes", 0),
        }
        for artifact in artifacts
        if artifact.get("name") and artifact.get("id")
    }
    meta_path = output_dir / "release-artifacts-meta.json"
    meta_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    label = None
    for artifact in artifacts:
        name = artifact.get("name", "")
        match = re.match(
            r"^(v[^-]+-v[^-]+-v[^-]+-v[^-]+(?:-[^-]+)?)-kubelet-packages$",
            name,
        )
        if match:
            label = match.group(1)
            break
    if not label:
        return
    match = re.match(r"^(v[^-]+)-(v[^-]+)-(v[^-]+)-(v[^-]+)(?:-([^-]+))?$", label)
    if not match:
        return
    kube_version, etcd_version, flannel_version, calico_version, istio_version = match.groups()
    cluster = spec["cluster"]
    cluster.setdefault("kubernetes_version", kube_version)
    if cluster["distribution"] == "kubeadm":
        cluster.setdefault("kubernetes_minor", kube_minor(kube_version))
        cluster.setdefault("network_plugin", "flannel")
    else:
        cluster.setdefault("k3s_version", "")
    spec["release"]["resolved_versions"] = {
        "kubernetes_version": kube_version,
        "etcd_version": etcd_version,
        "flannel_version": flannel_version,
        "calico_version": calico_version,
        "label": label,
    }
    if istio_version:
        spec["release"]["resolved_versions"]["istio_version"] = istio_version
        spec["addons"]["istio"].setdefault("version", istio_version)
    log.info("resolved versions from GitHub run %s: %s", run_id, label)


def maybe_run_k8s_release(spec: dict[str, Any], output_dir: Path) -> None:
    if not deep_get(spec, "release.enabled", False):
        return
    repo_root = Path(spec["release"]["repo_root"]).expanduser().resolve()
    build = deep_get(spec, "release.build", {})
    if not build:
        log.info("release.enabled=true but no release.build config supplied; skipping local k8s-release build")
        return
    components = build.get("components", [])
    fmt = build.get("format", "deb")
    if not components:
      return
    for component in components:
        if component == "etcd":
            version = deep_get(spec, "release.resolved_versions.etcd_version") or build.get("etcd_version")
        elif component == "flannel":
            version = deep_get(spec, "release.resolved_versions.flannel_version") or build.get("flannel_version")
        else:
            version = spec["cluster"].get("kubernetes_version") or build.get("kubernetes_version")
        if not version:
            raise ValueError(f"missing version for k8s-release component {component}")
        stream_shell(
            f"./k8s-release build {shlex.quote(version)} --component {shlex.quote(component)} --format {shlex.quote(fmt)}",
            cwd=repo_root,
        )
    (output_dir / "k8s-release-build.complete").write_text("ok\n", encoding="utf-8")


def resolve_local_package_repo(path: Path) -> tuple[Path, str]:
    root = path.expanduser().resolve()
    candidates = [root, root / "package-repositories"]
    for candidate in candidates:
        debian_dir = candidate / "debian"
        if not debian_dir.is_dir():
            continue
        if (debian_dir / "dists").is_dir():
            return candidate, "prebuilt_repo"
        if (debian_dir / "Packages").is_file() or (debian_dir / "Packages.gz").is_file():
            return candidate, "component_packages"
    raise ValueError(
        f"{root} is not a package repository root "
        f"(expected debian/ plus either debian/dists or debian/Packages)"
    )


def github_artifact(spec: dict[str, Any], name: str) -> dict[str, Any]:
    artifacts = deep_get(spec, "release.github_run_artifacts", {})
    artifact = artifacts.get(name)
    if artifact:
        return artifact
    raise ValueError(f"GitHub run is missing required artifact: {name}")


def package_repo_artifact_layout(spec: dict[str, Any]) -> str:
    layout = deep_get(spec, "release.package_repository.artifact_layout", "auto")
    if layout != "auto":
        return layout
    artifact_name = deep_get(spec, "release.package_repository.artifact_name", "package-repositories")
    artifacts = deep_get(spec, "release.github_run_artifacts", {})
    if artifact_name and artifact_name in artifacts:
        return "prebuilt_repo"
    return "component_packages"


def package_repo_trusted(spec: dict[str, Any], layout: str) -> bool:
    trusted = deep_get(spec, "release.package_repository.trusted")
    if trusted is None:
        return layout == "component_packages"
    return bool(trusted)


def default_artifact_components(spec: dict[str, Any]) -> list[str]:
    components = list(DEFAULT_KUBEADM_ARTIFACT_COMPONENTS)
    if deep_get(spec, "addons.istio.enabled", False):
        components.append("istio")
    return components


def select_github_package_artifacts(spec: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    layout = package_repo_artifact_layout(spec)
    if layout == "prebuilt_repo":
        name = deep_get(spec, "release.package_repository.artifact_name", "package-repositories")
        artifact = github_artifact(spec, name)
        return layout, [{"name": name, **artifact}]

    explicit_names = deep_get(spec, "release.package_repository.artifact_names", [])
    if explicit_names:
        selected_names = explicit_names
    else:
        components = deep_get(spec, "release.package_repository.artifact_components", []) or default_artifact_components(spec)
        excluded = set(deep_get(spec, "release.package_repository.artifact_components_exclude", []))
        selected_names = []
        artifacts = deep_get(spec, "release.github_run_artifacts", {})
        for component in components:
            if component in excluded:
                continue
            suffix = f"-{component}-packages"
            matches = [name for name in artifacts if name.endswith(suffix)]
            if len(matches) != 1:
                raise ValueError(
                    f"expected exactly one GitHub artifact matching component {component!r}, found {matches or 'none'}"
                )
            selected_names.append(matches[0])

    selected: list[dict[str, Any]] = []
    seen: set[str] = set()
    for name in selected_names:
        if name in seen:
            continue
        seen.add(name)
        selected.append({"name": name, **github_artifact(spec, name)})
    if not selected:
        raise ValueError("no GitHub package artifacts selected")
    return "component_packages", selected


def stream_to_remote_file(source_args: list[str], target: str, remote_path: str) -> None:
    log.info("stream %s -> %s:%s", shlex.join(source_args), target, remote_path)
    src = subprocess.Popen(source_args, stdout=subprocess.PIPE)
    assert src.stdout is not None
    try:
        subprocess.run(
            ["ssh", target, f"cat > {shlex.quote(remote_path)}"],
            stdin=src.stdout,
            check=True,
        )
    finally:
        src.stdout.close()
    rc = src.wait()
    if rc != 0:
        raise subprocess.CalledProcessError(rc, source_args)


def write_sha256sums(directory: Path, output_path: Path) -> None:
    lines: list[str] = []
    for path in sorted(directory.glob("*.deb")):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  {path.name}")
    output_path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def write_flat_repo_index(repo_root: Path) -> None:
    ensure_cmd("dpkg-scanpackages")
    debian_dir = repo_root / "debian"
    packages = run(["dpkg-scanpackages", ".", "/dev/null"], cwd=debian_dir, capture=True).stdout
    (debian_dir / "Packages").write_text(packages, encoding="utf-8")
    with gzip.open(debian_dir / "Packages.gz", "wt", encoding="utf-8") as fh:
        fh.write(packages)
    write_sha256sums(debian_dir, repo_root / "SHA256SUMS")
    (repo_root / "repo-signing-key.asc").write_text(
        "UNSIGNED\nThis repository was generated locally from GitHub Actions package artifacts.\n",
        encoding="utf-8",
    )


def extract_local_github_artifact(repo: str, artifact_id: int, zip_path: Path) -> None:
    with zip_path.open("wb") as fh:
        subprocess.run(
            ["gh", "api", f"repos/{repo}/actions/artifacts/{artifact_id}/zip"],
            check=True,
            stdout=fh,
        )


def build_local_component_package_repo(
    spec: dict[str, Any],
    output_dir: Path,
    repo: str,
    artifacts: list[dict[str, Any]],
) -> dict[str, Any]:
    stage_dir = output_dir / "release-inputs" / "package-repositories"
    raw_dir = stage_dir / "raw"
    debian_dir = stage_dir / "debian"
    tools_dir = stage_dir / "tools"
    shutil.rmtree(stage_dir, ignore_errors=True)
    raw_dir.mkdir(parents=True, exist_ok=True)
    debian_dir.mkdir(parents=True, exist_ok=True)
    tools_dir.mkdir(parents=True, exist_ok=True)

    for artifact in artifacts:
        artifact_name = artifact["name"]
        artifact_zip = raw_dir / f"{artifact_name}.zip"
        extract_dir = raw_dir / artifact_name
        extract_local_github_artifact(repo, artifact["id"], artifact_zip)
        with zipfile.ZipFile(artifact_zip) as zf:
            zf.extractall(extract_dir)
        artifact_zip.unlink(missing_ok=True)
        for deb in extract_dir.glob("*.deb"):
            shutil.copy2(deb, debian_dir / deb.name)
        istioctl = extract_dir / "istioctl"
        if istioctl.is_file():
            target = tools_dir / "istioctl"
            shutil.copy2(istioctl, target)
            target.chmod(0o755)

    if not list(debian_dir.glob("*.deb")):
        raise ValueError("selected GitHub package artifacts did not contain any .deb payloads")

    write_flat_repo_index(stage_dir)
    tools: dict[str, str] = {}
    if (tools_dir / "istioctl").is_file():
        tools["istioctl"] = str((tools_dir / "istioctl").resolve())
    return {
        "root": str(stage_dir.resolve()),
        "layout": "component_packages",
        "trusted": True,
        "tools": tools,
    }


def resolve_remote_package_repo_root(target: str, base_dir: str) -> tuple[str, str]:
    command = (
        f"base={shlex.quote(base_dir)}; "
        'for candidate in "$base" "$base/package-repositories"; do '
        'if [ -d "$candidate/debian/dists" ]; then printf "%s prebuilt_repo\\n" "$candidate"; exit 0; fi; '
        'if [ -d "$candidate/debian" ] && { [ -f "$candidate/debian/Packages" ] || [ -f "$candidate/debian/Packages.gz" ]; }; then '
        'printf "%s component_packages\\n" "$candidate"; exit 0; fi; '
        "done; exit 1"
    )
    result = run(["ssh", target, command], capture=True)
    root, layout = result.stdout.strip().split()
    return root, layout


def stage_local_github_package_repo(spec: dict[str, Any], output_dir: Path) -> dict[str, Any]:
    ensure_cmd("gh")
    repo = deep_get(spec, "release.github_run.repo", spec["release"]["github_repo"])
    layout, artifacts = select_github_package_artifacts(spec)
    if layout == "prebuilt_repo":
        artifact_name = artifacts[0]["name"]
        run_id = deep_get(spec, "release.github_run.run_id")
        stage_dir = output_dir / "release-inputs" / artifact_name
        stage_dir.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["TMPDIR"] = str(stage_dir)
        run(
            [
                "gh",
                "run",
                "download",
                str(run_id),
                "--repo",
                repo,
                "-n",
                artifact_name,
                "--dir",
                str(stage_dir),
            ],
            env=env,
        )
        root, root_layout = resolve_local_package_repo(stage_dir)
        return {
            "root": str(root),
            "layout": root_layout,
            "trusted": package_repo_trusted(spec, root_layout),
            "tools": {},
        }
    return build_local_component_package_repo(spec, output_dir, repo, artifacts)


def stage_remote_package_repo(spec: dict[str, Any], target: str, remote_bundle: str) -> dict[str, Any]:
    package_repo = spec["release"]["package_repository"]
    stage_dir = f"{remote_bundle}/release-inputs/package-repositories"
    run(["ssh", target, f"rm -rf {shlex.quote(stage_dir)} && mkdir -p {shlex.quote(stage_dir)}"])
    source = package_repo["source"]
    if source == "local_dir":
        local_root, local_layout = resolve_local_package_repo(Path(package_repo["local_dir"]))
        run(["scp", "-r", str(local_root), f"{target}:{stage_dir}/"])
        candidate = f"{stage_dir}/{local_root.name}"
        root, layout = resolve_remote_package_repo_root(target, candidate)
        return {
            "root": root,
            "layout": local_layout or layout,
            "trusted": package_repo_trusted(spec, local_layout or layout),
            "tools": {},
        }
    elif source == "remote_existing":
        root, layout = resolve_remote_package_repo_root(target, package_repo["remote_root"])
        return {
            "root": root,
            "layout": layout,
            "trusted": package_repo_trusted(spec, layout),
            "tools": {},
        }
    elif source == "github_run_artifact":
        ensure_cmd("gh")
        repo = deep_get(spec, "release.github_run.repo", spec["release"]["github_repo"])
        layout, artifacts = select_github_package_artifacts(spec)
        if layout == "prebuilt_repo":
            artifact_name = artifacts[0]["name"]
            remote_zip = f"{remote_bundle}/{artifact_name}.zip"
            stream_to_remote_file(
                ["gh", "api", f"repos/{repo}/actions/artifacts/{artifacts[0]['id']}/zip"],
                target,
                remote_zip,
            )
            run(
                [
                    "ssh",
                    target,
                    (
                        f"rm -rf {shlex.quote(stage_dir)} && mkdir -p {shlex.quote(stage_dir)} && "
                        f"python3 -m zipfile -e {shlex.quote(remote_zip)} {shlex.quote(stage_dir)} && "
                        f"rm -f {shlex.quote(remote_zip)}"
                    ),
                ]
            )
            root, resolved_layout = resolve_remote_package_repo_root(target, stage_dir)
            return {
                "root": root,
                "layout": resolved_layout,
                "trusted": package_repo_trusted(spec, resolved_layout),
                "tools": {},
            }

        run(
            [
                "ssh",
                target,
                (
                    f"rm -rf {shlex.quote(stage_dir)} && "
                    f"mkdir -p {shlex.quote(stage_dir)}/raw {shlex.quote(stage_dir)}/debian {shlex.quote(stage_dir)}/tools"
                ),
            ]
        )
        for artifact in artifacts:
            artifact_name = artifact["name"]
            remote_zip = f"{stage_dir}/raw/{artifact_name}.zip"
            extract_dir = f"{stage_dir}/raw/{artifact_name}"
            stream_to_remote_file(
                ["gh", "api", f"repos/{repo}/actions/artifacts/{artifact['id']}/zip"],
                target,
                remote_zip,
            )
            run(
                [
                    "ssh",
                    target,
                    (
                        f"mkdir -p {shlex.quote(extract_dir)} && "
                        f"python3 -m zipfile -e {shlex.quote(remote_zip)} {shlex.quote(extract_dir)} && "
                        f"rm -f {shlex.quote(remote_zip)} && "
                        f"find {shlex.quote(extract_dir)} -maxdepth 1 -type f -name '*.deb' -exec cp -f {{}} {shlex.quote(stage_dir)}/debian/ \\; && "
                        f"if [ -f {shlex.quote(extract_dir + '/istioctl')} ]; then install -m 0755 {shlex.quote(extract_dir + '/istioctl')} {shlex.quote(stage_dir)}/tools/istioctl; fi"
                    ),
                ]
            )
        run(
            [
                "ssh",
                target,
                (
                    f"test -n \"$(find {shlex.quote(stage_dir)}/debian -maxdepth 1 -type f -name '*.deb' -print -quit)\" && "
                    f"cd {shlex.quote(stage_dir)}/debian && "
                    "dpkg-scanpackages . /dev/null > Packages && "
                    "gzip -9c Packages > Packages.gz && "
                    f"sha256sum ./*.deb > {shlex.quote(stage_dir)}/SHA256SUMS && "
                    f"printf '%s\\n' 'UNSIGNED' 'Generated from GitHub Actions package artifacts.' > {shlex.quote(stage_dir)}/repo-signing-key.asc"
                ),
            ]
        )
        return {
            "root": stage_dir,
            "layout": "component_packages",
            "trusted": True,
            "tools": {"istioctl": f"{stage_dir}/tools/istioctl"},
        }
    else:
        raise ValueError(f"unsupported package repository source: {source}")


def stage_package_repo(spec: dict[str, Any], output_dir: Path, target: str, remote_bundle: str) -> str | None:
    if not deep_get(spec, "release.enabled", False):
        return None
    if spec["cluster"]["distribution"] != "kubeadm":
        return None
    source = deep_get(spec, "release.package_repository.source", "none")
    if source == "none":
        return None
    if target:
        staged = stage_remote_package_repo(spec, target, remote_bundle)
    else:
        if source == "local_dir":
            staged_root, layout = resolve_local_package_repo(Path(spec["release"]["package_repository"]["local_dir"]))
            staged = {
                "root": str(staged_root),
                "layout": layout,
                "trusted": package_repo_trusted(spec, layout),
                "tools": {},
            }
        elif source == "remote_existing":
            raise ValueError("remote_existing package repositories require a remote target host")
        elif source == "github_run_artifact":
            staged = stage_local_github_package_repo(spec, output_dir)
        else:
            raise ValueError(f"unsupported package repository source: {source}")
    spec["release"]["staged_package_repository_root"] = staged["root"]
    spec["release"]["staged_package_repository_layout"] = staged["layout"]
    spec["release"]["staged_package_repository_trusted"] = staged["trusted"]
    spec["release"]["staged_tools"] = staged.get("tools", {})
    return staged["root"]


def ssh_target(spec: dict[str, Any]) -> str:
    host = spec["target"]["host"]
    user = spec["target"]["user"]
    if not host or host == "local":
        return ""
    if "@" in host:
        return host
    return f"{user}@{host}"


def remote_env(spec: dict[str, Any], engine_path: str, mode: str) -> dict[str, str]:
    distro = spec["cluster"]["distribution"]
    fc = spec["firecracker"]
    cluster = spec["cluster"]
    paths = spec["paths"]
    env: dict[str, str] = {
        "RUN_ROOT": paths["run_root"],
        "CACHE_ROOT": paths["cache_root"],
        "FIRECRACKER_BIN": fc["binary"],
        "BRIDGE_NAME": fc["bridge_name"],
        "TAP_PREFIX": fc["tap_prefix"],
        "SUBNET_PREFIX": cluster["subnet_prefix"],
        "KERNEL_SOURCE": fc["kernel_source"],
    }
    if fc.get("kernel_boot_args"):
        env["KERNEL_BOOT_ARGS"] = fc["kernel_boot_args"]
    if fc.get("kernel_params"):
        env["KERNEL_BOOT_ARGS_EXTRA"] = " ".join(fc["kernel_params"])
    if distro == "kubeadm":
        env.update(
            {
                "CONTROL_PLANE_COUNT": str(cluster["control_plane_count"]),
                "WORKER_COUNT": str(cluster["worker_count"]),
                "KUBERNETES_MINOR": cluster["kubernetes_minor"],
                "POD_CIDR": cluster["pod_cidr"],
                "SERVICE_CIDR": cluster["service_cidr"],
                "NETWORK_PLUGIN": cluster["network_plugin"],
                "API_LB_IP": cluster["api_lb_ip"],
                "API_LB_PORT": str(cluster["api_lb_port"]),
                "VCPU_COUNT": str(fc["vcpu_count"]),
            }
        )
        if fc["kernel_source"] == "linuxkit":
            env["LINUXKIT_KERNEL_IMAGE"] = fc["linuxkit_kernel_image"]
        if cluster.get("kubernetes_version"):
            env["KUBERNETES_VERSION"] = cluster["kubernetes_version"]
        if cluster.get("flannel_manifest_url"):
            env["FLANNEL_MANIFEST_URL"] = cluster["flannel_manifest_url"]
        resolved_flannel = deep_get(spec, "release.resolved_versions.flannel_version")
        if resolved_flannel:
            env["FLANNEL_VERSION"] = resolved_flannel
        if deep_get(spec, "release.staged_package_repository_root"):
            env["PACKAGE_REPO_ROOT"] = spec["release"]["staged_package_repository_root"]
            env["PACKAGE_REPO_MODE"] = deep_get(spec, "release.package_repository.mode", "hybrid")
            env["PACKAGE_REPO_LAYOUT"] = deep_get(spec, "release.staged_package_repository_layout", "prebuilt_repo")
            env["PACKAGE_REPO_TRUSTED"] = "1" if deep_get(spec, "release.staged_package_repository_trusted", False) else "0"
        if fc.get("kernel_path"):
            env["KERNEL_PATH"] = fc["kernel_path"]
        if fc.get("initrd_path"):
            env["INITRD_PATH"] = fc["initrd_path"]
        if fc.get("kernel_modules_tar_path"):
            env["KERNEL_MODULES_TAR_PATH"] = fc["kernel_modules_tar_path"]
        if fc.get("base_rootfs_path"):
            env["BASE_ROOTFS_PATH"] = fc["base_rootfs_path"]
        if fc.get("rootfs_squashfs_path"):
            env["ROOTFS_SQUASHFS_PATH"] = fc["rootfs_squashfs_path"]
        if mode == "apply" and deep_get(spec, "addons.istio.enabled", False):
            istioctl_path = deep_get(spec, "addons.istio.istioctl_path") or deep_get(spec, "release.staged_tools.istioctl")
            if not istioctl_path:
                raise ValueError("addons.istio.enabled requires an istioctl artifact or addons.istio.istioctl_path")
            env["INSTALL_ISTIO"] = "1"
            env["ISTIOCTL_BIN"] = istioctl_path
            env["ISTIO_PROFILE"] = deep_get(spec, "addons.istio.profile", "minimal")
            istio_version = deep_get(spec, "addons.istio.version") or deep_get(spec, "release.resolved_versions.istio_version")
            if istio_version:
                env["ISTIO_VERSION"] = istio_version
    else:
        env.update(
            {
                "SERVER_COUNT": str(cluster["server_count"]),
                "AGENT_COUNT": str(cluster["agent_count"]),
                "POD_CIDR": cluster["pod_cidr"],
                "SERVICE_CIDR": cluster["service_cidr"],
                "VCPU_COUNT": str(fc["vcpu_count"]),
            }
        )
        if fc["kernel_source"] == "linuxkit":
            env["LINUXKIT_KERNEL_IMAGE"] = fc["linuxkit_kernel_image"]
        if cluster.get("k3s_version"):
            env["K3S_VERSION"] = cluster["k3s_version"]
        if fc.get("kernel_path"):
            env["KERNEL_PATH"] = fc["kernel_path"]
        if fc.get("base_rootfs_path"):
            env["BASE_ROOTFS"] = fc["base_rootfs_path"]
        if fc.get("guest_ssh_key"):
            env["GUEST_SSH_KEY"] = fc["guest_ssh_key"]
        if fc.get("guest_ssh_pub"):
            env["GUEST_SSH_PUB"] = fc["guest_ssh_pub"]
        if fc.get("k3s_bin"):
            env["K3S_BIN"] = fc["k3s_bin"]
    env["K2VM_ENGINE_PATH"] = engine_path
    return env


def stage_remote(spec: dict[str, Any], local_output_dir: Path, engine: Path) -> tuple[str, Path]:
    target = ssh_target(spec)
    if not target:
        return "", local_output_dir
    remote_root = spec["target"]["workdir"]
    remote_bundle = f"{remote_root}/bundle"
    run(["ssh", target, f"mkdir -p {shlex.quote(remote_bundle)}"])
    files = [SCRIPT_PATH, engine]
    for local_path in files:
        run(["scp", str(local_path), f"{target}:{remote_bundle}/"])
    return remote_bundle, local_output_dir


def fetch_remote_artifacts(spec: dict[str, Any], output_dir: Path) -> None:
    target = ssh_target(spec)
    if not target:
        return
    output_dir.mkdir(parents=True, exist_ok=True)
    remote_run_root = spec["paths"]["run_root"]
    subprocess.run(
        ["scp", "-r", f"{target}:{remote_run_root}/artifacts", str(output_dir / "artifacts")],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def cleanup_remote_workdir(spec: dict[str, Any]) -> None:
    target = ssh_target(spec)
    if not target:
        return
    run(["ssh", target, f"rm -rf {shlex.quote(spec['target']['workdir'])}"])


def execute_engine(spec: dict[str, Any], mode: str, output_dir: Path) -> None:
    target = ssh_target(spec)
    engine = resolve_engine_path(spec, output_dir)
    remote_bundle, _ = stage_remote(spec, output_dir, engine)
    if mode == "apply":
        stage_package_repo(spec, output_dir, target, remote_bundle)
    env = remote_env(spec, engine.name if target else str(engine), mode)
    if target:
        remote_engine = f"{remote_bundle}/{Path(env['K2VM_ENGINE_PATH']).name}"
        env["K2VM_ENGINE_PATH"] = remote_engine
        command = (
            f"{shell_quote_env(env)} bash {shlex.quote(remote_engine)} {shlex.quote(mode)}"
        )
        stream_shell(f"ssh {shlex.quote(target)} {shlex.quote(command)}")
        if mode == "apply":
            fetch_remote_artifacts(spec, output_dir)
        elif mode == "delete":
            cleanup_remote_workdir(spec)
    else:
        if sys.platform != "linux":
            raise SystemExit("local mode requires running k2vm.py on a Linux host")
        env = os.environ | env
        stream_shell(f"bash {shlex.quote(str(engine))} {shlex.quote(mode)}", cwd=REPO_ROOT, env=env)


def render_example(distribution: str) -> None:
    example: dict[str, Any] = {
        "schema_version": "k2vm.spec.v1",
        "name": f"{distribution}-proof",
        "target": {
            "host": "CHANGE_ME",
            "user": "root",
            "workdir": f"/tmp/k2vm/{distribution}-proof",
        },
        "cluster": {
            "distribution": distribution,
            "subnet_prefix": "198.19.0" if distribution == "kubeadm" else "172.31.240",
            "pod_cidr": "10.244.0.0/16",
            "service_cidr": "10.96.0.0/12",
        },
        "firecracker": {
            "binary": "/usr/local/bin/firecracker",
            "bridge_name": "k2vm198",
            "kernel_source": "linuxkit",
            "kernel_params": [],
            "tap_prefix": "k2vm198",
            "linuxkit_kernel_image": "linuxkit/kernel:6.12.59",
        },
        "paths": {},
        "release": {
            "enabled": True,
            "package_repository": {
                "source": "local_dir",
                "local_dir": "./package-repositories",
                "artifact_layout": "auto",
                "artifact_components": list(DEFAULT_KUBEADM_ARTIFACT_COMPONENTS),
                "artifact_components_exclude": [],
                "mode": "hybrid",
            },
        },
        "addons": {
            "istio": {
                "enabled": False,
                "profile": "minimal",
            },
        },
        "logging": {
            "level": "INFO",
            "format": "text",
        },
    }
    if distribution == "kubeadm":
        example["cluster"] |= {
            "control_plane_count": 3,
            "worker_count": 0,
            "network_plugin": "flannel",
            "api_lb_ip": "198.19.0.5",
            "api_lb_port": 6443,
            "kubernetes_version": "v1.36.1",
        }
    else:
        example["cluster"] |= {
            "server_count": 1,
            "agent_count": 2,
            "k3s_version": "v1.36.1+k3s1",
        }
        example["firecracker"] |= {
            "kernel_source": "provided",
            "kernel_path": "/opt/firecracker-sandbox-lab/vmlinux.bin",
            "base_rootfs_path": "/opt/firecracker-sandbox-lab/rootfs.ext4",
        }
    print(json.dumps(example, indent=2, sort_keys=True))


def validate_spec(spec: dict[str, Any]) -> None:
    distro = spec["cluster"]["distribution"]
    kernel_source = deep_get(spec, "firecracker.kernel_source", "linuxkit")
    if kernel_source not in {"linuxkit", "provided"}:
        raise ValueError("firecracker.kernel_source must be linuxkit or provided")
    if kernel_source == "provided" and not deep_get(spec, "firecracker.kernel_path"):
        raise ValueError("firecracker.kernel_path is required when firecracker.kernel_source=provided")
    if distro == "k3s" and kernel_source != "provided":
        raise ValueError("k3s currently requires firecracker.kernel_source=provided")
    kernel_path = deep_get(spec, "firecracker.kernel_path", "")
    if kernel_path and not isinstance(kernel_path, str):
        raise ValueError("firecracker.kernel_path must be a string")
    initrd_path = deep_get(spec, "firecracker.initrd_path", "")
    if initrd_path and not isinstance(initrd_path, str):
        raise ValueError("firecracker.initrd_path must be a string")
    kernel_params = deep_get(spec, "firecracker.kernel_params", [])
    if not isinstance(kernel_params, list) or not all(isinstance(item, str) and item for item in kernel_params):
        raise ValueError("firecracker.kernel_params must be an array of non-empty strings")
    kernel_boot_args = deep_get(spec, "firecracker.kernel_boot_args", "")
    if not isinstance(kernel_boot_args, str):
        raise ValueError("firecracker.kernel_boot_args must be a string")
    linuxkit_kernel_image = deep_get(spec, "firecracker.linuxkit_kernel_image", "")
    if kernel_source == "linuxkit" and (not isinstance(linuxkit_kernel_image, str) or not linuxkit_kernel_image):
        raise ValueError("firecracker.linuxkit_kernel_image must be a non-empty string")
    if distro == "kubeadm" and spec["cluster"]["control_plane_count"] != 3:
        raise ValueError("kubeadm mode currently requires cluster.control_plane_count=3")
    if distro == "k3s" and spec["cluster"]["server_count"] < 1:
        raise ValueError("k3s mode requires cluster.server_count >= 1")
    if not deep_get(spec, "release.enabled", False):
        return
    if distro != "kubeadm":
        raise ValueError("artifact-backed release inputs are currently supported only for kubeadm")
    source = deep_get(spec, "release.package_repository.source", "none")
    if source not in {"github_run_artifact", "local_dir", "remote_existing"}:
        raise ValueError("release.package_repository.source must be github_run_artifact, local_dir, or remote_existing")
    artifact_layout = deep_get(spec, "release.package_repository.artifact_layout", "auto")
    if artifact_layout not in {"auto", "prebuilt_repo", "component_packages"}:
        raise ValueError("release.package_repository.artifact_layout must be auto, prebuilt_repo, or component_packages")
    mode = deep_get(spec, "release.package_repository.mode", "hybrid")
    if mode not in {"hybrid", "strict"}:
        raise ValueError("release.package_repository.mode must be hybrid or strict")
    if source == "github_run_artifact" and not deep_get(spec, "release.github_run.run_id"):
        raise ValueError("release.github_run.run_id is required for github_run_artifact package repositories")
    if source == "local_dir" and not deep_get(spec, "release.package_repository.local_dir"):
        raise ValueError("release.package_repository.local_dir is required for local_dir package repositories")
    if source == "remote_existing" and not deep_get(spec, "release.package_repository.remote_root"):
        raise ValueError("release.package_repository.remote_root is required for remote_existing package repositories")
    artifact_components = deep_get(spec, "release.package_repository.artifact_components", [])
    artifact_components_exclude = deep_get(spec, "release.package_repository.artifact_components_exclude", [])
    if not isinstance(artifact_components, list) or not all(isinstance(item, str) and item for item in artifact_components):
        raise ValueError("release.package_repository.artifact_components must be an array of non-empty strings")
    if not isinstance(artifact_components_exclude, list) or not all(isinstance(item, str) and item for item in artifact_components_exclude):
        raise ValueError("release.package_repository.artifact_components_exclude must be an array of non-empty strings")
    trusted = deep_get(spec, "release.package_repository.trusted")
    if trusted not in {None, True, False}:
        raise ValueError("release.package_repository.trusted must be true, false, or null")
    if deep_get(spec, "addons.istio.enabled", False):
        if distro != "kubeadm":
            raise ValueError("addons.istio is currently supported only for kubeadm")
        if deep_get(spec, "addons.istio.profile", "") == "":
            raise ValueError("addons.istio.profile must not be empty")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    for name in ("apply", "delete", "status", "validate"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--spec", required=True)
        cmd.add_argument("--log-format", choices=("text", "json"))
        cmd.add_argument("--log-level")
        cmd.add_argument("--log-file")

    example = sub.add_parser("render-example")
    example.add_argument("--distribution", choices=("kubeadm", "k3s"), default="kubeadm")

    args = parser.parse_args()
    if args.command == "render-example":
        render_example(args.distribution)
        return 0

    ensure_cmd("bash")
    ensure_cmd("ssh")
    ensure_cmd("scp")
    spec_path = Path(args.spec).expanduser().resolve()
    raw_spec = load_json(spec_path)
    output_dir = Path(deep_get(raw_spec, "paths.local_output_dir", default_output_dir(raw_spec))).expanduser().resolve()
    spec = normalize_spec(raw_spec, output_dir)
    if args.log_format:
        spec["logging"]["format"] = args.log_format
    if args.log_level:
        spec["logging"]["level"] = args.log_level
    if args.log_file:
        spec["logging"]["file"] = args.log_file
    configure_logging(spec["logging"]["level"], spec["logging"]["format"], Path(spec["logging"]["file"]))
    output_dir.mkdir(parents=True, exist_ok=True)
    enrich_from_github_run(spec, output_dir)
    validate_spec(spec)
    resolved_path = output_dir / "resolved-spec.json"
    resolved_path.write_text(json.dumps(spec, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.command == "validate":
        log.info("spec is valid")
        return 0

    if args.command == "apply":
        maybe_run_k8s_release(spec, output_dir)
    execute_engine(spec, args.command, output_dir)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        log.error("command failed: %s", exc)
        raise SystemExit(exc.returncode)
    except Exception as exc:
        log.error("%s", exc)
        raise SystemExit(1)
