#!/usr/bin/env bash
set -euo pipefail

version_matrix=${VERSION_MATRIX:-}
kube_version=${KUBE_VERSION:-v1.36.1}
etcd_version=${ETCD_VERSION:-v3.6.11}
flannel_version=${FLANNEL_VERSION:-v0.28.4}
calico_version=${CALICO_VERSION:-v3.32.0}

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to resolve the version matrix."
    exit 1
fi

if [ -n "${version_matrix}" ] && [ "${version_matrix}" != "null" ]; then
    printf '%s' "${version_matrix}" |
        jq -c \
            --arg kube "${kube_version}" \
            --arg etcd "${etcd_version}" \
            --arg flannel "${flannel_version}" \
            --arg calico "${calico_version}" '
            if type != "array" then
              error("version matrix must be a JSON array")
            else
              map(. as $input | {
                kube_version: (.kube_version // $kube),
                etcd_version: (.etcd_version // $etcd),
                flannel_version: (.flannel_version // $flannel),
                calico_version: (.calico_version // $calico)
              } | . + {
                label: ($input.label // ([.kube_version, .etcd_version, .flannel_version, .calico_version] | join("-") | gsub("[^A-Za-z0-9_.-]"; "-")))
              })
            end'
else
    jq -cn \
        --arg kube "${kube_version}" \
        --arg etcd "${etcd_version}" \
        --arg flannel "${flannel_version}" \
        --arg calico "${calico_version}" '
        [{
          label: ([ $kube, $etcd, $flannel, $calico ] | join("-") | gsub("[^A-Za-z0-9_.-]"; "-")),
          kube_version: $kube,
          etcd_version: $etcd,
          flannel_version: $flannel,
          calico_version: $calico
        }]'
fi
