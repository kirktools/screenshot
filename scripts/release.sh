#!/bin/bash
# 发布入口：本地生成版本提交和标签，由标签推送触发 GitHub Actions。
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
用法：./scripts/release.sh [--patch|--minor|--major] [--dry-run]
默认 --patch。运行即确认正式发布，不再创建待确认草稿。
--dry-run 只预览，不联网、不写文件、不提交、不推送。
需要 git、python3，以及平时 git push 使用的认证；无需本机 gh 登录。
EOF
}
bump=patch
bump_set=0
dry_run=0
for argument in "$@"; do
  case "$argument" in
    --patch|--minor|--major|patch|minor|major)
      if [[ "$bump_set" == 1 ]]; then echo '只能指定一个版本增量。' >&2; exit 2; fi
      bump="${argument#--}"; bump_set=1 ;;
    --dry-run) dry_run=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
fail() { echo "$*" >&2; exit 1; }
[[ "$(git branch --show-current)" == master ]] || fail '请在 master 分支执行发布。'
remote=$(git remote get-url --push origin)
case "$remote" in
  https://github.com/kirktools/screenshot|https://github.com/kirktools/screenshot.git|git@github.com:kirktools/screenshot|git@github.com:kirktools/screenshot.git|ssh://git@github.com/kirktools/screenshot.git) ;;
  *) fail 'origin 推送地址必须为 kirktools/screenshot，避免发错仓库。' ;;
esac
next=$(python3 scripts/bump-version.py "$bump" --dry-run)
tag="v$next"
echo "版本：$(cat VERSION) → $next"
echo "流程：仅修改 VERSION → 提交 → 标签 $tag → 原子推送 master 和标签 → 云端测试、打包、正式发布。"
if [[ "$dry_run" == 1 ]]; then
  [[ -z "$(git status --porcelain)" ]] || echo '注意：实际发布前需先提交或处理工作区改动。'
  echo "将执行：git push --atomic origin HEAD:refs/heads/master refs/tags/$tag"
  exit 0
fi
[[ -z "$(git status --porcelain)" ]] || fail '工作区有未提交内容，请先提交或处理，再发布。'
# 更新只读基线后再生成版本；允许一并推送 master 上已提交的开发改动。
git fetch origin refs/heads/master:refs/remotes/origin/master --tags
git merge-base --is-ancestor origin/master HEAD || fail '本地 master 落后或已分叉，请先同步远端。'
current=$(tr -d '\r\n' < VERSION)
if git rev-parse --verify "refs/tags/v$current" >/dev/null 2>&1; then
  [[ "$(git rev-list -n 1 "v$current")" != "$(git rev-parse HEAD)" ]] || fail '当前提交已打版本标签；若上次推送失败，请重试原标签的原子推送，不要再次递增版本。'
fi
if git show-ref --verify --quiet "refs/tags/$tag"; then fail "标签 $tag 已存在，不会覆盖。"; fi
# 失败时保留本地现场，不重置用户代码，也不自动再次递增。
trap 'echo "发布未完成。请检查 git status、git log 和标签；保留现场，不会自动回滚或重试。" >&2' ERR
python3 scripts/bump-version.py "$bump" >/dev/null
[[ "$(tr -d '\r\n' < VERSION)" == "$next" ]] || fail '版本结果与预览不符，停止发布。'
git add VERSION
git commit -m "chore: release $tag" --only VERSION
[[ -z "$(git status --porcelain)" ]] || fail '提交后出现额外改动，停止打标签；请检查 Git hooks。'
git tag -a "$tag" -m "Kirk Screenshot $tag"
echo "若推送失败，修复原因后重试：git push --atomic origin HEAD:refs/heads/master refs/tags/$tag"
git push --atomic origin HEAD:refs/heads/master "refs/tags/$tag"
trap - ERR
echo '版本和标签已推送。GitHub 正在自动测试、打包并正式发布：'
echo 'https://github.com/kirktools/screenshot/actions/workflows/release.yml'
echo '若云端失败，修复原因后重跑同一次 Actions；不要重跑本脚本或覆盖标签。'
