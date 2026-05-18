# TencentDB Agent Memory — SWE-bench 测试指南

> 本文档描述如何使用 SWE-bench 实例对 TDAI（TencentDB Agent Memory）插件的记忆流程进行测试验证。适用于验证 L0/L1/L2/L3 四层记忆机制、MMD (L1.5) 生成逻辑、以及 recall 注入顺序。

**测试日期**：2026-05
**插件版本**：`@tencentdb-agent-memory/memory-tencentdb` v0.3.4+
**平台**：OpenClaw 2026.5.7+，macOS / Linux

---

## 目录

1. [测试目标与范围](#1-测试目标与范围)
2. [前置条件](#2-前置条件)
3. [插件配置](#3-插件配置)
4. [测试脚本说明](#4-测试脚本说明)
5. [运行测试](#5-运行测试)
6. [结果验证](#6-结果验证)
7. [预期输出对照表](#7-预期输出对照表)
8. [常见问题](#8-常见问题)

---

## 1. 测试目标与范围

### 1.1 可验证的记忆行为

| 层级 | 可验证项 |
|------|---------|
| **L0** | 对话录制格式、stripCodeBlocks 效果、sanitizeText 处理 |
| **L1** | 记忆提取时机（l1IdleTimeout / everyNConversations）、dedup 行为 |
| **L1.5** | MMD 生成条件（isLongTask / isContinuation）、node_id 映射 |
| **L2** | 场景块生成、L1→scene_blocks 对应关系、backfill 机制 |
| **L3** | persona 更新阈值（memories_since_last_persona >= 50） |
| **Recall** | FTS 跨 session 命中、prependContext/appendSystemContext 注入顺序 |

### 1.2 测试类型

| 类型 | 说明 | 脚本 |
|------|------|------|
| **单实例测试** | 单一 SWE-bench instance，验证基本记忆流程 | `swe-bench-single-test.sh` |
| **多实例同 Session** | 同一 session 注入多个 instance，验证 recall 跨实例能力 | `swe-bench-multi-test.sh` |
| **L1.5 生成测试** | 验证 gpt-5.4 offload 模型切换，修复"受国家限制"错误 | `swe-bench-rst-test.sh` |
| **结果验证** | 检查 memory 文件、MMD 文件内容是否符合预期 | `verify-results.sh` |

---

## 2. 前置条件

### 2.1 软件要求

- **OpenClaw** 2026.5.7+
- **Node.js** 18+
- **rtk**（Rust Token Killer，已配置 hook）
- **Python 3**（用于解析 L0 JSONL 和 Python literal 格式测试输入）

### 2.2 插件要求

```
memory-tencentdb      必须启用
context-offload       必须启用（L1.5 MMD 功能）
openai (或 poe)       必须有可用模型
```

### 2.3 环境变量

```bash
# 可选：开启 debug 日志（查看 memory pipeline 每步详情）
export OPENCLAW_TDAI_DEBUG=1
export OPENCLAW_DEBUG=1
```

---

## 3. 插件配置

### 3.1 完整 openclaw.json 配置示例

```json
{
  "plugins": {
    "entries": {
      "memory-tencentdb": {
        "enabled": true,
        "config": {
          "capture": { "enabled": true },
          "extraction": {
            "model": "minimax-portal/MiniMax-M2.7",
            "enableDedup": true,
            "maxMemoriesPerSession": 20
          },
          "offload": {
            "enabled": true,
            "model": "custom-api-poe-com/gpt-5.4"
          },
          "pipeline": {
            "everyNConversations": 1,
            "enableWarmup": false,
            "l1IdleTimeoutSeconds": 10
          },
          "recall": {
            "enabled": true,
            "maxResults": 5,
            "strategy": "hybrid",
            "scoreThreshold": 0.3
          }
        }
      },
      "openai": { "enabled": true }
    },
    "slots": {
      "contextEngine": "openclaw-context-offload"
    }
  },
  "models": {
    "providers": {
      "minimax-portal": {
        "baseUrl": "https://api.minimaxi.com/anthropic",
        "api": "anthropic-messages",
        "authHeader": true,
        "models": []
      },
      "custom-api-poe-com": {
        "baseUrl": "https://api.poe.com/v1",
        "api": "openai-completions",
        "apiKey": "sk-poe-XXXXXXXXXXXX",
        "models": [
          {
            "id": "gpt-5.4",
            "contextWindow": 4000,
            "maxTokens": 4096
          }
        ]
      }
    },
    "mode": "merge"
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "minimax-portal/MiniMax-M2.7"
      }
    }
  }
}
```

### 3.2 关键配置说明

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `offload.model` | `"custom-api-poe-com/gpt-5.4"` | **必须使用 poe 的 gpt-5.4**，minimax-portal 使用 OAuth 无 apiKey，无法用于 LocalLLM |
| `extraction.model` | `"minimax-portal/MiniMax-M2.7"` | L1/L2/L3 提取模型，可用 minimax |
| `pipeline.everyNConversations` | `1` | 每 1 条对话触发 L1 提取（测试用，生产建议 3-5） |
| `pipeline.l1IdleTimeoutSeconds` | `10` | 空闲 10s 后立即触发 L1（测试用） |
| `plugins.slots.contextEngine` | `"openclaw-context-offload"` | **必须设置**，否则 L1.5 不触发 |

---

## 4. 测试脚本说明

### 4.1 脚本目录结构

```
scripts/
├── setup-offload.sh                    # L1.5 offload 功能开关
├── memory-tencentdb-ctl.sh             # memory 管理 CLI
├── verify-results.sh                   # 结果验证脚本（新增）
└── tests/                              # SWE-bench 测试套件（新增）
    ├── swe-bench-single-test.sh        # 单实例测试
    ├── swe-bench-multi-test.sh         # 多实例同 session 测试
    ├── swe-bench-rst-test.sh           # RST writer + gpt-5.4 offload 测试
    └── swe-bench-inputs/               # 测试输入文件
        ├── astropy-rst.json            # RST writer issue #14182
        └── astropy-separability.json   # separability_matrix issue #12907
```

### 4.2 各脚本功能

#### `swe-bench-single-test.sh`

单 session 单 instance 测试，用于验证基础 L0→L1→L2→L3 流程。

```bash
bash scripts/tests/swe-bench-single-test.sh
```

**测试内容**：向 openclaw agent 注入一个 SWE-bench instance，观察 L0 录制、L1 提取、L1.5 MMD 生成。

#### `swe-bench-multi-test.sh`

同一 session 内顺序注入 3 个不同 instance，验证 recall 跨实例和 FTS 命中能力。

```bash
bash scripts/tests/swe-bench-multi-test.sh
```

**测试内容**：
- Instance 1: sympy Piecewise bug
- Instance 2: matplotlib tight_layout bug
- Instance 3: astropy WCS bug（与历史 session 同域，验证 recall）

#### `swe-bench-rst-test.sh`

使用真实的 SWE-bench lite JSON 输入（Python literal 格式），验证 gpt-5.4 offload 修复后的 L1.5 MMD 生成。

```bash
bash scripts/tests/swe-bench-rst-test.sh
```

**测试内容**：
- 读取 `swe-bench-inputs/astropy-rst.json`（issue #14182）
- session id: `swe-bench-rst-002`
- 验证 offload 文件中 23 条工具调用全部映射到同一 MMD 节点

#### `verify-results.sh`

测试完成后检查 memory 文件结构。

```bash
bash scripts/tests/verify-results.sh [--session-id <id>]
```

**检查项**：
- `~/.openclaw/memory-tdai/conversations/` 是否有新增 JSONL
- `~/.openclaw/memory-tdai/records/` 是否有新增 JSONL
- `~/.openclaw/context-offload/main/mmds/` 是否有 MMD 文件
- MMD 内容是否为有效 Mermaid（不是"受国家限制"）

---

## 5. 运行测试

### 5.1 快速开始

```bash
# 1. 确认插件已启用
openclaw plugins list | grep memory-tencentdb

# 2. 确认 contextEngine 已配置
openclaw config get plugins.slots.contextEngine

# 3. 运行单实例测试
bash scripts/tests/swe-bench-single-test.sh

# 4. 验证结果
bash scripts/tests/verify-results.sh
```

### 5.2 完整测试流程（多实例 + L1.5）

```bash
# 1. 清理旧数据（可选）
rm -f ~/.openclaw/memory-tdai/conversations/$(date +%Y-%m-%d).jsonl
rm -f ~/.openclaw/context-offload/main/mmds/*.mmd

# 2. 运行多实例测试
bash scripts/tests/swe-bench-multi-test.sh

# 3. 运行 RST 测试（gpt-5.4 offload）
bash scripts/tests/swe-bench-rst-test.sh

# 4. 批量验证
bash scripts/tests/verify-results.sh --session-id swe-bench-multi-001
bash scripts/tests/verify-results.sh --session-id swe-bench-rst-002
```

### 5.3 使用真实 SWE-bench Lite 输入

```bash
# 读取 Python literal 格式的测试输入
python3 -c "
import ast
with open('scripts/tests/swe-bench-inputs/astropy-rst.json') as f:
    data = ast.literal_eval(f.read())
instance = data[0]
print('instance_id:', instance['instance_id'])
print('repo:', instance['repo'])
print('problem_statement:', instance['problem_statement'][:200])
"
```

### 5.4 查看 L1.5 日志

```bash
# 实时跟踪 offload 日志
tail -f ~/.openclaw/context-offload/main/logs/*.log 2>/dev/null

# 或查看最新 MMD 内容
cat ~/.openclaw/context-offload/main/mmds/$(ls -t ~/.openclaw/context-offload/main/mmds/ | head -1)
```

---

## 6. 结果验证

### 6.1 手动检查脚本

运行后检查以下路径：

```bash
# L0 检查
cat ~/.openclaw/memory-tdai/conversations/$(date +%Y-%m-%d).jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    obj = json.loads(line)
    print(f\"role={obj['role']}, content_len={len(obj.get('content',''))}\")
"

# L1 检查
cat ~/.openclaw/memory-tdai/records/$(date +%Y-%m-%d).jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    obj = json.loads(line)
    print(f\"type={obj.get('type')}, summary={obj.get('summary','')[:80]}\")
"

# MMD 检查
ls -la ~/.openclaw/context-offload/main/mmds/
cat ~/.openclaw/context-offload/main/mmds/*.mmd | grep -v "^%%" | head -20
```

### 6.2 自动验证

```bash
bash scripts/tests/verify-results.sh --session-id swe-bench-rst-002
```

预期输出：
```
[INFO]  检查 session: swe-bench-rst-002
[OK]    L0: 23 条消息已录制
[OK]    L1: 1 条记忆已提取
[OK]    MMD: 003-fix-sympy-piecewise.mmd 存在且内容正常
[OK]    node_id 映射: 23 条 → N7
```

---

## 7. 预期输出对照表

### 7.1 L0 录制

| 消息 | role | 代码块处理 | 说明 |
|------|------|-----------|------|
| Bug 描述（用户） | user | **保留** | 用户代码片段完整进入 L0 |
| AI 分析回复（助手） | assistant | **移除** | 代码块被 stripCodeBlocks() 删除 |
| 工具调用说明（助手） | assistant | **保留** | 非代码块文字说明保留 |
| Patch 内容（用户） | user | **保留** | 用户提供的 diff/patch 内容 |

### 7.2 L1 提取

| 场景 | L1 触发条件 | 新增记录数 |
|------|------------|-----------|
| 单实例短对话 | l1IdleTimeout 10s | 1-4 条 |
| 长任务多工具调用 | everyNConversations=1 | 8-20 条 |
| 跨 session recall | FTS BM25 命中 | prependContext 注入 |

### 7.3 L1.5 MMD 生成

| 条件 | 结果 | 说明 |
|------|------|------|
| isLongTask=false + taskCompleted=true | 无 MMD | short task，不生成 |
| isLongTask=true + taskCompleted=false | 创建/复用 MMD | 长任务，MMD 激活 |
| isContinuation=true | 复用现有 MMD | 追加到已有节点 |
| offload.model = minimax-portal | "受国家限制"错误 | **OAuth 模式无 apiKey**，需换 gpt-5.4 |

### 7.4 L1→L2 对应关系

| 方式 | 说明 |
|------|------|
| **l15Boundaries 状态机** | 不靠文本相似度，靠 L1.5 judgment 时记录的 startIndex + targetMmd |
| node_id 分配 | backend LLM（gpt-5.4）根据 summary 语义合并决定 |
| backfill | entriesByMmd 按 targetMmd 分桶，统一发 L2Request |

---

## 8. 常见问题

### Q1: L1.5 MMD 内容是"受国家限制，无法生成"

**原因**：`offload.model` 配置为 `minimax-portal/MiniMax-M2.7`，但 minimax-portal 使用 OAuth 模式，没有 apiKey。LocalLLM 初始化需要 `baseUrl + apiKey`。

**修复**：切换到 poe 供应商：
```json
"offload": {
  "enabled": true,
  "model": "custom-api-poe-com/gpt-5.4"
}
```

### Q2: MMD 文件没有生成

**检查项**：
1. `plugins.slots.contextEngine` 是否为 `"openclaw-context-offload"`
2. session 内是否有足够多的工具调用（短 query 通常不满足 isLongTask）
3. offload model 是否正确初始化（查看日志中是否有 `Initialized: model=gpt-5.4`）

### Q3: L2 没有生成新的 scene_blocks

**原因**：L2 触发需要 90s 延迟（`l2DelayAfterL1Seconds`），测试期间可能未等待足够时间。

**验证**：检查 `~/.openclaw/memory-tdai/scene_blocks/` 是否在 90s 后有新文件。

### Q4: recall 没有命中历史记忆

**原因**：FTS 搜索是跨 session 的，但如果当前 query 的关键词与历史记忆的关键词无交集（无 BM25 命中），则 prependContext 为空。这是正常设计。

**验证**：检查 `~/.openclaw/memory-tdai/records/` 中是否有与当前 query 关键词匹配的历史记录。

---

## 附录：关键文件路径

```
~/.openclaw/
├── openclaw.json                    # 插件配置
├── memory-tdai/
│   ├── conversations/               # L0：对话录制
│   │   └── YYYY-MM-DD.jsonl
│   ├── records/                     # L1：记忆提取
│   │   └── YYYY-MM-DD.jsonl
│   ├── scene_blocks/                # L2：场景块
│   │   └── 技术研究-*.md
│   └── persona.md                   # L3：人格画像
└── context-offload/main/
    ├── mmds/                        # L1.5：Mermaid 图
    │   └── NNN-*.mmd
    ├── offload-*.jsonl              # 工具调用记录
    ├── refs/                        # 工具结果快照
    └── state.json                   # MMD 计数器、活跃 MMD
```