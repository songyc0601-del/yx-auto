# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A single-file Cloudflare Worker (`_worker.js`, ~2100 lines) that generates proxy subscription links. It fetches optimized IPs/domains and formats them into VLESS/Trojan/VMess nodes for clients like Clash, Surge, and Quantumult X. The entire project—request routing, subscription generation, protocol formatting, and the embedded frontend HTML—lives in `_worker.js`. Do not split this into multiple files without a clear justification.

## Commands

```bash
# Syntax check (no runtime, no build tool needed)
node --check _worker.js

# Deploy: copy _worker.js content into Cloudflare Workers & Pages dashboard
```

No package.json, Wrangler, or test suite exists. If you add tooling, document it here.

## Architecture

`_worker.js` is structured top-to-bottom:

1. **Default config** (lines 1–37): global `let` flags (`epd`, `epi`, `egi`, `ev`, `et`, `vm`) and domain/IP lists
2. **Utility functions**: UUID validation, batch line parsing, IP fetching from wetest.vip and GitHub
3. **Node formatters**: `formatNodeName`, `generateLinksFromSource`, `generateTrojanLinksFromSource`, `generateVMessLinksFromSource` — build protocol URLs per IP/domain entry
4. **`collectLinksForSet`** (line 685): aggregates nodes across all enabled sources (preferred domains, dynamic IPs, GitHub IPs) for one user set
5. **`handleSubscriptionRequest`** (line 821): handles a single `/{UUID}/sub` request, calls `collectLinksForSet`, formats output
6. **Output formatters**: `generateClashConfig`, `generateSurgeConfig`, `generateQuantumultConfig`, base64 default
7. **`generateHomePage`** (line 939–1898): returns the full frontend HTML as a template literal (inline CSS + JS)
8. **`export default { fetch }`** (line 1902): routes requests:
   - `GET /` → frontend HTML
   - `GET /{UUID}/sub?domain=…` → single-user subscription
   - `GET /batch/sub?sets=…` → multi-user batch subscription

## Key URL Parameters

Do not rename these — existing subscription URLs depend on them:

| Param | Default | Meaning |
|-------|---------|---------|
| `domain` | — | user's server domain (required) |
| `epd` | yes | enable preferred domains |
| `epi` | yes | enable preferred IPs (wetest.vip) |
| `egi` | yes | enable GitHub IP list |
| `ev` | yes | enable VLESS |
| `et` | no | enable Trojan |
| `mess` | no | enable VMess (not `vm`, which gets blocked) |
| `target` | base64 | output format: `clash`/`surge`/`quantumult` |
| `piu` | — | custom IP source URL |

## 优选域名运维自动化

动态优选IP（`epi`）与GitHub优选IP（`egi`）已在两个订阅入口被**强制关闭**（忽略URL参数），节点只来自 `directDomains` 优选域名列表。配套了一组脚本，在国内常开机器上定时筛选稳定低延迟域名并自动更新：

| 文件 | 作用 |
|------|------|
| `domains-candidates.txt` | 本地候选域名池（每行一个域名，`#` 注释） |
| `candidate-sources.txt` | 可选远程候选源URL列表，默认空；填了会自动拉取合并 |
| `test-domains.sh` | 手动测试：直连测各域名到CF边缘的握手延迟+成功率，输出报告与可粘贴的 `directDomains` 代码块。`EMIT_QUALIFIED=1` 时只输出达标域名（供自动化解析） |
| `auto-update-domains.sh` | cron 入口：多轮测试取交集 → 重写 `_worker.js` 的 `directDomains` → `node --check` 校验 → `git push`（触发 Pages 自动部署） |

**测试原理**：优选域名只作为节点的“连接地址”（进入CF anycast的入口IP），SNI/Host 用的是用户自己的 `domain`。所以衡量标准是「从国内直连到CF边缘的 TCP+TLS 握手延迟」。**必须在国内网络视角运行**，海外视角（GitHub Actions/海外VPS/Worker本身）测出的排序对国内客户无意义。

**部署**：克隆仓库到国内常开机器（如腾讯云Ubuntu，需 `git curl python3 nodejs`，git 配 deploy key 写权限），cron 定时跑 `auto-update-domains.sh`。安全护栏：无达标域名时保持现有列表不变（绝不清空）、语法校验失败自动回滚、无变化不提交、winners 排序避免顺序抖动。

**调参**：阈值在 `test-domains.sh` 顶部（`PASS_LATENCY` 等）；测试轮数在 `auto-update-domains.sh` 的 `ROUNDS`。

## Coding Conventions

- 4-space indentation throughout
- Cloudflare Workers runtime (no Node.js APIs)
- Keep configuration defaults near the top
- Frontend HTML is a template literal inside `generateHomePage`; edit it in-place
- Node naming uses a fixed format: `carrier·location·source·target` — see `formatNodeName` for the exact pattern
- Batch input format: `domain UUID [/path] [displayName]`, comma or space separated
