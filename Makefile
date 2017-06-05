test:
	prove t/*.t

release:
	@if [[ -z $$VERSION ]]; then echo >&2 "No VERSION specified in environment; try \`make VERSION=2.0 release'"; exit 1; fi
	@echo "Cutting new Genesis release (v$$VERSION)"
	@./pack $$VERSION

dev-release:
	@echo "Cutting new **DEVELOPER** Genesis release"
	@./pack

clean:
	rm -f genesis-*
