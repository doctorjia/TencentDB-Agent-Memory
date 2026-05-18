# TencentDB Agent Memory 系统分析

## SWE-bench 实例处理流程

---

## 整体架构：四层 Memory 系统

```
L0 (对话录制) → L1 (记忆提取) → L2 (场景块管理) → L3 (人格合成)
```

---

## SWE-bench 输入数据概述

| 数据类型 | 内容摘要 |
|---------|---------|
| **instance_id** | `astropy__astropy-12907` |
| **problem_statement** | 用户报告 `separability_matrix` 对嵌套 CompoundModel 计算错误，期望对角但实际输出全连接矩阵 |
| **patch** | 修复 `_cstack` 函数：`cright[-right.shape[0]:, -right.shape[1]:] = 1` → `= right` |
| **test_patch** | 新增 cm8-cm11 测试用例验证嵌套模型的可分离性 |
| **FAIL_TO_PASS** | `compound_model6-result6`, `compound_model9-result9` |
| **repo** | `astropy/astropy` |
| **version** | `4.3` |

---

## L0 — 对话录制（Conversation Recording）

### 输入（从 agent_end hook）

```json
[
  {"role": "user", "content": "Modeling's `separability_matrix` does not compute separability correctly for nested CompoundModels..."},
  {"role": "assistant", "content": "Let me investigate the issue by examining the _cstack function..."},
  {"role": "user", "content": "The patch shows: cright[-right.shape[0]:, -right.shape[1]:] = right instead of = 1"},
  {"role": "assistant", "content": "```python\n# Before fix\ncright[-right.shape[0]:, -right.shape[1]:] = 1\n# After fix\ncright[-right.shape[0]:, -right.shape[1]:] = right\n```\n\nLet me verify with test_cm9..."}
]
```

### L0 处理过程

| 步骤 | 操作 | 结果 |
|------|------|------|
| 1 | `extractUserAssistantMessages()` | 提取 user/assistant 消息 |
| 2 | `shouldCaptureL0()` | 过滤 framework 噪声（`/new`, `/reset` 等）|
| 3 | `stripCodeBlocks()` | **移除 assistant 代码块**，避免嵌入噪声 |
| 4 | `sanitizeText()` | 移除注入标签、base64、时间戳前缀 |
| 5 | `shouldCaptureL0()` | 最终过滤空消息 |

### 关键处理逻辑

**对于代码数据**：
- `stripCodeBlocks()` 从 assistant 回复中移除代码块，避免干扰嵌入
- 保留用户的问题描述和代码上下文

**对于日志数据**：
- `sanitizeText()` 移除注入标签、base64 图片、时间戳前缀
- 保留错误信息和堆栈语义

### L0 输出

写入 `conversations/YYYY-MM-DD.jsonl`，每行一条消息：

```jsonl
{"sessionKey": "astropy__astropy-12907", "id": "msg_123", "role": "user", "content": "Modeling's `separability_matrix` does not compute separability correctly for nested CompoundModels\n\nConsider the following model:\n\nfrom astropy.modeling import models as m\nfrom astropy.modeling.separable import separability_matrix\n\ncm = m.Linear1D(10) & m.Linear1D(5)\n\n...\n", "timestamp": 1700000000000}
{"sessionKey": "astropy__astropy-12907", "id": "msg_124", "role": "assistant", "content": "Let me investigate the issue by examining the _cstack function...", "timestamp": 1700000001000}
```

**关键设计**：L0 是"宽容的"，保留尽可能多信息，质量过滤下沉到 L1。

---

## L1 — 记忆提取（Memory Extraction）

### 输入

L0 过滤后的消息，通过 `shouldExtractL1()` 质量门控。

### L1 提取提示词构建（`formatExtractionPrompt`）

```
【上一个情境】：无

【背景对话】（仅供理解上下文）：
无

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

【待提取的新消息】：
[msg_123] [user] [2026-05-14T...]: Modeling's `separability_matrix` does not compute separability correctly for nested CompoundModels...

[msg_124] [assistant] [2026-05-14T...]: Let me investigate the issue by examining the _cstack function...

