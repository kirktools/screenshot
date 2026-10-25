.PHONY: dev dev-test release release-dry-run

# 命令行可覆盖默认值，例如 make release BUMP=minor。
BUMP ?= patch

release:
	@./scripts/release.sh "$(BUMP)"

release-dry-run:
	@./scripts/release.sh "$(BUMP)" --dry-run

# 从当前代码更新固定路径的应用，供本地验收 PR。
dev:
	@./scripts/dev.sh

dev-test:
	@python3 scripts/test-install-dev.py
