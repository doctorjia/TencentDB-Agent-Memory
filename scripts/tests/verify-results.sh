#!/usr/bin/env bash
# 结果验证脚本
# 用法: bash verify-results.sh [--session-id <id>]
#
# 检查内容：
#   - L0 对话录制数量
#   - L1 记忆提取数量
#   - L1.5 MMD 文件存在性和内容正确性
#   - node_id 映射情况

set -euo pipefail

# ── 常量 ──
SESSION_ID="${1:-}"
DATE="$(date +%Y-%m-%d)"

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; }

# ── 解析参数 ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id) SESSION_ID="$2"; shift 2 ;;
        --help|-h)
            echo "用法: bash verify-results.sh [--session-id <id>]"
            echo "  --session-id  指定要验证的 session（默认检查最新 session）"
            exit 0
            ;;
        *) shift ;;
    esac
done

echo "============================================"
echo "  TDAI Memory 验证报告"
echo "  日期: $DATE"
if [[ -n "$SESSION_ID" ]]; then
    echo "  Session: $SESSION_ID"
fi
echo "============================================"
echo ""

# ── L0 检查 ──
info "L0（对话录制）检查..."
L0_FILE="${HOME}/.openclaw/memory-tdai/conversations/${DATE}.jsonl"
if [[ -f "$L0_FILE" ]]; then
    L0_COUNT=$(wc -l < "$L0_FILE" | tr -d ' ')
    L0_SIZE=$(du -h "$L0_FILE" | cut -f1)
    ok "L0: ${L0_COUNT} 条消息, ${L0_SIZE}"
else
    warn "L0 文件不存在: $L0_FILE"
    L0_COUNT=0
fi

# ── L1 检查 ──
info "L1（记忆提取）检查..."
L1_FILE="${HOME}/.openclaw/memory-tdai/records/${DATE}.jsonl"
if [[ -f "$L1_FILE" ]]; then
    L1_COUNT=$(wc -l < "$L1_FILE" | tr -d ' ')
    L1_SIZE=$(du -h "$L1_FILE" | cut -f1)

    # 分析 L1 记录类型
    L1_TYPES=$(python3 -c "
import json
with open('$L1_FILE') as f:
    types = {}
    for line in f:
        try:
            obj = json.loads(line)
            t = obj.get('type', 'unknown')
            types[t] = types.get(t, 0) + 1
        except:
            pass
    for t, c in sorted(types.items()):
        print(f'  {t}: {c}')
" 2>/dev/null || echo "  (解析失败)")
    ok "L1: ${L1_COUNT} 条记忆, ${L1_SIZE}"
    echo "$L1_TYPES"
else
    warn "L1 文件不存在: $L1_FILE"
    L1_COUNT=0
fi

# ── L2 检查 ──
info "L2（场景块）检查..."
SCENE_BLOCKS_DIR="${HOME}/.openclaw/memory-tdai/scene_blocks"
if [[ -d "$SCENE_BLOCKS_DIR" ]]; then
    SB_COUNT=$(ls "$SCENE_BLOCKS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
    ok "L2: ${SB_COUNT} 个场景块文件"
    ls -lt "$SCENE_BLOCKS_DIR"/*.md 2>/dev/null | head -5 | while read line; do
        echo "  $line" | awk '{print "  " $NF}'
    done
else
    warn "L2 目录不存在: $SCENE_BLOCKS_DIR"
fi

# ── L1.5 MMD 检查 ──
info "L1.5（MMD）检查..."
MMDS_DIR="${HOME}/.openclaw/context-offload/main/mmds"
if [[ -d "$MMDS_DIR" ]]; then
    MMD_FILES=$(ls "$MMDS_DIR"/*.mmd 2>/dev/null || echo "")
    if [[ -n "$MMD_FILES" ]]; then
        MMD_COUNT=$(echo "$MMD_FILES" | wc -l | tr -d ' ')
        ok "L1.5: ${MMD_COUNT} 个 MMD 文件"
        echo "$MMD_FILES" | while read f; do
            fname=$(basename "$f")
            fsize=$(du -h "$f" | cut -f1)
            # 检查内容质量
            if grep -q "受国家限制" "$f"; then
                echo "    $fname (${fsize}) - ⚠️ 包含错误内容"
            elif grep -q "flowchart TD" "$f"; then
                # macOS grep doesn't support -oP (Perl regex), use python3 instead
                node_count=$(python3 -c "
import re, sys
with open('$f') as fp:
    content = fp.read()
matches = re.findall(r'\b\d{3}-N\d+\b', content)
print(len(set(matches)))
" 2>/dev/null || echo "?")
                echo "    $fname (${fsize}) - ✅ 有效 Mermaid, $node_count 个节点"
            else
                echo "    $fname (${fsize}) - ⚠️ 内容可能异常"
            fi
        done
    else
        warn "无 MMD 文件"
    fi
else
    warn "MMD 目录不存在: $MMDS_DIR"
fi

# ── session 特定 offload 检查 ──
if [[ -n "$SESSION_ID" ]]; then
    info "Session '${SESSION_ID}' offload 检查..."
    OFFLOAD_FILE="${HOME}/.openclaw/context-offload/main/offload-${SESSION_ID}.jsonl"
    if [[ -f "$OFFLOAD_FILE" ]]; then
        ENTRY_COUNT=$(wc -l < "$OFFLOAD_FILE" | tr -d ' ')
        ok "offload: ${ENTRY_COUNT} 条工具调用"
        # node_id 映射分析
        python3 -c "
import json
from collections import Counter
with open('$OFFLOAD_FILE') as f:
    entries = [json.loads(line) for line in f]
node_ids = [e.get('node_id', 'null') for e in entries]
counter = Counter(node_ids)
print('  node_id 分布:')
for nid, cnt in sorted(counter.items(), key=lambda x: str(x[0])):
    print(f'    {nid}: {cnt}')
" 2>/dev/null
    else
        warn "offload 文件不存在: $OFFLOAD_FILE"
    fi
fi

# ── 总结 ──
echo ""
echo "============================================"
echo "  验证总结"
echo "============================================"
echo "  L0 消息: ${L0_COUNT}"
echo "  L1 记忆: ${L1_COUNT}"
echo ""
if [[ -n "$SESSION_ID" ]]; then
    echo "  Session: $SESSION_ID"
    OFFLOAD_FILE="${HOME}/.openclaw/context-offload/main/offload-${SESSION_ID}.jsonl"
    if [[ -f "$OFFLOAD_FILE" ]]; then
        ENTRY_COUNT=$(wc -l < "$OFFLOAD_FILE" | tr -d ' ')
        echo "  offload 工具调用: ${ENTRY_COUNT}"
    fi
fi
echo "============================================"