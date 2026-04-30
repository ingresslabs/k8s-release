#!/usr/bin/env bash
set -euo pipefail

part=${1:-major}
version_file=${VERSION_FILE:-VERSION}
package_file=${PACKAGE_FILE:-package.json}

usage() {
    cat <<'EOF'
Usage:
  scripts/bump-project-version.sh <major|minor|patch>
EOF
}

case "${part}" in
    major|minor|patch) ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "ERROR: unsupported bump '${part}'." >&2
        usage >&2
        exit 2
        ;;
esac

[ -f "${version_file}" ] || {
    echo "ERROR: ${version_file} is missing." >&2
    exit 1
}

current=$(tr -d '[:space:]' < "${version_file}")
if ! printf '%s\n' "${current}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "ERROR: ${version_file} must contain MAJOR.MINOR.PATCH." >&2
    exit 1
fi

IFS=. read -r major minor patch <<EOF
${current}
EOF

case "${part}" in
    major)
        major=$((major + 1))
        minor=0
        patch=0
        ;;
    minor)
        minor=$((minor + 1))
        patch=0
        ;;
    patch)
        patch=$((patch + 1))
        ;;
esac

next="${major}.${minor}.${patch}"
printf '%s\n' "${next}" > "${version_file}"

if [ -f "${package_file}" ]; then
    if command -v jq >/dev/null 2>&1; then
        tmp=$(mktemp)
        jq --arg version "${next}" '.version = $version' "${package_file}" > "${tmp}"
        mv "${tmp}" "${package_file}"
    else
        echo "WARN: jq is unavailable; ${package_file} was not updated." >&2
    fi
fi

printf '%s\n' "${next}"
