# SWE-bench 测试套件

本目录包含用于测试 TencentDB Agent Memory（TDAI）插件记忆流程的脚本。

## 目录结构

```
tests/
├── swe-bench-single-test.sh    # 单实例测试
├── swe-bench-multi-test.sh     # 多实例同 session 测试
├── swe-bench-rst-test.sh       # RST writer + gpt-5.4 offload 测试
├── verify-results.sh            # 结果验证脚本
└── swe-bench-inputs/
    └── astropy-rst.json        # SWE-bench 测试输入（Python literal 格式）
```

## 快速开始

```bash
# 1. 运行单实例测试
bash scripts/tests/swe-bench-single-test.sh

# 2. 运行多实例测试
bash scripts/tests/swe-bench-multi-test.sh

# 3. 运行 RST + gpt-5.4 测试
bash scripts/tests/swe-bench-rst-test.sh

# 4. 验证结果
bash scripts/tests/verify-results.sh --session-id swe-bench-rst-002
```

## 前置条件

- OpenClaw 2026.5.7+
- `memory-tencentdb` 插件已启用
- `context-offload` 已配置（`plugins.slots.contextEngine = "openclaw-context-offload"`）
- `offload.model` 设置为 `custom-api-poe-com/gpt-5.4`（**不是** minimax-portal）

## 测试脚本说明

### swe-bench-single-test.sh

单 session 单 instance 测试，验证基础 L0→L1→L2→L3 流程。

### swe-bench-multi-test.sh

同一 session 内顺序注入 3 个不同 instance（sympy、matplotlib、astropy），验证 recall 跨实例能力。

### swe-bench-rst-test.sh

使用真实 SWE-bench lite JSON 输入测试 gpt-5.4 offload 模型。检查：
- offload.jsonl 中 23 条工具调用是否全部映射到同一 node_id
- MMD 文件是否正常生成（无"受国家限制"错误）

### verify-results.sh

验证 memory 文件结构：
- L0 对话录制数量
- L1 记忆提取数量
- MMD 文件存在性和内容正确性
- node_id 映射情况

## 测试输入格式

`swe-bench-inputs/` 目录下的文件是 **Python literal 格式**（不是 JSON），解析方式：

```python
import ast
with open('swe-bench-inputs/astropy-rst.json') as f:
    data = ast.literal_eval(f.read())
instance = data[0]
print(instance['instance_id'])  # astropy__astropy-14182
```

## 关键配置检查

```bash
# 检查 offload.model 是否为 gpt-5.4（不是 minimax）
openclaw config get plugins.entries.memory-tencentdb.config.offload.model

# 检查 contextEngine 是否配置
openclaw config get plugins.slots.contextEngine
```

如需切换 offload 模型，参考 `TESTREADME.md` Section 3。