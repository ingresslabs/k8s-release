#!/usr/bin/env bash
set -euo pipefail

output_file=continuous-improvement-report.md
strict=0
require_green_package_workflow=0
repo=${GITHUB_REPOSITORY:-}
branch=${GITHUB_REF_NAME:-}

usage() {
    cat <<'EOF'
Usage: scripts/continuous-improvement.sh [--output FILE] [--strict] [--repo OWNER/REPO] [--branch BRANCH]

Generate a release-readiness report against docs/world-class-release-spec.md.

Options:
  --output FILE      Markdown report path (default: continuous-improvement-report.md)
  --strict           Exit non-zero if any required gate fails
  --require-green-package-workflow
                     Fail if the latest package workflow is not green
  --repo OWNER/REPO  GitHub repository for latest CI status lookup
  --branch BRANCH    Branch for latest CI status lookup
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output_file=${2:?--output requires a file}
            shift 2
            ;;
        --strict)
            strict=1
            shift
            ;;
        --require-green-package-workflow)
            require_green_package_workflow=1
            shift
            ;;
        --repo)
            repo=${2:?--repo requires OWNER/REPO}
            shift 2
            ;;
        --branch)
            branch=${2:?--branch requires a branch}
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

if [ -z "${branch}" ]; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
fi

checks_tmp=$(mktemp)
notes_tmp=$(mktemp)
cleanup() {
    rm -f "${checks_tmp}" "${notes_tmp}"
}
trap cleanup EXIT

pass_count=0
warn_count=0
fail_count=0

add_check() {
    local status=$1
    local gate=$2
    local detail=$3

    printf '|%s|%s|%s|\n' "${status}" "${gate}" "${detail}" >> "${checks_tmp}"
    case "${status}" in
        PASS) pass_count=$((pass_count + 1)) ;;
        WARN) warn_count=$((warn_count + 1)) ;;
        FAIL) fail_count=$((fail_count + 1)) ;;
        *) fail_count=$((fail_count + 1)) ;;
    esac
}

add_note() {
    printf -- '- %s\n' "$1" >> "${notes_tmp}"
}

run_gate() {
    local gate=$1
    local command=$2
    local log_file
    log_file=$(mktemp)

    if bash -euo pipefail -c "${command}" >"${log_file}" 2>&1; then
        add_check PASS "${gate}" "Command passed: \`${command}\`."
    else
        add_check FAIL "${gate}" "Command failed: \`${command}\`. See ${log_file}."
        add_note "${gate} failed; inspect ${log_file}."
    fi
}

contains_gate() {
    local gate=$1
    local pattern=$2
    shift 2
    local files=("$@")

    if command -v rg >/dev/null 2>&1; then
        search_cmd=(rg -n "${pattern}" "${files[@]}")
    else
        search_cmd=(grep -R -n -E "${pattern}" "${files[@]}")
    fi

    if "${search_cmd[@]}" >/dev/null 2>&1; then
        add_check PASS "${gate}" "Found \`${pattern}\`."
    else
        add_check FAIL "${gate}" "Missing \`${pattern}\`."
        add_note "Add or repair ${gate}."
    fi
}

file_gate() {
    local gate=$1
    local path=$2

    if [ -f "${path}" ]; then
        add_check PASS "${gate}" "Found \`${path}\`."
    else
        add_check FAIL "${gate}" "Missing \`${path}\`."
        add_note "Create ${path}."
    fi
}

executable_gate() {
    local gate=$1
    local path=$2

    if [ -x "${path}" ]; then
        add_check PASS "${gate}" "\`${path}\` is executable."
    else
        add_check FAIL "${gate}" "\`${path}\` is missing or not executable."
        add_note "Make ${path} executable."
    fi
}

