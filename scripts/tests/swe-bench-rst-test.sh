#!/usr/bin/env bash
# SWE-bench RST + gpt-5.4 offload 测试脚本
# 用法: bash swe-bench-rst-test.sh
#
# 测试内容：
#   - 使用真实 SWE-bench lite JSON 输入（Python literal 格式）
#   - 验证 gpt-5.4 offload 模型正常生成 L1.5 MMD（无"受国家限制"错误）
#   - 检查 offload.jsonl 中 node_id 映射是否正确
#
# session id: swe-bench-rst-002
# 测试 instance: astropy__astropy-14182 (RST writer header_rows 支持)

set -euo pipefail

# ── 常量 ──
SESSION_ID="swe-bench-rst-002"
LOG_DIR="${HOME}/.openclaw/logs"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_FILE="${TEST_DIR}/swe-bench-inputs/astropy-rst.json"

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; }

# ── 环境检查 ──
info "检查前置条件..."
command -v openclaw &>/dev/null || fail "openclaw 未安装"
command -v python3 &>/dev/null || fail "python3 未安装"

# ── 读取 SWE-bench instance ──
if [[ ! -f "$INPUT_FILE" ]]; then
    fail "测试输入文件不存在: $INPUT_FILE"
fi

info "读取 SWE-bench instance..."
python3 << 'PYEOF'
import ast
import sys

with open("/Users/fergusj/TencentDB-Agent-Memory/scripts/tests/swe-bench-inputs/astropy-rst.json") as f:
    data = ast.literal_eval(f.read())

instance = data[0]
print(f"instance_id: {instance['instance_id']}")
print(f"repo: {instance['repo']}")
print(f"FAIL_TO_PASS: {instance.get('FAIL_TO_PASS', 'N/A')}")
print(f"problem_statement (first 300 chars):")
print(instance['problem_statement'][:300])
PYEOF

# ── 构建测试消息 ──
info "构建测试消息..."
TEST_MESSAGE=$(python3 << 'PYEOF'
import ast

with open("/Users/fergusj/TencentDB-Agent-Memory/scripts/tests/swe-bench-inputs/astropy-rst.json") as f:
    data = ast.literal_eval(f.read())

instance = data[0]
instance_id = instance['instance_id']
repo = instance['repo']
problem = instance['problem_statement']

# 构造测试消息，包含完整 problem_statement 和 patch 信息
msg = f"""分析并验证以下 SWE-bench issue:

instance_id: {instance_id}
repo: {repo}
problem_statement: {problem}

请执行以下步骤：
1. 读取仓库中 astropy/io/ascii/rst.py 文件
2. 检查 RST 类的 __init__ 方法是否支持 header_rows 参数
3. 检查 write() 方法是否动态计算分隔线位置
4. 检查 read() 方法是否正确设置 data.start_line
5. 运行 py_compile 验证语法正确性
6. 如果发现缺少 header_rows 支持，说明需要修改的位置

注意：这是 astropy 的 RST 表格写入器，需要支持多行表头（如 header_rows=['name', 'unit']）"""
print(msg)
PYEOF
)

info "发送测试消息到 openclaw agent (session: $SESSION_ID)..."

export OPENCLAW_TDAI_DEBUG=1
export OPENCLAW_DEBUG=1

openclaw agent \
    --session-id "$SESSION_ID" \
    --message "$TEST_MESSAGE" \
    2>&1 | tee "${LOG_DIR}/swe-bench-rst-002-$(date +%Y%m%d-%H%M%S).log"

# ── 等待 L1/L2 触发 ──
info "等待 L1/L2 处理（90s）..."
sleep 90

# ── 结果检查 ──
info "检查结果..."

# 检查 offload 文件
OFFLOAD_FILE="${HOME}/.openclaw/context-offload/main/offload-${SESSION_ID}.jsonl"
if [[ -f "$OFFLOAD_FILE" ]]; then
    ENTRY_COUNT=$(wc -l < "$OFFLOAD_FILE")
    ok "offload: ${ENTRY_COUNT} 条工具调用记录"

    # 检查 node_id 映射
    NODES=$(python3 -c "
import json
with open('$OFFLOAD_FILE') as f:
    entries = [json.loads(line) for line in f]
node_ids = set(e.get('node_id', 'null') for e in entries)
print(f\"node_ids: {sorted(node_ids)}\")
" 2>/dev/null || echo "解析失败")
    echo "  $NODES"
else
    warn "offload 文件不存在: $OFFLOAD_FILE"
fi

# 检查 MMD 文件
MMD_FILE="${HOME}/.openclaw/context-offload/main/mmds/003-fix-sympy-piecewise.mmd"
if [[ -f "$MMD_FILE" ]]; then
    # 检查是否有"受国家限制"错误内容
    if grep -q "受国家限制" "$MMD_FILE"; then
        fail "MMD 内容异常：包含'受国家限制'错误"
    else
        ok "MMD 内容正常（无'受国家限制'错误）"
        # 统计节点数
        NODE_COUNT=$(grep -oP '\b\d{3}-N\d+\b' "$MMD_FILE" | sort -u | wc -l | tr -d ' ')
        ok "MMD 节点数: $NODE_COUNT"
    fi
else
    warn "MMD 文件不存在（可能尚未生成）"
fi

info "测试完成。"