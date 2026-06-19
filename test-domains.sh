#!/usr/bin/env bash
# 优选域名连通性/延迟测试（本地/服务器辅助脚本，不参与 Worker 部署）
#
# 测量：从本机【直连】各 Cloudflare 优选域名，到 CF 边缘的 TCP+TLS 握手延迟与成功率。
# 候选池来自同目录的 domains-candidates.txt。
#
# 两种用法：
#   bash test-domains.sh              人类可读报告 + 可粘贴的 directDomains 代码块
#   EMIT_QUALIFIED=1 bash test-domains.sh   只输出达标域名（每行一个），供自动化解析
#
# 重要：请在“客户实际网络环境”（国内、不挂代理）下运行，结果才有参考价值。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAND_FILE="${SCRIPT_DIR}/domains-candidates.txt"
SOURCES_FILE="${SCRIPT_DIR}/candidate-sources.txt"   # 可选：远程候选源URL列表

ATTEMPTS=5          # 每个域名测试次数
CONNECT_TIMEOUT=3   # 单次连接超时（秒）
MAX_TIME=5          # 单次总超时（秒）
PASS_LATENCY=500    # 达标阈值：平均握手延迟（ms）低于此值且成功率100%才算合格
FETCH_TIMEOUT=8     # 拉取远程候选源的超时（秒）
EMIT_QUALIFIED="${EMIT_QUALIFIED:-0}"

if ! command -v curl >/dev/null 2>&1; then
    echo "错误：未找到 curl，请先安装。" >&2
    exit 1
fi
if [ ! -f "$CAND_FILE" ]; then
    echo "错误：候选域名文件不存在: $CAND_FILE" >&2
    exit 1
fi

# 从一段文本里提取“看起来像域名”的候选：取首个字段（空格或逗号分隔），
# 去掉 http(s):// 前缀、路径、端口、#备注，只保留合法主机名，排除纯IP。
extract_domains() {
    tr -d '\r' \
        | grep -vE '^[[:space:]]*(#|$)' \
        | sed -E 's/[[:space:],].*$//; s@^https?://@@; s@/.*$@@; s/:.*$//; s/#.*$//' \
        | grep -E '^[A-Za-z0-9._-]+\.[A-Za-z]{2,}$'
}

# 合并候选池：本地基础列表 + 远程源（若 candidate-sources.txt 配置了URL），去重
collect_candidates() {
    extract_domains < "$CAND_FILE"
    if [ -f "$SOURCES_FILE" ]; then
        while read -r url; do
            [ -z "$url" ] && continue
            case "$url" in \#*) continue ;; esac
            curl -sS --noproxy '*' --max-time "$FETCH_TIMEOUT" "$url" 2>/dev/null | extract_domains \
                || true
        done < "$SOURCES_FILE"
    fi
}

mapfile -t DOMAINS < <(collect_candidates | grep -v '^$' | sort -u)
if [ "${#DOMAINS[@]}" -eq 0 ]; then
    echo "错误：候选池为空。" >&2
    exit 1
fi

# 仅在非 EMIT 模式下输出日志
log() { [ "$EMIT_QUALIFIED" = "1" ] || printf '%s\n' "$*"; }

log "$(printf '%-30s %-20s %8s %12s' '域名' '解析IP' '成功率' '平均握手ms')"
log "----------------------------------------------------------------------------------"

results=()
for d in "${DOMAINS[@]}"; do
    ok=0
    total_ms=0
    ip="-"
    for _ in $(seq 1 "$ATTEMPTS"); do
        out=$(curl -sS --noproxy '*' \
                  --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
                  -o /dev/null \
                  -w '%{time_namelookup} %{time_appconnect} %{remote_ip}' \
                  "https://${d}/" 2>/dev/null)
        if [ $? -eq 0 ]; then
            dns=$(awk '{print $1}' <<<"$out")
            app=$(awk '{print $2}' <<<"$out")
            ipx=$(awk '{print $3}' <<<"$out")
            [ -n "$ipx" ] && ip="$ipx"
            ms=$(awk -v a="$app" -v n="$dns" 'BEGIN{printf "%.0f", (a-n)*1000}')
            ok=$((ok + 1))
            total_ms=$((total_ms + ms))
        fi
    done
    if [ $ok -gt 0 ]; then
        avg=$((total_ms / ok))
        avg_disp="$avg"
    else
        avg=99999
        avg_disp="-"
    fi
    rate=$((ok * 100 / ATTEMPTS))
    log "$(printf '%-30s %-20s %7d%% %12s' "$d" "$ip" "$rate" "$avg_disp")"
    results+=("$avg|$rate|$d|$ip")
done

# EMIT 模式：只输出达标域名（成功率100% 且 延迟<阈值），按延迟升序，供自动化解析
if [ "$EMIT_QUALIFIED" = "1" ]; then
    printf '%s\n' "${results[@]}" | sort -t'|' -k1 -n \
        | awk -F'|' -v th="$PASS_LATENCY" '$2==100 && $1<th {print $3}'
    exit 0
fi

echo
echo "==== 推荐排序（成功率 100%，按握手延迟从低到高）===="
printf '%s\n' "${results[@]}" | sort -t'|' -k1 -n \
    | awk -F'|' '$2==100 {printf "%-30s %-20s 握手%sms\n", $3, $4, $1}'

echo
echo "==== 可直接粘贴到 _worker.js 的 directDomains（成功率100% 且 握手<${PASS_LATENCY}ms）===="
qualified=$(printf '%s\n' "${results[@]}" | sort -t'|' -k1 -n \
    | awk -F'|' -v th="$PASS_LATENCY" '$2==100 && $1<th {printf "    { domain: \"%s\" },  // %sms\n", $3, $1}')
if [ -z "$qualified" ]; then
    echo "（本次没有域名达标，建议放宽 PASS_LATENCY 或补充候选池后重测，不要直接清空 directDomains）"
else
    echo "const directDomains = ["
    echo "$qualified" | sed '$ s/},/}/'
    echo "];"
fi

echo
echo "提示：建议在不同时段（尤其晚高峰）多跑几次，挑【每次都达标】的域名，而不是某一次最快的。"
