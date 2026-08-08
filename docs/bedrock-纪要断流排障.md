# Bedrock 纪要生成稳健性排障记录

分支：`fix/bedrock-timeout-retry`
涉及文件：`src/meetap` 的 `summarize_via_bedrock()`
状态：已修复并验证

这条支线专治「转录成功、但会议纪要生成不稳定」的一系列问题——从最初的超时空手而归，一路排到最终的断流根因（Sonnet 5 thinking 吃预算）。本文按时间线记录问题、根因和修复，供日后回溯。

---

## 背景

`meetap` 后端用 **AWS Transcribe + Bedrock** 生成会议纪要：Transcribe 出转录文本，再把转录 + prompt 模板喂给 Bedrock 的 `converse_stream`（Converse 流式 API，非 Anthropic SDK）生成 Markdown 纪要。

- 模型：`global.anthropic.claude-sonnet-5`（区域 `ap-northeast-1`）
- 配置：`~/.config/meetap/config`（`ai_backend=bedrock`）
- 纪要末尾有一段 Meetap 藏头签名（footer），每个词首字母包在 `<strong>` 标签里拼出 `Listen · analyze · recap · refine · yield` 和 `Your audio notes generator`。

---

## 问题演进与修复时间线

### 1. 超时空手而归 — `7853dd5`

**现象：** 大 transcript 时出现「转录成功、纪要因 `Read timed out` 空手而归」。

**根因：** 大 prompt 的首字节延迟超过 boto3 默认的 60s `read_timeout`；且流式请求被中途掐断时，botocore 自带的 `retries` 兜不住（它只重试建连阶段，不重试已开始的流）。

**修复：**
- `read_timeout=300, connect_timeout=15`，放宽超时。
- `retries={"max_attempts": 0}` 关掉 botocore 内层重试，改为**外层整体重发**整个请求（`MAX_TRIES=3`，递增退避 5s/10s）。

### 2. 半截纪要被当成功写出 — `b11d15b`

**现象：** 流在没抛异常的情况下提前结束，只吐了前半段就断，半截纪要被当成功写出并发邮件。

**根因：** 只要收到了文本就写文件，没校验流是否正常收尾。

**修复：** 检测 `messageStop` 的 `stopReason`，只有正常终止才算完整，否则判为断流触发重试。
（⚠️ 此版本把 `max_tokens` 也当成了正常终止——这个判断在第 4 步被纠正。）

### 3. `meetap again` 写入日志 — `245b073`

**现象：** `meetap again` 重新生成纪要时，输出没写进 `meetap.log`。

**修复：** 给 `again` 的「有转录、从纪要生成阶段重跑」分支包一层 `tee -a "$LOG_DIR/meetap.log"`，终端和日志同时可见。
（注意：只包这一个分支，避免和无转录路径内部的 truncate 模式 `exec > "$LOG_FILE"` 冲突。）

### 4. 断流根因：Sonnet 5 thinking 吃预算 — `293ba4c` ⭐

**现象：** 纪要间歇性断流，时好时坏。同一份 transcript 重跑，有时完整，有时截断到一半，甚至出现过正文 0 字。

**诊断（systematic-debugging）：** 同一 125332 字节 prompt 连跑 4 次，加埋点看真实 `stopReason` 和 token 用量：

| 运行 | stopReason | 正文字符 | 输出 token | 真实状态 |
|---|---|---|---|---|
| A | end_turn | 5074 | 7983 | ✅ 完整 |
| 1 | end_turn | 6205 | 14887 | ✅ 完整 |
| 2 | max_tokens | 3100 | 16000 | ❌ 词中间截断 |
| 3 | max_tokens | 0 | 16000 | ❌ 全思考、零正文 |

**根因：** `global.anthropic.claude-sonnet-5` **默认开启 adaptive thinking**，思考 token 与正文**共享同一个 `maxTokens` 预算**。会议纪要 prompt 长、内容重，模型会思考很久——运行 3 是决定性证据：16000 token 全烧在思考上，正文一个字没剩。思考长度每次随机，所以断流时有时无。

此外第 2 步遗留的 `max_tokens` 被当成正常收尾，于是被预算截断的半截纪要仍被写出。

**修复：**

| 改动 | 作用 |
|---|---|
| `additionalModelRequestFields={"thinking": {"type": "disabled"}}` | 纪要是直出任务不需要推理，关掉思考把整个预算留给正文，顺带省成本、降延迟。Sonnet 5 接受 `thinking: {type: "disabled"}`。 |
| `maxTokens` 16000 → 32000 | 留足头寸（纪要目标 ~2500 字，绰绰有余） |
| `max_tokens` 不再算正常收尾 | 它本就是「被预算截断」信号，改为触发既有重试 |
| 新增 footer 藏头签名检测 | 双保险：正文必须以 Meetap 签名收尾才算完整 |

**footer 检测的坑：** 签名把每个词首字母包进 `<strong>` 标签（`<strong>a</strong>udio`），所以裸串匹配 `"audio"` 会误判为缺失。检测前必须**先剥掉 HTML 标签**再比：

```python
FOOTER_MARK = "audio notes generator"
def footer_present(s):
    plain = re.sub(r"<[^>]+>", "", s)
    return FOOTER_MARK in plain
```

**验证：** 关掉思考后连跑 3 次同一 prompt，**3/3 完整**，输出 token 从 14000–16000 稳定降到 **5000–6000**——直接证明思考就是吃预算的元凶。实际 `meetap again 20260806_1501` 重跑：5007 字、footer 完整、`end_turn` 正常收尾，耗时从旧版的 3 分 44 秒降到 74 秒。

---

## 完整性判断的最终逻辑

`summarize_via_bedrock()` 判定纪要完整需**同时满足**，任一不满足即触发外层重试（最多 3 次）：

1. 正文非空；
2. `stopReason ∈ {end_turn, stop_sequence}`（`max_tokens` = 被截断，不算）；
3. footer 藏头签名存在（剥 HTML 标签后匹配 `audio notes generator`）。

---

## 经验教训

- **Sonnet 5 / Opus 5 等新模型默认开 adaptive thinking**，思考与正文共享 `maxTokens` 预算。直出型任务（摘要、翻译、格式化）应显式 `thinking: {type: "disabled"}`，否则会间歇性截断且平白增加成本和延迟。
- **`stopReason=max_tokens` 是残缺信号**，不能当正常收尾。
- **流式请求的断流 botocore 内层 retry 兜不住**，需外层整体重发。
- **完整性校验要用业务信号**（这里是 footer 签名），比单看 `stopReason` 更可靠；做文本匹配时注意模型可能插入 HTML 标签，先归一化再比对。
