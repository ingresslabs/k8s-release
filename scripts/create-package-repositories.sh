#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:-release-artifacts}
repo_dir=${2:-package-repositories}
codename=${REPO_CODENAME:-stable}
origin=${REPO_ORIGIN:-KubeKattle k8s-release}
label=${REPO_LABEL:-Kubernetes Packages}
suite=${REPO_SUITE:-stable}

artifact_dir=$(cd "${artifact_dir}" && pwd)
mkdir -p "${repo_dir}"
repo_dir=$(cd "${repo_dir}" && pwd)

if ! command -v gpg >/dev/null 2>&1; then
    echo "ERROR: gpg is required to sign package repositories."
    exit 1
fi

prepare_signing_key() {
    export GNUPGHOME="${GNUPGHOME:-$(mktemp -d)}"
    chmod 700 "${GNUPGHOME}"

    if [ -n "${REPO_GPG_PRIVATE_KEY:-}" ]; then
        printf '%s\n' "${REPO_GPG_PRIVATE_KEY}" | gpg --batch --import
    elif [ -n "${REPO_GPG_PRIVATE_KEY_FILE:-}" ]; then
        gpg --batch --import "${REPO_GPG_PRIVATE_KEY_FILE}"
    else
        cat > "${GNUPGHOME}/repo-key.conf" <<EOF
Key-Type: RSA
Key-Length: 3072
Name-Real: k8s-release CI Repository
Name-Email: k8s-release@example.invalid
Expire-Date: 0
%no-protection
%commit
EOF
        gpg --batch --generate-key "${GNUPGHOME}/repo-key.conf"
    fi

    fingerprint=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
    if [ -z "${fingerprint}" ]; then
        echo "ERROR: no repository signing key is available."
        exit 1
    fi

    gpg --batch --armor --export "${fingerprint}" > "${repo_dir}/repo-signing-key.asc"
    echo "${fingerprint}"
}

gpg_sign_args=(--batch --yes --local-user)
fingerprint=$(prepare_signing_key)
gpg_sign_args+=("${fingerprint}")
if [ -n "${REPO_GPG_PASSPHRASE:-}" ]; then
    gpg_sign_args=(--batch --yes --pinentry-mode loopback --passphrase "${REPO_GPG_PASSPHRASE}" --local-user "${fingerprint}")
fi

shopt -s nullglob
debs=("${artifact_dir}"/*.deb)
rpms=("${artifact_dir}"/*.rpm)

if [ "${#debs[@]}" -gt 0 ]; then
    debian_dir="${repo_dir}/debian"
    mkdir -p "${debian_dir}/pool/main"
    cp "${debs[@]}" "${debian_dir}/pool/main/"

    mapfile -t deb_arches < <(
        for deb in "${debs[@]}"; do
            dpkg-deb --field "${deb}" Architecture
        done | sort -u
    )

    for arch in "${deb_arches[@]}"; do
        packages_dir="${debian_dir}/dists/${codename}/main/binary-${arch}"
        mkdir -p "${packages_dir}"
        (
            cd "${debian_dir}"
            dpkg-scanpackages -a "${arch}" pool /dev/null > "dists/${codename}/main/binary-${arch}/Packages"
            gzip -9c "dists/${codename}/main/binary-${arch}/Packages" > "dists/${codename}/main/binary-${arch}/Packages.gz"
        )
    done

    cat > "${debian_dir}/apt-release.conf" <<EOF
APT::FTPArchive::Release::Origin "${origin}";
APT::FTPArchive::Release::Label "${label}";
APT::FTPArchive::Release::Suite "${suite}";
APT::FTPArchive::Release::Codename "${codename}";
APT::FTPArchive::Release::Architectures "$(printf '%s ' "${deb_arches[@]}" | sed 's/ $//')";
APT::FTPArchive::Release::Components "main";
EOF

    (
        cd "${debian_dir}"
        apt-ftparchive -c apt-release.conf release "dists/${codename}" > "dists/${codename}/Release"
        gpg "${gpg_sign_args[@]}" --armor --detach-sign -o "dists/${codename}/Release.gpg" "dists/${codename}/Release"
        gpg "${gpg_sign_args[@]}" --clearsign -o "dists/${codename}/InRelease" "dists/${codename}/Release"
        rm apt-release.conf
    )
fi

if [ "${#rpms[@]}" -gt 0 ]; then
    rpm_dir="${repo_dir}/rpm"
    mkdir -p "${rpm_dir}"
    cp "${rpms[@]}" "${rpm_dir}/"
    createrepo_c "${rpm_dir}"
    gpg "${gpg_sign_args[@]}" --armor --detach-sign -o "${rpm_dir}/repodata/repomd.xml.asc" "${rpm_dir}/repodata/repomd.xml"
fi

(
    cd "${repo_dir}"
    find . -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

echo "Signed package repositories written to ${repo_dir}."
