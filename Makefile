.PHONY: dev dev-test signing-test signing-integration-test signing-prepare signing-ci release release-dry-run

# 命令行可覆盖默认值，例如 make release BUMP=minor。
BUMP ?= patch

release:
	@./scripts/release.sh "$(BUMP)"

release-dry-run:
	@./scripts/release.sh "$(BUMP)" --dry-run

# 从当前代码更新 Screenshot Dev，供本地验收，不覆盖日常版。
dev:
	@./scripts/dev.sh

dev-test:
	@python3 scripts/test-install-dev.py

# 检查待公开内容，不暂存、不提交。
public-check:
	@python3 scripts/test-public-content.py
	@python3 scripts/check-public-content.py

signing-test:
	@python3 scripts/test-signing.py

# 会把本项目专用证书写入 GitHub Actions Secrets；不会发布。
signing-ci:
	@python3 scripts/configure-ci-signing.py --upload

# 本机验收：两份内容不同的应用包延续同一签名要求，不安装或上传。
signing-integration-test:
	@python3 scripts/test-signing-integration.py

# 只在本机生成固定发布身份，不上传。
signing-prepare:
	@python3 scripts/configure-ci-signing.py
