# hermes-provider-probe

对 Hermes 主 LLM provider 的最小化可用性探测脚本：提示词仅使用简短的 `Reply OK.`，
验证配置的 provider/model 是否真正可用，并输出所用 endpoint、HTTP 状态与 token
用量。用于在依赖方暴露连接故障之前，快速定位配置或上游问题。

> 关于 token 消耗：`/responses` 发送显式的短 `instructions: "Reply with OK only."`，
> 用来避免 provider 注入或默认附加的长 instruction 前缀；同时保留
> `input: "Reply OK."`。脚本刻意不设置硬性输出上限（省略
> `max_output_tokens`，使用 provider default），provider usage 仍可能变化，
> 脚本不承诺固定的总 token 成本；通常消耗较低主要来自短提示词、短 instructions
> 与 `reasoning.effort=none`，而非硬限制。

## 特性

- 默认健康检查模型 `gpt-5.6-luna`，`reasoning.effort=none`（最小开销），可用
  `TEST_MODEL` 覆盖。
- 默认走 `codex_responses`（`/responses`）；显式配置 `api_mode: chat_completions`
  时走 `/chat/completions`。
- Token 策略按 endpoint 区分：
  - `/responses` 发送短 `instructions: "Reply with OK only."`，以避免 provider
    注入或默认附加的长 instruction 前缀；载荷**完全省略** `max_output_tokens`——
    上游对该字段（即使值为 1）返回 HTTP 400 `upstream_error`，省略后使用
    provider default 输出上限。provider usage 仍可能变化，不能据此保证固定总 token 成本。
  - `/chat/completions` 保留 `max_tokens: 1`。
- 主 endpoint 返回 HTTP 400 时自动改试另一 endpoint（401/403/429/5xx 与 HTML
  响应一律不重试）；文案中性，仅报告 `returned HTTP 400`。
- 密钥只写入权限 0600 的 header 文件，不进入 curl 参数，也不打印到终端。
- 任何异常 shape（curl 失败、非 JSON、SSE 截断/错误事件、非 200）一律
  fail-closed 并以非零退出码结束，绝不误报成功。

## 依赖

- bash 3.2+（macOS 自带 /bin/bash 3.2 已验证可运行；较新 bash 亦可）
- curl
- jq
- python3 + PyYAML（`python3 -c 'import yaml'` 可验证）

## 用法

```sh
./test-provider.sh
```

默认读取 `~/.hermes/config.yaml` 与 `~/.hermes/.env`（.env 只解析 `KEY=VALUE`
行，不执行任何 shell 代码，且不会覆盖环境中已存在的同名变量）。

### 环境变量

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `HERMES_DIR` | 存放 config.yaml / .env 的目录 | `$HOME/.hermes` |
| `TEST_MODEL` | 覆盖被测模型 | `gpt-5.6-luna` |
| `CURL_TIMEOUT` | curl 超时秒数 | `30` |
| `LIST_MODELS` | 设为 `1` 时额外调用 `/models` 列出模型（仅信息性，不影响测试模型） | `0` |

### 配置要点（config.yaml）

- 读取 `model.provider` / `model.base_url` / `model.api_mode` / `model.default`。
- `model.api_mode` 缺省为 `codex_responses`；显式配置优先于默认值。
- `model.base_url` 缺失时，从 `providers` / `custom_providers`（list 与 dict
  两种写法均支持）中按名称或归一化 URL 匹配条目取回 base_url。
- `model.base_url` 及回退路由只允许 HTTP(S) origin/path 形式；userinfo（包括
  percent-encoded userinfo）、query、fragment、空白/控制字符，以及无效 host 或
  port 会在任何输出或 curl 调用前被拒绝。
- 密钥来源优先级：`model.api_key`（支持 `${ENV}` 引用）→ 匹配 provider 条目的
  `key_env` / `api_key` → 兼容环境变量（`CODEX_API_KEY` 等）。找不到密钥时探测失败，
  外部退出码为 1。
- 输出提示词按 endpoint 准确说明 token 策略：Responses 显示短 instructions 并使用
  provider default（不承诺固定 usage），Chat 使用 `max_tokens: 1`。

## 测试

```sh
bash tests/run.sh
```

全量 hermetic 测试：无外网（curl 替换为 `tests/fake-curl`）、临时 HERMES_DIR、
synthetic key、覆盖以下场景：

- `custom_providers` / `providers` 的 list / dict route fallback
- 显式 `model.base_url` 优先于 provider 条目路由
- 完全缺地址时 fail-closed 且不调用 curl
- 密钥不出现在 stdout / stderr / curl argv，仅存在于 0600 的 header 文件
- 默认与显式的 model / api_mode（Responses 与 Chat 的 SSE 成功流）
- 关键截断与失败流（SSE 截断、error 事件）fail-closed
- 严格校验非 SSE JSON shape：Responses 的 `status` / `output`，以及 Chat 的
  `choices` / assistant `message.content`
- 仅 JSON HTTP 400 触发 fallback；401/403/429/5xx 与 HTML 不 fallback
- base_url 凭据安全回归：拒绝 userinfo、percent-encoded userinfo、query 与
  fragment，且 marker 不出现在输出或 curl capture 中
- noisy 环境变量不影响行为与密钥选择
- 回归：`/responses` 载荷不含 `max_output_tokens`；`/chat/completions` 载荷
  保留 `max_tokens: 1`；HTTP 400 文案中性

## CI

`.github/workflows/test.yml`：ubuntu-latest，`permissions: contents: read`，
安装 jq / shellcheck / python3-yaml 后依次执行 `bash -n`、`shellcheck`、
`bash tests/run.sh`，与上文命令一致。

## 安全边界

- 测试全部使用 synthetic key 与临时目录，不触碰真实凭据。
- 脚本不执行 `.env` 中的任意代码；密钥经 `-H @file` 传入 curl，不进入 argv。
- 探测失败（非 200、非 JSON、SSE 异常、curl 错误）一律非零退出。

## 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 探测成功（`[PASS]`） |
| `1` | 所有探测失败：配置/解析、密钥/header、curl、HTTP 非 200、响应 shape 异常等 |
