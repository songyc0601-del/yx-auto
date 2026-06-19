#!/usr/bin/env bash
# 定时自动更新 directDomains：测试候选域名 → 重写 _worker.js → git push（触发 Pages 自动部署）
#
# 部署在【国内常开机器】（如腾讯云 Ubuntu），用 cron 每隔几天运行。
# 注意：机房网络视角与家庭宽带有偏差，但远好于海外视角，是优选自动化的常规做法。
#
# 安全设计：
#   - 多轮测试取交集，避免单次抖动误判
#   - 本次无稳定达标域名时，保持现有 directDomains 不变（绝不清空）
#   - 改完先 node --check 语法校验，失败自动回滚
#   - directDomains 无实质变化时不提交

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG="${SCRIPT_DIR}/auto-update.log"
exec >>"$LOG" 2>&1
echo "===== $(date '+%F %T') 开始 ====="

# 防并发
LOCK="${SCRIPT_DIR}/.auto-update.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "已有任务在运行，跳过本次"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# 同步远端，避免与手动改动冲突
if ! git pull --rebase --quiet; then
    echo "git pull 失败，终止本次（请检查仓库状态）"
    exit 1
fi

# 多轮测试，取“每轮都达标”的交集，降低单次网络抖动误判
ROUNDS="${ROUNDS:-3}"
declare -A pass_count
for r in $(seq 1 "$ROUNDS"); do
    echo "--- 第 $r/$ROUNDS 轮测试 ---"
    while read -r dom; do
        [ -n "$dom" ] && pass_count["$dom"]=$(( ${pass_count["$dom"]:-0} + 1 ))
    done < <(EMIT_QUALIFIED=1 bash "${SCRIPT_DIR}/test-domains.sh")
done

# 取所有轮次都达标的域名
winners=()
for dom in "${!pass_count[@]}"; do
    if [ "${pass_count[$dom]}" -eq "$ROUNDS" ]; then
        winners+=("$dom")
    fi
done

if [ "${#winners[@]}" -eq 0 ]; then
    echo "本次无稳定达标域名，保持现有 directDomains 不变，安全退出"
    exit 0
fi

# 排序固定顺序：相同域名集合生成完全相同的结果，避免顺序抖动导致的无意义提交/重部署
mapfile -t winners < <(printf '%s\n' "${winners[@]}" | sort)
echo "稳定达标域名（${#winners[@]} 个）: ${winners[*]}"

# 用 python3 可靠地就地替换 directDomains 代码块（保留其上方注释）
WINNERS_CSV="$(IFS=,; echo "${winners[*]}")"
WINNERS="$WINNERS_CSV" python3 - <<'PY'
import os, re
doms = [d for d in os.environ["WINNERS"].split(",") if d]
lines = ["const directDomains = ["]
for i, d in enumerate(doms):
    sep = "," if i < len(doms) - 1 else ""
    lines.append('    {{ domain: "{}" }}{}'.format(d, sep))
lines.append("];")
block = "\n".join(lines)

path = "_worker.js"
src = open(path, encoding="utf-8").read()
new = re.sub(r"const directDomains = \[.*?\];", lambda _m: block, src, count=1, flags=re.S)
if new != src:
    open(path, "w", encoding="utf-8").write(new)
    print("CHANGED")
else:
    print("UNCHANGED")
PY

# 语法校验（若安装了 node）
if command -v node >/dev/null 2>&1; then
    if ! node --check _worker.js; then
        echo "语法校验失败！回滚 _worker.js，终止"
        git checkout -- _worker.js
        exit 1
    fi
else
    echo "警告：未安装 node，跳过语法校验"
fi

# 无实质变化则不提交
if git diff --quiet -- _worker.js; then
    echo "directDomains 无变化，无需提交"
    exit 0
fi

git add _worker.js
git commit -q -m "Auto-refresh preferred domains from latency test"
if git push -q; then
    echo "已提交并推送，Pages 将自动部署"
else
    echo "git push 失败（请检查推送凭证），改动已本地提交，下次会重试推送"
    exit 1
fi
