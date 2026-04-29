#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:-output}
shopt -s nullglob
debs=("${artifact_dir}"/*.deb)
rpms=("${artifact_dir}"/*.rpm)

if [ "${#debs[@]}" -eq 0 ] && [ "${#rpms[@]}" -eq 0 ]; then
    echo "ERROR: no DEB or RPM artifacts found in ${artifact_dir}."
    exit 1
fi

for deb in "${debs[@]}"; do
    echo "Verifying DEB package: ${deb}"
    dpkg-deb --info "${deb}" >/dev/null
    dpkg-deb --contents "${deb}" >/dev/null
    dpkg-deb --field "${deb}" Package Version Architecture Maintainer >/dev/null
done

if [ "${#rpms[@]}" -gt 0 ]; then
    if ! command -v rpm >/dev/null 2>&1; then
        echo "ERROR: rpm is required to verify RPM packages."
        exit 1
    fi

    for rpm_pkg in "${rpms[@]}"; do
        echo "Verifying RPM package: ${rpm_pkg}"
        rpm --checksig --nosignature "${rpm_pkg}" >/dev/null
        rpm -qip "${rpm_pkg}" >/dev/null
        rpm -qlp "${rpm_pkg}" >/dev/null
    done
fi

echo "Package verification passed for ${artifact_dir}."
