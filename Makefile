.DEFAULT_GOAL := help

# Ensure the output directory exists
all: $(shell mkdir -p output)

# Use Kubernetes as the builder backend via Buildx
# Set to 1 to enable Kubernetes-based distributed builds using Buildx.
# Set to 0 to disable Kubernetes and use the default Docker builder.
KUBE_BUILDER ?= 0

# Define the Kubernetes version to use
KUBE_VERSION ?= v1.36.1
PROJECT_VERSION ?= $(shell cat VERSION 2>/dev/null || echo 1.0.0)
KUBE_AIRGAP_BUNDLE ?= k8s-$(KUBE_VERSION)-airgap.tar
PREVIOUS_KUBE_VERSION ?=
RELEASE_PROOF_MATRIX ?= docs/release-proof-matrix.example.json

# Define the etcd version to use
ETCD_VERSION ?= v3.6.11


KUBE_GIT_URL ?= https://github.com/kubernetes/kubernetes.git

# Define the Flannel version to use
FLANNEL_VERSION ?= v0.28.4
FLANNEL_GIT_URL ?= https://github.com/flannel-io/flannel.git

# Define the Calico version to use
CALICO_VERSION ?= v3.32.0
CALICO_GIT_URL ?= https://github.com/projectcalico/calico.git

# Define the certificate version to use
CERT_VERSION ?= 1.0.0

# Digest-pinned build inputs. Override these when moving to a new upstream toolchain.
KUBE_GO_IMAGE ?= golang:1.23.3-bookworm@sha256:59b8183301af6dc358c9258d7b2ab0ee1a9363618552334fb3b160d454cbda72
ETCD_GO_IMAGE ?= golang:1.20-bookworm@sha256:9fa9101141c01e9440216d32eb2b380b3c3079bea07aeab3546020cc91b3662c
FLANNEL_GO_IMAGE ?= golang:1.23.3-bookworm@sha256:59b8183301af6dc358c9258d7b2ab0ee1a9363618552334fb3b160d454cbda72
CALICO_GO_IMAGE ?= golang:1.22-bookworm@sha256:3d699e4d15d0f8f13c9195c0632a16702b8cbdece2955af1c23b37ae5d55a253
RUNTIME_IMAGE ?= debian:bookworm-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252
DEBIAN_SNAPSHOT ?= 20260401T000000Z
DOCKER_RETRY_ATTEMPTS ?= 3
DOCKER_RETRY_DELAY_SECONDS ?= 15

# Package metadata and reproducibility controls.
PKG_MAINTAINER ?= Kubernetes Packager <maintainer@example.com>
PKG_LICENSE ?= Apache-2.0
PKG_URL ?= https://kubernetes.io
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || date +%s)

