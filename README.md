# hermes-provider-probe

对 Hermes 主 LLM provider 的最小化可用性探测脚本：以极小 token 消耗（提示词仅
`Reply OK.`）验证配置的 provider/model 是否真正可用，并输出所用 endpoint、
HTTP 状态与 token 用量。用于在依赖方暴露连接故障之前，快速定位配置或上游问题。

## 特性

- 默认健康检查模型 `gpt-5.6-luna`，`reasoning.effort=none`（最小开销），可用
  `TEST_MODEL` 覆盖。
- 默认走 `codex_responses`（`/responses`）；显式配置 `api_mode: chat_completions`
  时走 `/chat/completions`。
- Token 策略按 endpoint 区分：
  - `/responses` 载荷**完全省略** `max_output_tokens`——上游对该字段（即使值为 1）
    返回 HTTP 400 `upstream_error`；省略后使用 provider default 输出上限。
  - `/chat/completions` 保留 `max_tokens: 1`。
- 主 endpoint 返回 HTTP 400 时自动改试另一 endpoint（401/403/429/5xx 与 HTML
  响应一律不重试）；文案中性，仅报告 `returned HTTP 400`。
- 密钥只写入权限 0600 的 header 文件，不进入 curl 参数，也不打印到终端。
- 任何异常 shape（curl 失败、非 JSON、SSE 截断/错误事件、非 200）一律
  fail-closed 并以非零退出码结束，绝不误报成功。

## 依赖

- bash 4+
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
- 密钥来源优先级：`model.api_key`（支持 `${ENV}` 引用）→ 匹配 provider 条目的
  `key_env` / `api_key` → 兼容环境变量（`CODEX_API_KEY` 等）。找不到密钥时退出码 2。
- 输出提示词按 endpoint 准确说明 token 策略：Responses 使用 provider default，
  Chat 使用 `max_tokens: 1`。

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
- 仅 JSON HTTP 400 触发 fallback；401/403/429/5xx 与 HTML 不 fallback
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
| `1` | 探测失败：配置缺失、curl 错误、HTTP 非 200、响应 shape 异常 |
| `2` | 配置解析/密钥问题：PyYAML 缺失、必需环境变量缺失、非法 header 等 |
