# kernel-style V=1 build verbosity
ifeq ("$(origin V)", "command line")
  BUILD_VERBOSE = $(V)
endif

ifeq ($(BUILD_VERBOSE),1)
  Q =
else
  Q = @
endif

VERSION = $(shell git describe --dirty --tags --always)
GIT_COMMIT = $(shell git rev-parse HEAD)
K8S_VERSION = v1.18.2
REPO = github.com/operator-framework/operator-sdk
PKGS = $(shell go list ./... | grep -v /vendor/)
TEST_PKGS = $(shell go list ./... | grep -v -E 'github.com/operator-framework/operator-sdk/test/')
SOURCES = $(shell find . -name '*.go' -not -path "*/vendor/*")
# GO_BUILD_ARGS should be set when running 'go build' or 'go install'.
GO_BUILD_ARGS = \
  -gcflags "all=-trimpath=$(shell go env GOPATH)" \
  -asmflags "all=-trimpath=$(shell go env GOPATH)" \
  -ldflags " \
    -X '$(REPO)/version.GitVersion=$(VERSION)' \
    -X '$(REPO)/version.GitCommit=$(GIT_COMMIT)' \
    -X '$(REPO)/version.KubernetesVersion=$(K8S_VERSION)' \
  " \


SCORECARD_TEST_BASE_IMAGE = quay.io/operator-framework/scorecard-test
SCORECARD_TEST_KUTTL_BASE_IMAGE = quay.io/operator-framework/scorecard-test-kuttl

SCORECARD_TEST_IMAGE ?= $(SCORECARD_TEST_BASE_IMAGE)
SCORECARD_TEST_KUTTL_IMAGE ?= $(SCORECARD_TEST_KUTTL_BASE_IMAGE)

SCORECARD_TEST_ARCHES:="amd64" "ppc64le" "s390x" "arm64"
SCORECARD_TEST_KUTTL_ARCHES:="amd64" "ppc64le" "s390x" "arm64"

export CGO_ENABLED:=0
.DEFAULT_GOAL:=help

.PHONY: help
help: ## Show this help screen
	@echo 'Usage: make <OPTIONS> ... <TARGETS>'
	@echo ''
	@echo 'Available targets are:'
	@echo ''
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##############################
# Development                #
##############################

##@ Development

.PHONY: all install

all: format test build/scorecard ## Test and Build the Operator SDK

install: ## Install the binaries
	$(Q)$(GOARGS) go install $(GO_BUILD_ARGS) ./cmd 

# Code management.
.PHONY: format tidy clean cli-doc lint

format: ## Format the source code
	$(Q)go fmt $(PKGS)

tidy: ## Update dependencies
	$(Q)go mod tidy -v

clean: ## Clean up the build artifacts
	$(Q)rm -rf build

lint-dev:  ## Run golangci-lint with all checks enabled (development purpose only)
	./hack/tests/check-lint.sh dev

lint-fix: ## Run golangci-lint automatically fix (development purpose only)
	./hack/tests/check-lint.sh fix

lint: ## Run golangci-lint with all checks enabled in the ci
	./hack/tests/check-lint.sh ci

setup-k8s:
	hack/ci/setup-k8s.sh ${K8S_VERSION}

##############################
# Generate Artifacts         #
##############################

##@ Generate

.PHONY: generate gen-cli-doc gen-changelog

generate: gen-cli-doc  ## Run all non-release generate targets

gen-cli-doc: ## Generate CLI documentation
	./hack/generate/cli-doc/gen-cli-doc.sh

gen-changelog: ## Generate CHANGELOG.md and migration guide updates
	./hack/generate/changelog/gen-changelog.sh

##############################
# Release                    #
##############################

##@ Release

# Build/install/release the SDK.
.PHONY: release_builds release

release_builds := \
	build/scorecard-$(VERSION)-aarch64-linux-gnu \
	build/scorecard-$(VERSION)-x86_64-linux-gnu \
	build/scorecard-$(VERSION)-x86_64-apple-darwin \
	build/scorecard-$(VERSION)-ppc64le-linux-gnu \
	build/scorecard-$(VERSION)-s390x-linux-gnu 

release: clean $(release_builds) $(release_builds:=.asc) ## Release the Operator SDK