# Help target: Displays available targets and variables
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  help                    Display this help message"
	@echo "  build                   Perform a simple build using Buildx (all components)"
	@echo "  build-certificates      Build only certificates"
	@echo "  build-no-cache          Perform a simple build using Buildx without cache"
	@echo "  build-kube-proxy        Build only kube-proxy"
	@echo "  build-kubelet           Build only kubelet"
	@echo "  build-etcd              Build only etcd"
	@echo "  build-kube-scheduler    Build only kube-scheduler"
	@echo "  build-kube-controller-manager Build only kube-controller-manager"
	@echo "  build-kube-apiserver    Build only kube-apiserver"
	@echo "  build-kubectl           Build only kubectl"
	@echo "  build-flannel           Build only flannel"
	@echo "  build-calico            Build only calico"
	@echo "  check-pinned-inputs     Verify Dockerfiles use digest-pinned base images"
	@echo "  verify-packages         Verify packages in the output directory"
	@echo "  smoke-install-packages  Install generated packages in clean containers"
	@echo "  node-start-smoke        Start installed packages in a node smoke container"
	@echo "  create-package-repos    Create signed apt/yum repositories from output"
	@echo "  release-evidence        Write release evidence for generated output"
	@echo "  release-passport        Write a release passport for generated output"
	@echo "  airgap-bundle           Create an offline bundle with artifacts, repos, install helpers, and policy"
	@echo "  verify-bundle           Verify an offline bundle"
	@echo "  verify-proof            Verify a replayable release proof"
	@echo "  verify-release          Verify a release artifact set"
	@echo "  prove-release           Run the one-command release proof engine"
	@echo "  prove-matrix            Build and prove release combinations from a config file"
	@echo "  airgap-import           Verify and import an airgap bundle into AIRGAP_REPO"
	@echo "  version                 Print the project version"
	@echo "  bump-major              Bump the project major version"
	@echo "  continuous-improvement  Score release readiness against the project spec"
	@echo "  archive                 Create a git archive with branch and commit in the name"
	@echo "  bundle                  Create a git bundle with branch and commit in the name"
	@echo "  clean                   Clean up generated files"
	@echo "  release                 Create a project Git tag and GitHub release"
	@echo ""
	@echo "Variables:"
	@echo "  FLANNEL_GIT_URL         Flannel Git repository URL (default: https://github.com/flannel-io/flannel.git)"
	@echo "  FLANNEL_VERSION         Flannel version to use (default: v0.28.4)"
	@echo "  CALICO_GIT_URL          Calico Git repository URL (default: https://github.com/projectcalico/calico.git)"
	@echo "  CALICO_VERSION          Calico version to use (default: v3.32.0)"
	@echo "  CERT_VERSION            Certificate version to use (default: 1.0.0)"
	@echo "  KUBE_GIT_URL            Kubernetes Git repository URL (default: https://github.com/kubernetes/kubernetes.git)"
	@echo "  KUBE_BUILDER            Use Kubernetes to build images (default: 0, set to 1 to enable)"
	@echo "  KUBE_BUILDER_ARM64      Use Kubernetes ARM64 builder (default: 0, set to 1 to enable)"
	@echo "  KUBE_VERSION            Kubernetes version to use (default: v1.36.1)"
	@echo "  KUBE_AIRGAP_BUNDLE      Airgap bundle path (default: k8s-$(KUBE_VERSION)-airgap.tar)"
	@echo "  PREVIOUS_KUBE_VERSION   Previous Kubernetes version for upgrade proof"
	@echo "  RELEASE_PROOF_MATRIX    JSON matrix file for prove-matrix"
	@echo "  AIRGAP_REPO             Local mirror directory for airgap-import"
	@echo "  PROJECT_VERSION         Project release version (default: $(PROJECT_VERSION))"
	@echo "  ETCD_VERSION            Etcd version to use (default: v3.6.11)"
	@echo "  PACKAGE_TYPE            Package type to build (deb, rpm, or all; default: deb)"
	@echo "  COMPOSE_DOCKER_CLI_BUILD Enable Docker CLI build (set to 1)"
	@echo "  DOCKER_BUILDKIT          Enable BuildKit for Docker builds (set to 1)"
	@echo "  KUBE_GO_IMAGE            Digest-pinned Go image for Kubernetes builds"
	@echo "  ETCD_GO_IMAGE            Digest-pinned Go image for etcd builds"
	@echo "  FLANNEL_GO_IMAGE         Digest-pinned Go image for Flannel builds"
	@echo "  CALICO_GO_IMAGE          Digest-pinned Go image for Calico builds"
	@echo "  RUNTIME_IMAGE            Digest-pinned runtime/package image"
	@echo "  DEBIAN_SNAPSHOT          Debian snapshot timestamp for apt package resolution"
	@echo "  DOCKER_RETRY_ATTEMPTS    Retry count for Docker build/up commands (default: 3)"
	@echo "  DOCKER_RETRY_DELAY_SECONDS Retry delay between Docker retries in seconds (default: 15)"
	@echo "  SOURCE_DATE_EPOCH        Timestamp used for reproducible package metadata"
	@echo "  PKG_MAINTAINER           Maintainer string embedded into packages"
	@echo ""

# Check if required tools are installed and functional
check-tools:
	@echo "Checking if required tools are installed..."
	@command -v docker >/dev/null 2>&1 || { echo >&2 "Error: Docker is not installed or not in PATH."; exit 1; }
	@docker --version >/dev/null 2>&1 || { echo >&2 "Error: Docker is not functioning correctly."; exit 1; }
	@docker compose version >/dev/null 2>&1 || { echo >&2 "Error: Docker Compose is not installed or not functioning correctly."; exit 1; }
	@docker buildx version >/dev/null 2>&1 || { echo >&2 "Error: Docker Buildx is not installed or not functioning correctly."; exit 1; }
	@echo "All required tools are installed and functional."

.PHONY: check-pinned-inputs
check-pinned-inputs:
	@./scripts/check-pinned-inputs.sh

.PHONY: verify-packages
verify-packages:
	@./scripts/verify-packages.sh output

.PHONY: smoke-install-packages
smoke-install-packages:
	@./scripts/smoke-install-packages.sh output

.PHONY: node-start-smoke
node-start-smoke:
	@./scripts/node-start-smoke-packages.sh output

.PHONY: create-package-repos
create-package-repos:
	@./scripts/create-package-repositories.sh output package-repositories

.PHONY: release-evidence
release-evidence:
	@./scripts/generate-release-evidence.sh output package-repositories release-evidence.md

