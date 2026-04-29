#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:-output}
prefix=${2:-}
if [ -n "${prefix}" ]; then
    manifest_path="${artifact_dir}/${prefix}-release-manifest.json"
    checksums_path="${artifact_dir}/${prefix}-SHA256SUMS"
else
    manifest_path="${artifact_dir}/release-manifest.json"
    checksums_path="${artifact_dir}/SHA256SUMS"
fi

shopt -s nullglob
artifacts=("${artifact_dir}"/*.deb "${artifact_dir}"/*.rpm)

if [ "${#artifacts[@]}" -eq 0 ]; then
    echo "ERROR: no DEB or RPM artifacts found in ${artifact_dir}."
    exit 1
fi

sha256sum "${artifacts[@]}" | sed "s#  ${artifact_dir}/#  #" > "${checksums_path}"

{
    printf '{\n'
    printf '  "source_date_epoch": "%s",\n' "${SOURCE_DATE_EPOCH:-}"
    printf '  "artifacts": [\n'
    for index in "${!artifacts[@]}"; do
        artifact=${artifacts[$index]}
        name=$(basename "${artifact}")
        sha=$(sha256sum "${artifact}" | awk '{print $1}')
        size=$(stat -c '%s' "${artifact}" 2>/dev/null || stat -f '%z' "${artifact}")
        comma=","
        if [ "$((index + 1))" -eq "${#artifacts[@]}" ]; then
            comma=""
        fi
        printf '    {"name": "%s", "sha256": "%s", "bytes": %s}%s\n' "${name}" "${sha}" "${size}" "${comma}"
    done
    printf '  ]\n'
    printf '}\n'
} > "${manifest_path}"

echo "Wrote ${checksums_path} and ${manifest_path}."
