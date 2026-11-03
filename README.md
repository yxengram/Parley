# Parley

一个简易的 macOS LLM 聊天客户端，使用 OpenAI 兼容 API。纯 Swift / SwiftUI，没有任何第三方依赖。

## 构建与运行
```bash
./build.sh            # 生成 build/Parley.app（ad-hoc 签名）
open build/Parley.app
swift test            # 205 个测试：核心层 167 个，App 层 38 个；集成测试会自动启动 tools/mock_server.py
```
只装了 Command Line Tools 就能构建，不需要 Xcode。

## 用法
- **设置 → Providers**：填写 Base URL（需包含 `/v1`，例如 `http://192.168.1.20:1234/v1` 或 `https://api.openai.com/v1`）。API key 保存在 macOS 钥匙串里，不会同步到 iCloud。
- 会话的默认存放目录是 `~/Library/Application Support/Parley/Conversations`。这个位置不会被 iCloud 同步，可以在设置里修改。新建对话时也可以单独选择目录。
- 消息上的悬停按钮：复制、回滚到此处、从此处分叉、编辑并重发（用户消息）、重新生成（模型消息）。
- 思考内容：兼容 `reasoning_content`、`reasoning`，以及内联的 `<think>…</think>` 标签。
- 回复因达到 token 上限而被截断时（`finish_reason: length`），消息下方会说明原因：用满了 Max Tokens 时，提示提高 Max Tokens、降低推理强度或设置思考预算；没有设置 Max Tokens，或回复比 Max Tokens 短（上下文已满，Strata 会把 Max Tokens 缩短到剩余空间）时，提示新建对话、分叉或回滚。
- 推理速度：生成时，窗口右下角的状态条实时显示每秒 token 数（tok/s），每秒刷新几次。回复结束后，速度和首个 token 的等待时间会显示在消息底部的 token 用量旁边（设置里的“显示 token 用量”同时控制它）。服务器返回 usage 或 llama.cpp/Strata 的 timings 时用精确数值；否则按流式分块估算（一块约等于一个 token），并标上“≈”。等待第一个 token 时显示已等待的秒数；服务器报告读取提示词的进度时（Strata、llama.cpp），显示“Reading the prompt: 42% …”。
- 上下文长度：状态条显示“已用 / 上限（百分比）”，超过 80% 变橙色，超过 95% 变红。点击可查看详情：已用 token、上限及其来源、模型最大值、服务器类型和速度。
  - Parley 会向当前服务器读取模型的上下文长度：LM Studio（`/api/v1/models`，旧版 `/api/v0/models`）、llama.cpp（`/props`）、vLLM（`max_model_len`）、Ollama（`/api/ps`），以及在线 API 模型列表里的字段。
  - 上限的优先级：服务器报告的当前值 > 你自己填写的值 > 模型最大值。只知道模型最大值时（例如 LM Studio 里还没加载的模型），状态条写成“max 256k”，因为实际加载的长度可能小得多。都不知道时显示“Context: unknown — set…”，可以在弹窗里填写一个数值（按服务器和模型分别保存）。服务器暂时连不上时不会记住“未知”，下次成功回复后会再问一次。
  - LM Studio 0.4 及以上可以在弹窗里“用 N tokens 重新加载模型”。这会在服务器上卸载并重新加载该模型，影响所有使用它的应用，所以必须先确认（回车不会触发），绝不会自动执行；填写的值和当前已加载的值相同时不能重新加载。重新加载在后台进行，关闭弹窗不会中断，失败信息会保留在弹窗和状态条里；同一服务器上的同一模型同时只能有一个重新加载。llama.cpp、vLLM、Ollama 和在线 API 无法在运行时修改，只能手动填写。
  - 已用 token 以最近一次服务器统计的 usage 为准，并扣除思考部分（思考内容不会再发回服务器）：服务器报告 reasoning_tokens 时用它，否则按思考文字估算（LM Studio、llama.cpp、Strata 都不报告）；之后的新消息和没有统计时按文字估算（中日韩字符约 1 字 1 token，其他约 4 字符 1 token），并标上“≈”。

