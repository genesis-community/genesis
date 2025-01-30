.PHONY: sanity-test test test-quick test-secrets test-ci release dev-release clean coverage

TESTS ?= t/*.t

sanity-test:
	@bash -c 'set -o pipefail; export GENESIS_OUTPUT_COLUMNS=120; perl -Ilib -c bin/genesis && perl -Ilib -- bin/genesis -D ping 2>&1'

coverage:
	SKIP_SECRETS_TESTS=yes cover -t -ignore_re '(/Legacy.pm|/JSON/|/UUID/|^t/.*\.pm)'

test: sanity-test
	prove -lf $(TESTS)

test-all: sanity-test test-quick test-secrets

test-quick: sanity-test
	SKIP_SECRETS_TESTS=yes prove -l t/*.t

test-secrets: sanity-test
	@echo 'prove t/secrets.t'
	@prove -l t/secrets.t ; rc=$$? ; for pid in $$(ps | grep '[\.]/t/vaults/vault-' | awk '{print $$1}') ; do kill -TERM $$pid; done ; exit $$rc

test-isolated: sanity-test
	for x in t/*.t; do git clean -xdf t; prove -lv $$x; done

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
