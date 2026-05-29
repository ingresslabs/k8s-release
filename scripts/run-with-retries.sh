#!/usr/bin/env bash
set -euo pipefail

attempts=3
delay_seconds=15

while [ "$#" -gt 0 ]; do
    case "$1" in
        --attempts)
            attempts=${2:?--attempts requires a value}
            shift 2
            ;;
        --delay)
            delay_seconds=${2:?--delay requires a value}
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

[ "$#" -gt 0 ] || {
    echo "ERROR: command is required." >&2
    exit 2
}

if ! [[ "${attempts}" =~ ^[0-9]+$ ]] || [ "${attempts}" -lt 1 ]; then
    echo "ERROR: --attempts must be a positive integer." >&2
    exit 2
fi

if ! [[ "${delay_seconds}" =~ ^[0-9]+$ ]] || [ "${delay_seconds}" -lt 0 ]; then
    echo "ERROR: --delay must be a non-negative integer." >&2
    exit 2
fi

attempt=1
while true; do
    if "$@"; then
        exit 0
    fi

    if [ "${attempt}" -ge "${attempts}" ]; then
        echo "ERROR: command failed after ${attempts} attempts: $*" >&2
        exit 1
    fi

    echo "WARN: attempt ${attempt}/${attempts} failed for: $*" >&2
    attempt=$((attempt + 1))
    if [ "${delay_seconds}" -gt 0 ]; then
        sleep "${delay_seconds}"
    fi
done