## Strata
Parley 能识别 [Strata](https://github.com/Niko1221/Strata)，并针对它做了这些处理：
- **识别方式**：Strata 桌面版“在网络上共享”的端口（默认 47832）的模型列表写着 `owned_by: "strata"`；直接运行的 Strata 引擎（`serve/server.py`，默认 8080）则通过不需要 key 的 `GET /health`（`"service":"strata"`）识别。识别后弹窗里的“Server”显示 Strata。共享端口只有 `/v1/models`、`/v1/chat/completions`、`/v1/messages` 三个接口，所以 Parley 不会再向它发送其他探测请求。
- **上下文长度**：共享端口不报告上下文长度（Strata issue #3931），请在弹窗里填写 Strata 安装时选择的值（例如 131072）。引擎端口从 `/health` 和模型列表读取。Strata 在启动模型时就固定了上下文长度，API 无法修改，所以没有“重新加载”按钮；要改只能在 Strata 里重新设置。
- **超出上下文**：Max Tokens 总是按你的设置发送。Strata 默认（`fit_max_tokens` 开启）会把放不下的 Max Tokens 精确缩短到剩余空间；关闭 `fit_max_tokens` 时会报 400，并给出最多还能用多少。Strata 的超长错误会显示成可读的说明：对话有多少 token、上下文多大，以及下一步怎么做（新建对话、从更早的消息分叉、回滚，或把 Max Tokens 降到提示的数值）。错误里的上下文长度也会自动填入状态条。
- **思考**：推理强度照常发送 low/medium/high（Strata 把 high 当作最高档）。连接 Strata 时，会话设置里多出“Off (no thinking)”（发送 `reasoning_effort: "none"`）和“Thinking Budget”（`reasoning_budget_tokens`）。这两项只发给 Strata，其他服务器收不到。
- **提示词进度与速度**：只对 Strata 发送 `return_progress: true`，读取提示词时显示进度和缓存命中的 token 数；10 秒内没有任何数据时提示“Strata may be loading the model”。tok/s 使用 Strata 自己报告的 `predicted_per_second`；弹窗里还显示提示词读取速度和缓存命中的 token 数。
- **图片**：共享端口单次请求最多 12 MB（运行时模式 4 MB），而每条消息都会重新发送之前的所有图片，所以超出时 Parley 在发送前就拒绝（不提供重试按钮，因为重试只会同样失败），并建议从第一张图片之前分叉或新建对话。模型没有开启图片读取（Pictures）时，Strata 会拒绝请求；Parley 会记住这一点（只在内存中），并在输入框上方提前警告：草稿里有图片时提示移除它；对话里之前已经有图片时（每条消息都会重新发送它们），提示在 Strata 里开启 Pictures 或从第一张图片之前分叉。
- **其他错误**：模型还在加载、没有加载模型、暂停了新请求、引擎正在启动或已停止、正忙（Strata 一次只处理一个请求，排队超时）、显存被其他程序占用、API key 错误、共享端口连不上（可能换了端口）等情况都会显示成明确的说明和重试建议（共享端口不转发 Retry-After）。
- 这些请求都只发往你配置的 Strata 地址本身（相同协议、主机和端口），与其他请求一样不跟随重定向。

## 加密格式
- 每次保存时对整个会话重新加密，然后原子写入（先写临时文件，再 rename）。文件里只有版本、KDF 参数、salt 和 id 是明文，标题、消息数和时间都在密文里。
- 加密方式：PBKDF2-HMAC-SHA256（60 万次迭代）派生密钥，再用 AES-256-GCM 加密，明文头部作为 AAD 防止篡改。
- 密码只在解锁时用来派生密钥，之后只有密钥保存在内存里。“锁定”会把密钥从内存中清除。

## 隐私
- 网络请求只发往你配置的 API 地址，并且会拒绝 HTTP 重定向。URLSession 是 ephemeral 模式：没有缓存，也没有 cookie。
- 读取上下文长度只会向同一个服务器（相同的协议、主机和端口）发送只读 GET 请求，超时 5 秒，失败时静默忽略。LM Studio、Strata 引擎（`/health`）、llama.cpp、Ollama 的原生接口只对本机、局域网或 Tailscale 地址（或模型列表显示是 LM Studio/llama.cpp/Strata 时）尝试；Strata 共享端口除了模型列表什么都不问，`/slots` 永远不读。不会查询任何第三方的模型数据库。
- 聊天请求会附带 `stream_options: {include_usage: true}` 以获得 token 统计；如果服务器以 400/422 拒绝这个字段，会去掉它重试一次，并在本次运行中记住。
- 没有遥测，也不会把消息内容写进日志。Markdown 渲染不会加载远程图片。
- 复制按钮使用 `.currentHostOnly`，不会经由通用剪贴板同步到其他设备。
- 已知限制：在消息正文里选中文字后按 ⌘C，走的是系统默认剪贴板。