build/scorecard-%-aarch64-linux-gnu: GOARGS = GOOS=linux GOARCH=arm64
build/scorecard-%-x86_64-linux-gnu: GOARGS = GOOS=linux GOARCH=amd64
build/scorecard-%-x86_64-apple-darwin: GOARGS = GOOS=darwin GOARCH=amd64
build/scorecard-%-ppc64le-linux-gnu: GOARGS = GOOS=linux GOARCH=ppc64le
build/scorecard-%-s390x-linux-gnu: GOARGS = GOOS=linux GOARCH=s390x
build/scorecard-%-linux-gnu: GOARGS = GOOS=linux

build/%: $(SOURCES) ## Build the operator-sdk binary
	$(Q){ \
	$(GOARGS) go build $(GO_BUILD_ARGS) -o $@ ./cmd; \
	}

build/%.asc: ## Create release signatures for operator-sdk release binaries
	$(Q){ \
	default_key=$$(gpgconf --list-options gpg | awk -F: '$$1 == "default-key" { gsub(/"/,""); print toupper($$10)}'); \
	git_key=$$(git config --get user.signingkey | awk '{ print toupper($$0) }'); \
	if [ "$${default_key}" = "$${git_key}" ]; then \
		gpg --output $@ --detach-sig build/$*; \
		gpg --verify $@ build/$*; \
	else \
		echo "git and/or gpg are not configured to have default signing key $${default_key}"; \
		exit 1; \
	fi; \
	}

# Image scaffold/build/push.
.PHONY: image image-build image-push

image: image-build image-push ## Build and push all images

image-build: image-build-scorecard-test image-build-scorecard-test-kuttl## Build all images

image-push: image-push-scorecard-test ## Push all images

# Scorecard test image scaffold/build/push.
.PHONY: image-build-scorecard-test image-push-scorecard-test image-push-scorecard-test-multiarch

# Scorecard test kuttl image scaffold/build/push.
.PHONY: image-build-scorecard-test-kuttl image-push-scorecard-test-kuttl image-push-scorecard-test-kuttl-multiarch

image-build-scorecard-test:
	./hack/image/build-scorecard-test-image.sh $(SCORECARD_TEST_BASE_IMAGE):dev

image-push-scorecard-test:
	./hack/image/push-image-tags.sh $(SCORECARD_TEST_BASE_IMAGE):dev $(SCORECARD_TEST_IMAGE)-$(shell go env GOARCH)

image-push-scorecard-test-multiarch:
	./hack/image/push-manifest-list.sh $(SCORECARD_TEST_IMAGE) ${SCORECARD_TEST_ARCHES}

image-build-scorecard-test-kuttl:
	./hack/image/build-scorecard-test-kuttl-image.sh $(SCORECARD_TEST_KUTTL_BASE_IMAGE):dev

image-push-scorecard-test-kuttl:
	./hack/image/push-image-tags.sh $(SCORECARD_TEST_KUTTL_BASE_IMAGE):dev $(SCORECARD_TEST_KUTTL_IMAGE)-$(shell go env GOARCH)

image-push-scorecard-test-kuttl-multiarch:
	./hack/image/push-manifest-list.sh $(SCORECARD_TEST_KUTTL_IMAGE) ${SCORECARD_TEST_KUTTL_ARCHES}

##############################
# Tests                      #
##############################

##@ Tests

# Static tests.
.PHONY: test test-sanity test-unit

test: test-unit ## Run the tests

test-sanity: tidy build/operator-sdk lint
	./hack/tests/sanity-check.sh

test-unit: ## Run the unit tests
	$(Q)go test -coverprofile=coverage.out -covermode=count -count=1 -short $(TEST_PKGS)

test-links:
	./hack/check-links.sh

# CI tests.
.PHONY: test-ci

test-ci: test-sanity test-unit install test-subcommand test-e2e ## Run the CI test suite

# Subcommand tests.
.PHONY: test-subcommand test-subcommand-olm-install

test-subcommand: test-subcommand-olm-install

test-subcommand-olm-install:
	./hack/tests/subcommand-olm-install.sh

# E2E tests.
.PHONY: test-e2e test-e2e-go 

test-e2e: test-e2e-go 

test-e2e-go:
	./hack/tests/e2e-go.sh

# Integration tests.
.PHONY: test-integration

test-integration: ## Run integration tests
	./hack/tests/integration.sh