[msg_125] [user] [2026-05-14T...]: The patch shows: cright[-right.shape[0]:, -right.shape[1]:] = right instead of = 1
```

### LLM 情境切分 + 记忆提取

使用 `EXTRACT_MEMORIES_SYSTEM_PROMPT`，LLM 执行两类任务：

**1. 情境切分（Scene Segmentation）**
- 判断用户意图切换
- 命名格式：`我（AI）在和xxx做xxx`（中文，30-50字）

**2. 三类记忆提取**

| 类型 | 定义 | SWE-bench 典型内容 | Priority |
|------|------|-------------------|----------|
| **persona** | 用户稳定属性/偏好/习惯 | "用户习惯在调试时先看堆栈" | 80-100 |
| **episodic** | 客观事件（时间+地点+动作+结果） | "用户在 2026-05-14 于 `foo.py:42` 发现空指针异常" | 80-100 |
| **instruction** | 长期行为规则 | "用户要求 AI 回答时先分析根因再给方案" | 70-100 |

### LLM 输出示例（模拟）

```json
[
  {
    "scene_name": "AI在和用户修复astropy嵌套CompoundModel可分离性计算bug",
    "message_ids": ["msg_123", "msg_124", "msg_125", "msg_126"],
    "memories": [
      {
        "content": "用户报告 astropy.modeling.separable 的 separability_matrix 对嵌套 CompoundModel 计算错误，预期输出对角矩阵但实际输出全连接矩阵",
        "type": "episodic",
        "priority": 95,
        "source_message_ids": ["msg_123"],
        "metadata": {
          "activity_start_time": "2026-05-14T...",
          "file": "astropy/modeling/separable.py",
          "function": "_cstack"
        }
      },
      {
        "content": "修复方案是将 _cstack 函数中 cright 矩阵赋值从常数 1 改为使用 right 变量，以正确处理嵌套模型的可分离性计算",
        "type": "episodic",
        "priority": 90,
        "source_message_ids": ["msg_125"],
        "metadata": {
          "activity_start_time": "2026-05-14T...",
          "patch_detail": "cright[-right.shape[0]:, -right.shape[1]:] = 1 → = right"
        }
      },
      {
        "content": "用户关注代码正确性，对数学逻辑严谨性要求高，会深入分析矩阵运算语义",
        "type": "persona",
        "priority": 75,
        "source_message_ids": ["msg_123", "msg_125"],
        "metadata": {}
      },
      {
        "content": "用户要求 AI 回答时先分析问题根因再给出修复方案",
        "type": "instruction",
        "priority": 85,
        "source_message_ids": ["msg_124"],
        "metadata": {}
      }
    ]
  }
]
```

### L1 去重（`batchDedup`）

基于向量相似度检测冲突，避免重复存储。

### L1 输出（写入 `records/*.jsonl`）

```json
{
  "id": "mem_abc123",
  "type": "episodic",
  "content": "用户报告 astropy.modeling.separable 的 separability_matrix 对嵌套 CompoundModel 计算错误，预期输出对角矩阵但实际输出全连接矩阵",
  "priority": 95,
  "scene_name": "AI在和用户修复astropy嵌套CompoundModel可分离性计算bug",
  "source_message_ids": ["msg_123"],
  "metadata": {
    "activity_start_time": "2026-05-14T...",
    "file": "astropy/modeling/separable.py",
    "function": "_cstack"
  },
  "created_at": "2026-05-14T..."
}
```

### SWE-bench 代码/日志如何抽取

**代码中的 Bug**：
- 作为 episodic 记忆提取，格式为：
  ```
  "用户（姓名）在 [时间] 于 [文件:行号] [做了某事（触发→行动→结果）]"
  ```
- metadata 中记录 `activity_start_time` 和 `activity_end_time`（ISO 8601）

**日志中的错误**：
- 提取错误类型+堆栈位置作为 episodic
- 优先级根据重要性打分（80-100 重要事件）

---

## L2 — 场景块管理（Scene Block Management）

### 输入

L1 输出的记忆批次（约20条/批），通过 `SceneExtractor.extract()` 处理。

### L2 提示词构建

**system prompt** 指导 LLM：
- 默认策略是 UPDATE（更新已有场景），不是 CREATE
- 场景总数上限 15
- 使用文件工具读写 `scene_blocks/` 目录

**user prompt 注入**：

```
### 1️⃣ New Memories List
[{
  "content": "用户报告 astropy.modeling.separable 的 separability_matrix 对嵌套 CompoundModel 计算错误",
  "created_at": "2026-05-14T...",
  "id": "mem_abc123"
}, ...]

### 2️⃣ Existing Scene Blocks Summary
**当前场景总数：3 / 15**

### 场景文件-astropy-bug修复.md
**热度**: 5 | **更新**: 2026-05-13
**summary**: 用户报告 astropy 库的 separability_matrix 计算问题
...
```

### L2 LLM Agent 操作（模拟）

1. **READ** `astropy-bug修复.md`（如果存在）
2. **分析**：新记忆是关于嵌套 CompoundModel 的 separability 计算 bug
3. **决策**：UPDATE 已有场景 vs CREATE 新场景
4. **WRITE/EDIT**：更新场景文件

### L2 输出（场景块文件）

**场景文件：`astropy-modeling-嵌套CompoundModel-bug修复.md`**

```markdown
-----META-START-----
created: 2026-05-13T...
updated: 2026-05-14T...
summary: 用户报告 astropy separability_matrix 对嵌套 CompoundModel 计算错误，根因是 _cstack 函数矩阵赋值逻辑
heat: 6
-----META-END-----

## 用户基础信息
-姓名：未知名（SWEBench实例）
-职业：astropy 库用户/开发者
-技术栈：Python 科学计算、astropy.modeling

## 用户核心特征
用户对矩阵运算语义有深入理解，能精确描述问题现象（"预期对角但实际全连接"），关注嵌套模型的可分离性计算正确性。

## 用户偏好
- 喜欢在调试时查看具体矩阵值变化
- 要求 AI 先分析根因再给出修复方案

## 隐性信号
用户可能是 astropy 库的 contributor 或高级用户，对内部实现细节有研究需求。

## 核心叙事
用户在使用 astropy 的 CompoundModel 时发现 separability_matrix 对嵌套结构计算错误。当 `m.Pix2Sky_TAN() & cm`（嵌套）时，输出矩阵从预期的对角变成了全连接，表明模型间的可分离性被错误计算。根本原因在 `_cstack` 函数的 `cright` 矩阵赋值逻辑：使用常数 1 而非 right 变量，导致嵌套结构信息丢失。用户通过对比简单模型和嵌套模型的 separability_matrix 输出来定位问题。

## 演变轨迹
- [2026-05-14]: 发现嵌套 CompoundModel separability 计算错误（mem_id: #abc123）

## 待确认/矛盾点
- 暂无
```

### 热度管理

- 新建 Block: `heat: 1`
- 更新 Block: `heat: 旧heat + 1`
- 合并 Block: `heat: sum(所有相关block的heat) + 1`

---

## L3 — 人格合成（Persona Synthesis）

### 输入

自上次 persona 更新后发生变化的所有场景块（通过 `CheckpointManager` 管理 `last_persona_time`）。

### L3 四层深度扫描协议

| Layer | 扫描目标 | SWE-bench 典型输出 |
|-------|---------|-------------------|
| **Layer 1** | 基础锚点（事实、人口统计） | 用户身份、技术背景 |
| **Layer 2** | 兴趣图谱（投入时间/金钱的事物） | 编程语言偏好、工具偏好 |
| **Layer 3** | 交互协议（沟通习惯、雷区） | "需要先分析根因再给方案" |
| **Layer 4** | 认知内核（决策逻辑、矛盾点） | "代码洁癖 vs 快速修复" |

### L3 输出（`persona.md`）

```markdown
# User Narrative Profile

> **Archetype**: 一位对科学计算库内部实现有深度研究兴趣的 Python 开发者，关注嵌套模型的数学语义正确性

> **基本信息**
-
- 技术栈：Python, astropy, numpy, scipy
- 关注领域：天文建模、矩阵运算、CompoundModel

> **长期偏好**
- 调试时需要查看具体矩阵值变化
- 回答前先分析根因再给方案
- 代码正确性优先于快速修复

## Chapter 1: Context & Current State
用户正在修复 astropy 库的嵌套 CompoundModel separability 计算问题。这是一个涉及 `_cstack` 函数矩阵赋值的底层 bug，影响嵌套模型的可分离性计算逻辑。

## Chapter 2: The Texture of Life
用户对矩阵运算和嵌套模型结构有深入理解，能够精确描述问题现象（"预期对角但实际全连接"）。关注科学计算库的数学语义正确性。

## Chapter 3: Interaction & Cognitive Protocol
### 3.1 沟通策略
- 先分析根因再给方案
- 需要具体矩阵值作为调试证据
### 3.2 决策逻辑
代码正确性 > 快速修复，倾向于深入理解问题本质

## Chapter 4: Deep Insights & Evolution
* **矛盾统一性**: 追求数学严谨性（精确到矩阵元素级别）同时能处理复杂嵌套结构
* **演变轨迹**: 暂无重大变化
* **涌现特征**:
  - `矩阵语义敏感` - 能精确描述矩阵运算问题
  - `根因分析优先` - 调试时先定位根本原因
  - `科学计算深度用户` - 使用 astropy 而非仅 scikit-learn
```

---

## 召回路径（Recall）模拟

当 SWE-bench 发起后续请求时（如另一个 astropy issue）：

### 输入查询

```json
{"query": "astropy modeling separability nested compound model"}
```

### 召回过程（`memory-search.ts`）

1. **混合搜索**（strategy: hybrid, RRF 融合）：
   - embedding 相似度搜索
   - keyword BM25 搜索
2. **阈值过滤**：score > 0.3
3. **Top-K**：maxResults = 5

### 召回输出示例

```json
{
  "results": [
    {
      "content": "用户报告 astropy.modeling.separable 的 separability_matrix 对嵌套 CompoundModel 计算错误，预期输出对角矩阵但实际输出全连接矩阵",
      "type": "episodic",
      "score": 0.85,
      "scene": "astropy-modeling-嵌套CompoundModel-bug修复"
    },
    {
      "content": "用户对矩阵运算语义有深入理解，能精确描述问题现象（\"预期对角但实际全连接\"）",
      "type": "persona",
      "score": 0.72,
      "scene": null
    }
  ]
}
```

### 注入 Prompt

```xml
<relevant-memories>
用户关注 astropy modeling 的嵌套 CompoundModel separability 计算问题。
用户喜欢先分析根因再给方案。
</relevant-memories>
```

---

## 总结：SWE-bench 场景的信息流

```
代码/日志输入
    ↓
[L0] 原始对话录制 → sanitizeText() + stripCodeBlocks()
    ↓
[L1] 情境切分 + 记忆提取 → persona/episodic/instruction 三类记忆
    ↓
[L2] 场景块整合 → Markdown 叙事文档（含 Bug 解决弧）
    ↓
[L3] 人格合成 → persona.md（含调试风格、技术偏好）
```

---

## 关键信息抽取总结

| 数据类型 | L0 处理 | L1 抽取 | L2 整合 | L3 归纳 |
|---------|---------|---------|---------|---------|
| **Bug 描述** | sanitizeText + stripCodeBlocks | episodic: separability_matrix 计算错误 | 场景叙事：嵌套模型可分离性 | persona: 矩阵语义敏感性 |
| **Patch** | sanitizeText | episodic: 修复方案（cright=right） | 核心叙事：根因分析 | persona: 根因分析优先 |
| **Test** | shouldCaptureL0 | instruction: 测试验证要求 | 场景块元数据 | persona: 代码正确性优先 |

---

## 核心机制说明

1. **代码 Bug**：主要沉淀为 **episodic** 记忆（L1）→ 聚合到场景块（L2）
2. **日志错误**：通过 LLM 理解后以"行动→结果"结构沉淀
3. **persona 层（L3）**：从场景块中归纳用户的**调试风格偏好**（而非具体 bug 细节）

---

## 短期 Memory 与长期 Memory 各层级输入输出

| 层级 | 名称 | 输入 | 输出 | 存储位置 |
|------|------|------|------|---------|
| **L0** | 对话录制 | agent_end hook 原始消息 | JSONL 单条消息记录 | `conversations/YYYY-MM-DD.jsonl` |
| **L1** | 记忆提取 | L0 消息 + shouldExtractL1 过滤 | persona/episodic/instruction 三类结构化记忆 | `records/*.jsonl` + VectorStore |
| **L2** | 场景块管理 | L1 记忆批次（~20条） | Markdown 叙事文档（含 META header） | `scene_blocks/*.md` |
| **L3** | 人格合成 | L2 变化场景块 | 用户画像文档（含四层扫描洞察） | `persona.md` |