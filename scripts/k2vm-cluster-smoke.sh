#!/usr/bin/env bash
set -euo pipefail

if [ -f ./.env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

usage() {
    cat <<'EOF'
Usage:
  scripts/k2vm-cluster-smoke.sh <version> --host HOST --artifacts DIR --repos DIR [options]

Uses k2vm.py to run a real remote kubeadm cluster smoke test on a Firecracker
host, stage the current package repositories with local_dir mode, fetch the
resulting artifacts, and emit replayable evidence into the release artifact set.

Options:
  --host HOST                Remote SSH target host; accepts HOST or USER@HOST
  --artifacts DIR            Release artifact directory
  --repos DIR                Package repository directory used for cluster install
  --output-dir DIR           Evidence output directory (default: artifact dir)
  --remote-dir DIR           Remote k2vm working directory
  --keep-remote              Preserve the remote working directory after success
  --package-repo-mode MODE   Package repository mode: hybrid or strict (default: hybrid)
EOF
}

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

version=${1:-}
if [ -z "${version}" ]; then
    usage >&2
    exit 2
fi
shift

tag=${version}
case "${tag}" in
    v*) ;;
    *) tag="v${tag}" ;;
esac

host=
artifact_dir=
repo_dir=
output_dir=
remote_dir=
keep_remote=0
package_repo_mode=hybrid

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            host=${2:?--host requires a value}
            shift 2
            ;;
        --artifacts)
            artifact_dir=${2:?--artifacts requires a directory}
            shift 2
            ;;
        --repos)
            repo_dir=${2:?--repos requires a directory}
            shift 2
            ;;
        --output-dir)
            output_dir=${2:?--output-dir requires a directory}
            shift 2
            ;;
        --remote-dir)
            remote_dir=${2:?--remote-dir requires a directory}
            shift 2
            ;;
        --keep-remote)
            keep_remote=1
            shift
            ;;
        --package-repo-mode)
            package_repo_mode=${2:?--package-repo-mode requires a value}
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "${host}" ] || host=${K8S_RELEASE_PROOF_HOST:-}
[ -n "${host}" ] || { echo "ERROR: --host is required." >&2; exit 2; }
[ -n "${artifact_dir}" ] || { echo "ERROR: --artifacts is required." >&2; exit 2; }
[ -n "${repo_dir}" ] || { echo "ERROR: --repos is required." >&2; exit 2; }

case "${package_repo_mode}" in
    hybrid|strict) ;;
    *)
        echo "ERROR: --package-repo-mode must be hybrid or strict." >&2
        exit 2
        ;;
esac

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

log() {
    printf '==> %s\n' "$*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'
}

need_tool python3
need_tool ssh
need_tool scp
need_tool tar

[ -d "${artifact_dir}" ] || fail "artifact directory not found: ${artifact_dir}"
[ -d "${repo_dir}" ] || fail "package repository directory not found: ${repo_dir}"

artifact_dir=$(cd "${artifact_dir}" && pwd)
repo_dir=$(cd "${repo_dir}" && pwd)

if [ -z "${output_dir}" ]; then
    output_dir=${artifact_dir}
fi
mkdir -p "${output_dir}"
output_dir=$(cd "${output_dir}" && pwd)

