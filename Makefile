.PHONY: sanity-test test test-quick test-secrets test-ci release dev-release clean coverage

MODULE_TESTS := $(shell grep -rl use_ok t/*.t)

sanity-test:
	perl -Ilib -c bin/genesis

test: sanity-test test-quick test-secrets

test-ci: sanity-test
	prove t/*.t

test-quick: sanity-test
	ls t/*.t | grep -v secrets.t | xargs prove

test-secrets: sanity-test
	@echo 'prove t/secrets.t'
	@prove t/secrets.t ; rc=$$? ; for pid in $$(ps | grep '[\.]/t/vaults/vault-' | awk '{print $$1}') ; do kill -TERM $$pid; done ; exit $$rc

release:
	@if [[ -z $$VERSION ]]; then echo >&2 "No VERSION specified in environment; try \`make VERSION=2.0 release'"; exit 1; fi
	@echo "Cutting new Genesis release (v$$VERSION)"
	./pack $$VERSION

dev-release:
	@echo "Cutting new **DEVELOPER** Genesis release"
	./pack

clean:
	rm -f genesis-*

coverage:
	cover -t -make "prove -lv $(MODULE_TESTS)" -ignore_re '(/Legacy.pm|^t/|/JSON/)'