.PHONY: release-passport
release-passport:
	@./scripts/generate-release-passport.sh $(KUBE_VERSION) --artifacts release-artifacts --repos package-repositories --output release-artifacts/release-passport.md

.PHONY: airgap-bundle
airgap-bundle:
	@./scripts/create-airgap-bundle.sh $(KUBE_VERSION) --airgap --artifacts release-artifacts --repos package-repositories --output $(KUBE_AIRGAP_BUNDLE)

.PHONY: verify-bundle
verify-bundle:
	@./scripts/verify-bundle.sh $(KUBE_AIRGAP_BUNDLE)

.PHONY: verify-proof
verify-proof:
	@./scripts/verify-proof.sh release-artifacts/release-proof.json

.PHONY: verify-release
verify-release:
	@./scripts/verify-release.sh $(KUBE_VERSION)

.PHONY: prove-release
prove-release:
	@args=""; \
	if [ -n "$(PREVIOUS_KUBE_VERSION)" ]; then args="$$args --previous $(PREVIOUS_KUBE_VERSION)"; fi; \
	./scripts/prove-release.sh "$(KUBE_VERSION)" $$args

.PHONY: prove-matrix
prove-matrix:
	@./scripts/prove-release-matrix.sh --config "$(RELEASE_PROOF_MATRIX)"

.PHONY: airgap-import
airgap-import:
	@[ -n "$(AIRGAP_REPO)" ] || { echo "ERROR: AIRGAP_REPO is required."; exit 2; }
	@./scripts/airgap.sh import "$(KUBE_AIRGAP_BUNDLE)" --repo "$(AIRGAP_REPO)"

.PHONY: version
version:
	@cat VERSION

.PHONY: bump-major
bump-major:
	@./scripts/bump-project-version.sh major

.PHONY: bump-minor
bump-minor:
	@./scripts/bump-project-version.sh minor

.PHONY: bump-patch
bump-patch:
	@./scripts/bump-project-version.sh patch

.PHONY: continuous-improvement
continuous-improvement:
	@./scripts/continuous-improvement.sh --output continuous-improvement-report.md

# Define BUILD_INFO to calculate and display build duration
define BUILD_INFO
    @echo "Build completed at: $$(date '+%Y-%m-%d %H:%M:%S')"
    @echo "Total build time: $$(($$(date +%s) - $(START_TIME))) seconds"
endef

# Switch to the appropriate Buildx builder based on KUBE_BUILDER or KUBE_BUILDER_ARM64
switch-builder:
ifeq ($(KUBE_BUILDER_ARM64),1)
	@echo "Switching to Kubernetes ARM64 Buildx builder..."
	@docker buildx use kube-build-farm-arm64 || { echo >&2 "Error: Kubernetes ARM64 Buildx builder not found."; exit 1; }
else ifeq ($(KUBE_BUILDER),1)
	@echo "Switching to Kubernetes Buildx builder..."
	@docker buildx use kube-build-farm || { echo >&2 "Error: Kubernetes Buildx builder not found."; exit 1; }
else
	@echo "Switching to default Buildx builder..."
	@docker buildx use default
endif

# Define the default platform based on $KUBE_BUILDER
ifeq ($(KUBE_BUILDER_ARM64),1)
    DOCKER_DEFAULT_PLATFORM := linux/arm64
    DEFAULT_PKG_ARCH := arm64
else
    DOCKER_DEFAULT_PLATFORM := linux/amd64
    DEFAULT_PKG_ARCH := amd64
endif

PKG_ARCH ?= $(DEFAULT_PKG_ARCH)

# Define the package type (deb or rpm)
PACKAGE_TYPE ?= deb

# Check if docker compose v2 is available, otherwise use docker-compose
DOCKER_COMPOSE := $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; else echo "docker-compose"; fi)

# Multi-line variable for docker-compose arguments
define DOCKER_ARGS
    KUBE_VERSION=$(KUBE_VERSION) \
    KUBE_GIT_URL=$(KUBE_GIT_URL) \
    ETCD_VERSION=$(ETCD_VERSION) \
    COMPOSE_DOCKER_CLI_BUILD=1 \
    DOCKER_BUILDKIT=1 \
    FLANNEL_GIT_URL=$(FLANNEL_GIT_URL) \
    FLANNEL_VERSION=$(FLANNEL_VERSION) \
    CALICO_GIT_URL=$(CALICO_GIT_URL) \
    CALICO_VERSION=$(CALICO_VERSION) \
    KUBE_GO_IMAGE='$(KUBE_GO_IMAGE)' \
    ETCD_GO_IMAGE='$(ETCD_GO_IMAGE)' \
    FLANNEL_GO_IMAGE='$(FLANNEL_GO_IMAGE)' \
    CALICO_GO_IMAGE='$(CALICO_GO_IMAGE)' \
    RUNTIME_IMAGE='$(RUNTIME_IMAGE)' \
    DEBIAN_SNAPSHOT=$(DEBIAN_SNAPSHOT) \
    SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
    PKG_MAINTAINER='$(PKG_MAINTAINER)' \
    PKG_LICENSE='$(PKG_LICENSE)' \
    PKG_URL='$(PKG_URL)' \
    PKG_ARCH=$(PKG_ARCH) \
    DOCKER_DEFAULT_PLATFORM=$(DOCKER_DEFAULT_PLATFORM) \
    PACKAGE_TYPE=$(PACKAGE_TYPE)
