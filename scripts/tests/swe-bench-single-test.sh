#!/usr/bin/env bash
# SWE-bench 单实例测试脚本
# 用法: bash swe-bench-single-test.sh [--session-id <id>]
#
# 测试内容：
#   - L0 对话录制
#   - L1 记忆提取（l1IdleTimeout 触发）
#   - L1.5 MMD 生成条件（isLongTask 判断）
#   - L2 场景块生成（90s 延迟后）
#
# 前置条件：
#   - openclaw 已安装并配置 memory-tencentdb 插件
#   - context-offload 已启用（plugins.slots.contextEngine 已设置）

set -euo pipefail

# ── 常量 ──
SESSION_ID="${1:-swe-bench-single-001}"
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

if ! command -v openclaw &>/dev/null; then
    fail "openclaw 未安装"
fi

if ! openclaw plugins list 2>/dev/null | grep -q "memory-tencentdb"; then
    warn "memory-tencentdb 插件可能未启用"
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    warn "测试输入文件不存在: $INPUT_FILE"
    warn "使用内联测试输入..."
    USE_INLINE=true
else
    USE_INLINE=false
fi

# ── 清理旧数据（可选） ──
info "清理旧数据..."
rm -f "${HOME}/.openclaw/memory-tdai/conversations/$(date +%Y-%m-%d).jsonl" 2>/dev/null || true
rm -f "${HOME}/.openclaw/context-offload/main/mmds/*.mmd" 2>/dev/null || true

# ── 构建测试消息 ──
info "Session ID: $SESSION_ID"

if [[ "$USE_INLINE" == "true" ]]; then
    # 内联测试输入：Astropy RST writer header_rows issue
    TEST_MESSAGE="用 Python 测试 astropy.io.ascii.rst 模块的 header_rows 参数支持。问题：RST writer 不支持 header_rows 参数，导致 TypeError。代码路径：astropy/io/ascii/rst.py。需要检查：1) RST.__init__ 是否接受 header_rows 参数；2) write() 方法是否动态计算分隔线位置；3) read() 方法是否正确设置 data.start_line。请实际读取代码文件并运行测试验证。"
else
    # 从文件读取 SWE-bench instance
    info "读取测试输入: $INPUT_FILE"
    INSTANCE_ID=$(python3 -c "import ast; d=ast.literal_eval(open('$INPUT_FILE').read()); print(d[0]['instance_id'])")
    PROBLEM=$(python3 -c "import ast; d=ast.literal_eval(open('$INPUT_FILE').read()); print(d[0]['problem_statement'][:300])")
    TEST_MESSAGE="使用以下 SWE-bench instance 进行测试：
instance_id: $INSTANCE_ID
problem_statement: $PROBLEM

请分析并验证该问题是否已修复。"
fi

info "发送测试消息..."
echo "--- 测试消息内容 ---"
echo "$TEST_MESSAGE"
echo "--------------------"

# ── 执行测试 ──
export OPENCLAW_TDAI_DEBUG=1
export OPENCLAW_DEBUG=1

openclaw agent \
    --session-id "$SESSION_ID" \
    --message "$TEST_MESSAGE" \
    2>&1 | tee "${LOG_DIR}/swe-bench-single-$(date +%Y%m%d-%H%M%S).log"

# ── 等待 L1/L2 触发 ──
info "等待 L1/L2 处理（90s）..."
sleep 90

# ── 结果检查 ──
info "检查结果..."

L0_COUNT=$(wc -l < "${HOME}/.openclaw/memory-tdai/conversations/$(date +%Y-%m-%d).jsonl" 2>/dev/null || echo "0")
L1_COUNT=$(wc -l < "${HOME}/.openclaw/memory-tdai/records/$(date +%Y-%m-%d).jsonl" 2>/dev/null || echo "0")
MMD_FILES=$(ls "${HOME}/.openclaw/context-offload/main/mmds/"*.mmd 2>/dev/null | wc -l | tr -d ' ')

ok "L0: ${L0_COUNT} 条消息"
ok "L1: ${L1_COUNT} 条记忆"
ok "MMD: ${MMD_FILES} 个文件"

info "测试完成。详细结果请查看 ~/.openclaw/memory-tdai/ 和 ~/.openclaw/context-offload/main/"
info "验证脚本: bash scripts/tests/verify-results.sh --session-id $SESSION_ID"