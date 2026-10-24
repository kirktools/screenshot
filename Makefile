.PHONY: release release-dry-run

# 命令行可覆盖默认值，例如 make release BUMP=minor。
BUMP ?= patch

release:
	@./scripts/release.sh "$(BUMP)"

release-dry-run:
	@./scripts/release.sh "$(BUMP)" --dry-run