endef

# If KUBE_BUILDER is set to 1, use buildx Kubernetes build farm
build: switch-builder
	@echo "Starting simple build process..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up
	@$(BUILD_INFO)

# Perform a build without using the cache
build-no-cache: switch-builder
	@echo "Starting build process without cache..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build --no-cache
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up
	@$(BUILD_INFO)

# Variables
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
GIT_COMMIT := $(shell git rev-parse --short HEAD)

# Target: Create git archive
.PHONY: archive
archive:
	@echo "Creating git archive..."
	git archive --format=tar.gz --output=archive-$(GIT_BRANCH)-$(GIT_COMMIT).tar.gz HEAD
	@echo "Archive created: archive-$(GIT_BRANCH)-$(GIT_COMMIT).tar.gz"

# Target: Create git bundle
.PHONY: bundle
bundle:
	@echo "Creating git bundle..."
	git bundle create bundle-$(GIT_BRANCH)-$(GIT_COMMIT).bundle --all
	@echo "Bundle created: bundle-$(GIT_BRANCH)-$(GIT_COMMIT).bundle"

# Clean up generated files
.PHONY: clean
clean:
	@rm -f archive-*.tar.gz bundle-*.bundle

# Individual component build targets
.PHONY: build-kube-proxy
build-kube-proxy: switch-builder
	@echo "Building kube-proxy..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build kube-proxy-builder
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up kube-proxy-builder
	@$(BUILD_INFO)

.PHONY: build-kubelet
build-kubelet: switch-builder
	@echo "Building kubelet..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build kubelet-builder
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up kubelet-builder
	@$(BUILD_INFO)

.PHONY: build-etcd
build-etcd: switch-builder
	@echo "Building etcd..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build etcd-builder
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up etcd-builder
	@$(BUILD_INFO)

.PHONY: build-kube-scheduler
build-kube-scheduler: switch-builder
	@echo "Building kube-scheduler..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build kube-scheduler-builder
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up kube-scheduler-builder
	@$(BUILD_INFO)

.PHONY: build-kube-controller-manager
build-kube-controller-manager: switch-builder
	@echo "Building kube-controller-manager..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build kube-controller-manager-builder
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up kube-controller-manager-builder
	@$(BUILD_INFO)

.PHONY: build-kube-apiserver
build-kube-apiserver: switch-builder
	@echo "Building kube-apiserver..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build kube-apiserver-builder
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up kube-apiserver-builder
	@$(BUILD_INFO)

.PHONY: build-kubectl
build-kubectl: switch-builder
	@echo "Building kubectl..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build kubectl-builder
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up kubectl-builder
	@$(BUILD_INFO)

.PHONY: build-flannel
build-flannel: switch-builder
	@echo "Building flannel..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build flannel-builder
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up flannel-builder
	@$(BUILD_INFO)

.PHONY: build-calico
build-calico: switch-builder
	@echo "Building calico..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build calico-builder
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up calico-builder
	@$(BUILD_INFO)

.PHONY: build-certificates
build-certificates: switch-builder
	@echo "Building certificates..."
	@$(eval START_TIME := $(shell date +%s))
	$(DOCKER_ARGS) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) build certificates-builder
	$(DOCKER_ARGS) CERT_VERSION=$(CERT_VERSION) ./scripts/run-with-retries.sh --attempts $(DOCKER_RETRY_ATTEMPTS) --delay $(DOCKER_RETRY_DELAY_SECONDS) $(DOCKER_COMPOSE) up certificates-builder
	@$(BUILD_INFO)

# Target: Create a Git tag and release on GitHub
.PHONY: release
release:
	@echo "Creating Git tag and releasing on GitHub..."
	@release_version="$${RELEASE_VERSION:-project-v$(PROJECT_VERSION)}"; \
	git tag -a "$$release_version" -m "Project release $(PROJECT_VERSION)"; \
	git push origin "$$release_version"; \
	gh release create "$$release_version" --generate-notes; \
	echo "Release $$release_version created and pushed to GitHub."
