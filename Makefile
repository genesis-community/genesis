.PHONY: sanity-test compile-check pod-check pod-check-syntax pod-check-quiet test test-quick test-secrets test-ci unit-tests integration-tests e2e-tests test-all test-manifest release dev-release clean coverage pod-validate-ai pod-validate-changed

# Test manifest-based execution
TEST_MANIFEST ?= t/test-manifest.txt
TESTS ?= t/*/*.t

# Coverage report format (html, json, text)
COVERAGE_REPORT_FORMAT ?= html

compile-check:
	@echo "Checking all Perl modules compile..."
	@failed=0; \
	for pm in $$(find lib -name '*.pm'); do \
		if ! perl -Ilib -c "$$pm" >/dev/null 2>&1; then \
			echo "FAILED: $$pm"; \
			perl -Ilib -c "$$pm"; \
			failed=$$((failed+1)); \
		fi; \
	done; \
	if [ $$failed -eq 0 ]; then \
		echo "All modules compile successfully"; \
	else \
		echo "$$failed module(s) failed to compile"; \
		exit 1; \
	fi

pod-check:
	@echo "Checking POD coverage for all modules..."
	@t/bin/pod-coverage-check

pod-check-syntax:
	@echo "Checking POD coverage and syntax for all modules..."
	@t/bin/pod-coverage-check --syntax

pod-check-quiet:
	@echo "Checking POD coverage (summary only)..."
	@t/bin/pod-coverage-check --quiet

sanity-test: compile-check
	@bash -c 'set -o pipefail; export GENESIS_OUTPUT_COLUMNS=120; perl -Ilib -c bin/genesis && perl -Ilib -- bin/genesis -D ping 2>&1'

coverage:
	SKIP_SECRETS_TESTS=yes cover -t -ignore_re '(/Legacy.pm|/JSON/|/UUID/|^t/.*\.pm)' -report $(COVERAGE_REPORT_FORMAT)

test: sanity-test
	prove -lf $(TESTS)

test-all: sanity-test unit-tests integration-tests e2e-tests

unit-tests: sanity-test
	@echo "Running unit tests (library/module level)..."
	@SKIP_SECRETS_TESTS=yes prove -l $(shell t/bin/parse-manifest $(TEST_MANIFEST) unit-tests)

integration-tests: sanity-test
	@echo "Running integration tests (multi-component)..."
	@prove -l $(shell t/bin/parse-manifest $(TEST_MANIFEST) integration-tests)

e2e-tests: sanity-test
	@echo "Running e2e tests (full workflows)..."
	@prove -l $(shell t/bin/parse-manifest $(TEST_MANIFEST) e2e-tests)

test-all: sanity-test unit-tests integration-tests e2e-tests

test-manifest: sanity-test
	@echo "Running all tests from manifest..."
	@prove -lf $(TESTS)

test-quick: unit-tests

test-secrets: sanity-test
	@echo 'Running secrets e2e test...'
	@prove -l t/e2e-tests/secrets.t ; rc=$$? ; for pid in $$(ps | grep '[\.]/t/vaults/vault-' | awk '{print $$1}') ; do kill -TERM $$pid; done ; exit $$rc

test-isolated: sanity-test
	@echo "Running all tests in isolation..."
	@for x in $$(awk '/\.t$$/{print "t/"$$1}' $(TEST_MANIFEST)); do \
		echo "Testing $$x..."; \
		git clean -xdf t; \
		prove -lv $$x || exit 1; \
	done

release:
	@if [[ -z $(VERSION) ]]; then echo >&2 "No VERSION specified in environment; try \`make VERSION=2.0 release'"; exit 1; fi
	@echo "Cutting new Genesis release (v$(VERSION))"
	./pack $(VERSION)

shipit:
	rm -rf artifacts
	mkdir -p artifacts
	./pack $(VERSION)
	mv genesis-$(VERSION) artifacts/genesis
	artifacts/genesis -v | grep $(VERSION)

dev-release:
	@echo "Cutting new **DEVELOPER** Genesis release"
	./pack

clean:
	rm -f genesis-*

# AI-powered POD documentation validation
# Requires: uv, claude CLI
#
# Usage:
#   make pod-validate-ai                    # Validate all POD modules
#   make pod-validate-ai MODULES="Genesis::Kit Genesis::Env"
#   make pod-validate-changed               # Validate changed files only
#   make pod-validate-changed BASE=main     # Compare to specific branch
pod-validate-ai:
ifdef MODULES
	@t/bin/pod-validate-ai $(MODULES)
else
	@t/bin/pod-validate-ai --all
endif

pod-validate-changed:
	@t/bin/pod-validate-ai --changed --base $(or $(BASE),main)