ssh_user=root
ssh_host=${host}
if [[ "${host}" == *"@"* ]]; then
    ssh_user=${host%@*}
    ssh_host=${host#*@}
fi

safe_host=$(safe_name "${ssh_host}")
if [ -z "${remote_dir}" ]; then
    remote_dir="/tmp/k2vm/k8s-release-${safe_host}-${tag}"
fi

runtime_dir="${output_dir}/${tag}-${safe_host}-k2vm-cluster-smoke"
spec_path="${runtime_dir}/spec.json"
receipt_out="${output_dir}/${tag}-${safe_host}-cluster-smoke-receipt.json"
artifact_tar="${output_dir}/${tag}-${safe_host}-cluster-smoke-artifacts.tar.gz"

mkdir -p "${runtime_dir}"

python3 - "${spec_path}" "${runtime_dir}" "${ssh_host}" "${ssh_user}" "${remote_dir}" "${repo_dir}" "${tag}" "${package_repo_mode}" <<'PY'
import json
import sys
from pathlib import Path

spec_path = Path(sys.argv[1])
runtime_dir = Path(sys.argv[2])
ssh_host = sys.argv[3]
ssh_user = sys.argv[4]
remote_dir = sys.argv[5]
repo_dir = sys.argv[6]
tag = sys.argv[7]
package_repo_mode = sys.argv[8]

components = [
    "kubelet",
    "kubectl",
    "kube-apiserver",
    "kube-controller-manager",
    "kube-scheduler",
    "kube-proxy",
    "etcd",
    "flannel",
    "istio",
]

spec = {
    "schema_version": "k2vm.spec.v1",
    "name": f"k8s-release-{tag}-{ssh_host}".replace(".", "-"),
    "target": {
        "host": ssh_host,
        "user": ssh_user,
        "workdir": remote_dir,
    },
    "cluster": {
        "distribution": "kubeadm",
        "control_plane_count": 3,
        "worker_count": 0,
        "network_plugin": "flannel",
        "subnet_prefix": "198.19.0",
        "pod_cidr": "10.244.0.0/16",
        "service_cidr": "10.96.0.0/12",
        "api_lb_ip": "198.19.0.5",
        "api_lb_port": 6443,
        "kubernetes_version": tag,
    },
    "firecracker": {
        "binary": "/usr/local/bin/firecracker",
        "bridge_name": "k2vm198",
        "kernel_source": "linuxkit",
        "kernel_params": [],
        "tap_prefix": "k2vm198",
        "linuxkit_kernel_image": "linuxkit/kernel:6.12.59",
    },
    "paths": {
        "local_output_dir": str(runtime_dir),
    },
    "release": {
        "enabled": True,
        "package_repository": {
            "source": "local_dir",
            "local_dir": repo_dir,
            "artifact_layout": "auto",
            "artifact_components": components,
            "artifact_components_exclude": [],
            "mode": package_repo_mode,
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

spec_path.write_text(json.dumps(spec, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

log "Validating k2vm spec"
python3 ./scripts/k2vm.py validate --spec "${spec_path}"

log "Running remote cluster smoke on ${ssh_user}@${ssh_host}"
python3 ./scripts/k2vm.py apply --spec "${spec_path}"

fetched_dir="${runtime_dir}/artifacts"
[ -d "${fetched_dir}" ] || fail "k2vm did not fetch remote artifacts into ${fetched_dir}"

if [ -f "${fetched_dir}/receipt.json" ]; then
    cp "${fetched_dir}/receipt.json" "${receipt_out}"
fi

tar -C "${runtime_dir}" -czf "${artifact_tar}" artifacts resolved-spec.json spec.json

echo "Remote cluster smoke host: ${ssh_user}@${ssh_host}"
echo "Remote cluster smoke workdir: ${remote_dir}"
echo "Fetched artifacts directory: ${fetched_dir}"
echo "Cluster smoke artifact tarball: ${artifact_tar}"
if [ -f "${receipt_out}" ]; then
    echo "Cluster smoke receipt: ${receipt_out}"
    python3 - "${receipt_out}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(json.dumps(data, indent=2, sort_keys=True))
PY
fi
for report in nodes.txt pods.txt services.txt etcd-members.txt smoke-job.log; do
    if [ -f "${fetched_dir}/${report}" ]; then
        echo
        echo "--- ${report} ---"
        sed -n '1,120p' "${fetched_dir}/${report}"
    fi
done

if [ "${keep_remote}" -eq 1 ]; then
    log "Keeping remote k2vm workdir ${remote_dir}"
else
    log "Cleaning remote k2vm workdir ${remote_dir}"
    python3 ./scripts/k2vm.py delete --spec "${spec_path}"
fi
