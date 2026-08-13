# opencode-go → Codex 一键接入

把 opencode 的 **OpenCode Go 订阅**(DeepSeek V4 Pro 等)一键接入 **Codex**(桌面端 / CLI),并自动完成:
API key 获取、模型注册、工具启用、联网沙箱、超时回退策略的配置。

## 解决的问题

| 问题 | 原因 | 本项目的方案 |
|---|---|---|
| codex 无法使用 v4-pro | codex 只支持 `wire_api = "responses"`,而 opencode-go 的 deepseek-v4-pro 只在 `/chat/completions` 可用 | 本地转换代理:Responses ↔ Chat Completions(含流式 SSE、工具调用、思考内容转换) |
| 模型"显示为自定义"、无工具 | codex 只为它认识的模型注入工具;未知模型(lite 模式)拿不到 `tools` 数组 | 用已知模型名(`gpt-5.6-sol`)发起,代理改写为真实模型;注册表声明 `use_responses_lite=false`、`tool_mode=direct` |
| 第二轮对话报 `reasoning_content must be passed back` | DeepSeek 思考型模型要求思考内容在后续请求中回传 | 代理捕获 `reasoning_content` → 以 reasoning 项发给 codex → 下一轮自动回传 |
| 联网/克隆失败 | 应用沙箱默认禁止本地会话联网;git 在受限进程内 schannel 拿不到凭据 | 写入 `sandbox_mode=workspace-write` + 网络访问;`GIT_SSL_BACKEND=openssl` |
| 频繁卡住重试 | codex 默认流空闲超时 5 分钟、重试 5 次 | `stream_idle_timeout_ms=120s`、`stream_max_retries=2`、`request_max_retries=2` |

## 环境要求

### Windows(脚本基于 PowerShell 5.1)

- Python 3(转换代理 `ogproxy.py` 运行在本地 127.0.0.1:8765)
- Codex 桌面应用或 CLI
- opencode(用于获取/存放 OpenCode Go 订阅的 API key)

### macOS

- macOS(脚本基于 bash + python3,系统自带)
- Codex 桌面应用或 CLI(CLI 自动识别 PATH 或 `/Applications/ChatGPT.app/Contents/Resources/codex`)
- opencode(用于获取/存放 OpenCode Go 订阅的 API key)

## 快速开始

### Windows

1. 把本目录拷贝到目标机器(如 `C:\Users\<你>\scripts\opencode-to-codex\`)
2. 双击 **`go-to-codex.bat`**
   - 若检测不到 OpenCode Go 的 key,会自动打开 `https://opencode.ai/auth`
   - 登录后粘贴 API key(`sk-` 开头),自动验证并保存到 opencode 的 `auth.json`
   - 自动启动转换代理 → 写入 `~/.codex/config.toml` → 用 codex CLI 发测试消息验证
3. 完全退出并重新打开 Codex 桌面应用(新配置对新聊天生效)
4. 开始使用:模型为 DeepSeek V4 Pro,支持工具调用与联网

切回 ChatGPT:双击 **`back-to-chatgpt.bat`**(保留 provider 配置,可随时切回)。

### macOS

1. 把本目录拷贝到目标机器(如 `~/opencode-go-codex-bridge/`)
2. 运行 **`./go-to-codex.sh`**(或双击 **`go-to-codex.command`**)
   - 自动从 `~/.local/share/opencode/auth.json` 读取 OpenCode Go 的 key
   - 若检测不到,会自动打开 `https://opencode.ai/auth`,粘贴 API key(`sk-` 开头)即可
   - 自动启动转换代理 → 写入 `~/.codex/config.toml` → 用 codex CLI 发测试消息验证
3. 完全退出并重新打开 Codex 桌面应用(新配置对新聊天生效)
4. 开始使用:模型为 DeepSeek V4 Pro,支持工具调用与联网

切回 ChatGPT:运行 **`./back-to-chatgpt.sh`**(或双击 `back-to-chatgpt.command`,保留 provider 配置,可随时切回)。

## 文件说明

| 文件 | 作用 |
|---|---|
| `go-to-codex.bat` / `.ps1` | Windows 一键:获取 key → 验证订阅 → 启动代理 → 写配置 → CLI 验证 |
| `back-to-chatgpt.bat` / `.ps1` | Windows 切回 `gpt-5.6-sol`(保留 opencode-go provider 配置) |
| `common.ps1` | Windows 共享逻辑:key 获取/保存、config.toml 编辑(容错混合行尾)、代理启动 |
| `go-to-codex.sh` / `.command` | macOS 一键(对应 .bat/.ps1) |
| `back-to-chatgpt.sh` / `.command` | macOS 切回(对应 .bat/.ps1) |
| `common.sh` | macOS 共享逻辑(对应 common.ps1,bash + 内嵌 python3 编辑 config.toml) |
| `ogproxy.py` | 本地转换代理:模型注册表 + Responses→Chat 翻译(流式/非流式、工具调用合并、思考内容回传) |

## 工作原理

1. **模型名技巧**:codex 只为"已知模型"注入工具。配置里 `model = "gpt-5.6-sol"`,代理把请求改写为 `deepseek-v4-pro` 发送到 opencode-go。
2. **协议转换**:codex 走 Responses API;opencode-go 的 v4-pro 只支持 chat/completions。代理做双向翻译,包括 SSE 流式事件、`function_call`/`function_call_output` 配对、并行工具调用合并。
3. **思考内容闭环**:DeepSeek 思考型模型要求历史中的 assistant 消息携带 `reasoning_content`。代理从流中捕获,以 reasoning 项发送给 codex,下轮自动回传。
4. **注册表**:代理的 `/v1/models` 返回完整模型元数据(`use_responses_lite=false`、`tool_mode=direct`、上下文窗口等),让 codex 以非 lite 模式运行,获得原生函数调用。

## 注意事项

- 代理是本地单点,电脑重启后请先运行一次 `go-to-codex.bat`(会自动拉起代理)
- 沙箱/网络设置对**新聊天**生效
- deepseek 系列为纯文本模型,不支持图片输入
- 订阅有速率限制,连续高频请求可能触发上游限流
