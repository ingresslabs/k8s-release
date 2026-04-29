#!/usr/bin/env bash
set -euo pipefail

failures=0

while IFS= read -r dockerfile; do
    name=$(basename "${dockerfile}")

    if grep -Eq '^FROM +(golang|debian):' "${dockerfile}"; then
        echo "ERROR: ${dockerfile} uses an unpinned base image in FROM."
        failures=$((failures + 1))
    fi

    if [ "${name}" = "Dockerfile.certificates" ] && grep -Eq '^ARG +RUNTIME_IMAGE=.*@sha256:' "${dockerfile}"; then
        :
    elif grep -Eq '^ARG +GO_IMAGE=.*@sha256:' "${dockerfile}" && grep -Eq '^ARG +RUNTIME_IMAGE=.*@sha256:' "${dockerfile}"; then
        :
    else
        echo "ERROR: ${dockerfile} does not declare digest-pinned image defaults."
        failures=$((failures + 1))
    fi

    if grep -q 'apt-get update' "${dockerfile}" && ! grep -q 'snapshot.debian.org' "${dockerfile}"; then
        echo "ERROR: ${dockerfile} uses apt without configuring snapshot.debian.org."
        failures=$((failures + 1))
    fi
done < <(find . -maxdepth 1 -name 'Dockerfile*' -type f | sort)

if grep -RIn 'golang:1\.20 AS builder\|debian:bullseye-slim\|debian:bookworm-slim$' Dockerfile* docker-compose.yml; then
    echo "ERROR: found legacy floating image references."
    failures=$((failures + 1))
fi

if [ "${failures}" -gt 0 ]; then
    exit 1
fi

echo "All Docker build inputs are digest-pinned."