workflow_files=(.github/workflows/*.yml)
shell_files=(package-builder.sh generate-certs.sh k8s-release scripts/*.sh)

file_gate "World-class spec" docs/world-class-release-spec.md
file_gate "Project version" VERSION
file_gate "Release policy" docs/release-policy.md
executable_gate "CLI entrypoint" k8s-release
executable_gate "Install smoke script" scripts/smoke-install-packages.sh
executable_gate "Node start smoke script" scripts/node-start-smoke-packages.sh
executable_gate "Reproducibility compare script" scripts/compare-reproducible-artifacts.sh
executable_gate "Signed repository script" scripts/create-package-repositories.sh
executable_gate "Release evidence script" scripts/generate-release-evidence.sh
executable_gate "Release passport script" scripts/generate-release-passport.sh
executable_gate "Airgap bundle script" scripts/create-airgap-bundle.sh
executable_gate "Airgap ceremony script" scripts/airgap.sh
executable_gate "Airgap bundle verifier" scripts/verify-bundle.sh
executable_gate "One-command release verifier" scripts/verify-release.sh
executable_gate "Release proof engine" scripts/prove-release.sh
executable_gate "L4 release proof runner" scripts/l4-release-proof.sh
executable_gate "Replayable proof verifier" scripts/verify-proof.sh
executable_gate "Project version bump script" scripts/bump-project-version.sh

run_gate "Pinned Docker inputs" "make check-pinned-inputs"
run_gate "Shell syntax" "bash -n ${shell_files[*]}"
run_gate "Whitespace hygiene" "git diff --check"

if command -v ruby >/dev/null 2>&1; then
    run_gate "Workflow YAML parses" "ruby -e 'require \"yaml\"; ARGV.each { |f| YAML.load_file(f) }' ${workflow_files[*]}"
else
    add_check WARN "Workflow YAML parses" "Ruby is unavailable; skipped local YAML parse."
fi

if command -v actionlint >/dev/null 2>&1; then
    run_gate "GitHub Actions lint" "actionlint ${workflow_files[*]}"
elif command -v go >/dev/null 2>&1; then
    actionlint_log=$(mktemp)
    if go run github.com/rhysd/actionlint/cmd/actionlint@latest "${workflow_files[@]}" >"${actionlint_log}" 2>&1; then
        add_check PASS "GitHub Actions lint" "Command passed: \`go run github.com/rhysd/actionlint/cmd/actionlint@latest ${workflow_files[*]}\`."
    else
        add_check WARN "GitHub Actions lint" "Go fallback failed; install \`actionlint\` for a hard local gate. Log: ${actionlint_log}."
        add_note "Install actionlint in the runner image or run it locally before release."
    fi
else
    add_check WARN "GitHub Actions lint" "Neither actionlint nor go is available; skipped actionlint."
fi

contains_gate "Reproducible build job" "reproducible-build" "${workflow_files[@]}"
contains_gate "Checksum comparison job" "compare-reproducibility" "${workflow_files[@]}"
contains_gate "Package install smoke" "smoke-install-packages.sh" "${workflow_files[@]}"
contains_gate "Node start smoke" "node-start-smoke" "${workflow_files[@]}"
contains_gate "Signed apt/yum repositories" "create-package-repositories.sh" "${workflow_files[@]}"
contains_gate "Release evidence generation" "generate-release-evidence.sh" "${workflow_files[@]}"
contains_gate "Release passport generation" "generate-release-passport.sh" "${workflow_files[@]}"
contains_gate "Airgap bundle generation" "create-airgap-bundle.sh" "${workflow_files[@]}"
contains_gate "Airgap bundle verification" "verify-bundle.sh" "${workflow_files[@]}"
contains_gate "SBOM generation" "anchore/sbom-action" "${workflow_files[@]}"
contains_gate "Build provenance attestation" "attest-build-provenance" "${workflow_files[@]}"
contains_gate "Sigstore package signatures" "cosign sign-blob" "${workflow_files[@]}"
contains_gate "Version matrix input" "version_matrix" .github/workflows/build.yml .github/workflows/publish-packages.yml
contains_gate "Fresh cert separation" "cert" scripts/compare-reproducible-artifacts.sh scripts/node-start-smoke-packages.sh
contains_gate "CLI release verification" "verify-release" k8s-release README.md docs/world-class-release-spec.md scripts/verify-release.sh
contains_gate "CLI airgap verification" "verify-bundle" k8s-release README.md docs/world-class-release-spec.md scripts/verify-bundle.sh
contains_gate "CLI release proof" "prove" k8s-release docs/world-class-release-spec.md scripts/prove-release.sh
contains_gate "CLI proof verification" "verify-proof" k8s-release docs/world-class-release-spec.md scripts/verify-proof.sh
contains_gate "Local L4 proof" "local" docs/world-class-release-spec.md scripts/prove-release.sh scripts/l4-release-proof.sh
contains_gate "Policy as code" "release-proof-policy" docs/world-class-release-spec.md docs/release-proof-policy.example.yaml scripts/prove-release.sh
contains_gate "Upgrade rollback proof" "rollback" docs/world-class-release-spec.md docs/release-proof-policy.example.yaml scripts/l4-release-proof.sh
contains_gate "Airgap import ceremony" "airgap import" k8s-release docs/world-class-release-spec.md scripts/airgap.sh
contains_gate "Release passport contract" "release passport" README.md docs/world-class-release-spec.md scripts/generate-release-passport.sh
contains_gate "L4 headline" "Current target: L4" docs/world-class-release-spec.md
contains_gate "Project starts at 1.0.0" "1\\.0\\.0" VERSION package.json docs/release-policy.md README.md
contains_gate "Major-change release bumping" "bump-major" Makefile docs/release-policy.md scripts/bump-project-version.sh
contains_gate "Merge tested work before branch cleanup" "tested work must be merged into.*main" docs/release-policy.md

if command -v gh >/dev/null 2>&1 && [ -n "${repo}" ] && [ -n "${branch}" ]; then
    latest_run=$(gh run list \
        --repo "${repo}" \
        --branch "${branch}" \
        --workflow build.yml \
        --limit 1 \
        --json status,conclusion,url,headSha,createdAt \
        --jq '.[0] | [.status, (.conclusion // ""), .url] | @tsv' 2>/dev/null || true)
	    if [ -n "${latest_run}" ]; then
	        IFS=$'\t' read -r run_status run_conclusion run_url <<< "${latest_run}"
	        if [ -z "${run_status}" ]; then
	            if [ "${require_green_package_workflow}" -eq 1 ]; then
	                add_check FAIL "Latest GitHub package workflow" "No matching run found for ${repo}@${branch}."
	                add_note "Run Build Kubernetes Packages for ${repo}@${branch}."
	            else
	                add_check WARN "Latest GitHub package workflow" "No matching run found for ${repo}@${branch}."
	            fi
	        elif [ "${run_status}" = "completed" ] && [ "${run_conclusion}" = "success" ]; then
	            add_check PASS "Latest GitHub package workflow" "Latest run passed: ${run_url}."
	        elif [ "${run_status}" = "completed" ]; then
	            if [ "${require_green_package_workflow}" -eq 1 ]; then
	                add_check FAIL "Latest GitHub package workflow" "Latest run concluded \`${run_conclusion:-unknown}\`: ${run_url}."
	                add_note "Fix the latest Build Kubernetes Packages run."
	            else
	                add_check WARN "Latest GitHub package workflow" "Latest run concluded \`${run_conclusion}\`: ${run_url}."
	            fi
	        else
	            if [ "${require_green_package_workflow}" -eq 1 ]; then
	                add_check FAIL "Latest GitHub package workflow" "Latest run is \`${run_status}\`: ${run_url}."
	                add_note "Wait for the latest Build Kubernetes Packages run to pass."
	            else
	                add_check WARN "Latest GitHub package workflow" "Latest run is \`${run_status}\`: ${run_url}."
	            fi
	        fi
	    else
	        if [ "${require_green_package_workflow}" -eq 1 ]; then
	            add_check FAIL "Latest GitHub package workflow" "No matching run found for ${repo}@${branch}."
	            add_note "Run Build Kubernetes Packages for ${repo}@${branch}."
	        else
	            add_check WARN "Latest GitHub package workflow" "No matching run found for ${repo}@${branch}."
	        fi
	    fi
	else
	    if [ "${require_green_package_workflow}" -eq 1 ]; then
	        add_check FAIL "Latest GitHub package workflow" "Skipped; gh, repo, or branch unavailable."
	        add_note "Provide gh, --repo, and --branch for the green workflow gate."
	    else
	        add_check WARN "Latest GitHub package workflow" "Skipped; gh, repo, or branch unavailable."
	    fi
	fi

total=$((pass_count + warn_count + fail_count))
score=0
if [ "${total}" -gt 0 ]; then
    score=$((pass_count * 100 / total))
fi

mkdir -p "$(dirname "${output_file}")"
{
    echo "# Continuous Improvement Report"
    echo
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "Branch: ${branch:-unknown}"
    echo
    echo "Spec: docs/world-class-release-spec.md"
    echo
    echo "Score: ${score}% (${pass_count} pass, ${warn_count} warn, ${fail_count} fail)"
    echo
    echo "|Status|Gate|Detail|"
    echo "|---|---|---|"
    cat "${checks_tmp}"
    echo
    echo "## Next Actions"
    echo
    if [ -s "${notes_tmp}" ]; then
        cat "${notes_tmp}"
    else
        echo "- No failed gates. Keep expanding L4 VM/kind cluster upgrade and conformance coverage."
    fi
} > "${output_file}"

echo "Wrote ${output_file}"
echo "Score: ${score}% (${pass_count} pass, ${warn_count} warn, ${fail_count} fail)"

if [ "${strict}" -eq 1 ] && [ "${fail_count}" -gt 0 ]; then
    exit 1
fi
