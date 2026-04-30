#!/usr/bin/env bash
set -euo pipefail

left_dir=${1:?first artifact directory is required}
right_dir=${2:?second artifact directory is required}

checksum_file() {
    local artifact_dir=$1
    local output_file=$2

    find "${artifact_dir}" -type f \( -name "*.deb" -o -name "*.rpm" \) \
        ! -name "*cert*" -print0 |
        while IFS= read -r -d '' artifact; do
            sha=$(sha256sum "${artifact}" | awk '{print $1}')
            printf '%s  %s\n' "${sha}" "$(basename "${artifact}")"
        done |
        sort -k2,2 > "${output_file}"
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

left_sums="${tmp_dir}/left-SHA256SUMS"
right_sums="${tmp_dir}/right-SHA256SUMS"

checksum_file "${left_dir}" "${left_sums}"
checksum_file "${right_dir}" "${right_sums}"

if [ ! -s "${left_sums}" ]; then
    echo "ERROR: no deterministic DEB/RPM artifacts found in ${left_dir}."
    echo "Certificate packages are intentionally excluded because they contain fresh key material."
    exit 1
fi

if [ ! -s "${right_sums}" ]; then
    echo "ERROR: no deterministic DEB/RPM artifacts found in ${right_dir}."
    echo "Certificate packages are intentionally excluded because they contain fresh key material."
    exit 1
fi

if ! diff -u "${left_sums}" "${right_sums}"; then
    echo "ERROR: reproducibility check failed; artifact checksums differ."
    exit 1
fi

echo "Reproducibility check passed for deterministic packages."
