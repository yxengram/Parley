# Parley

一个简易的 macOS LLM 聊天客户端，使用 OpenAI 兼容 API。纯 Swift / SwiftUI，没有任何第三方依赖。

## 构建与运行
```bash
./build.sh            # 生成 build/Parley.app（ad-hoc 签名）
open build/Parley.app
swift test            # 260 个测试：核心层 187 个，App 层 73 个；集成测试会自动启动 tools/mock_server.py
```
只装了 Command Line Tools 就能构建，不需要 Xcode。

## 用法
- **设置 → Providers**：填写 Base URL（需包含 `/v1`，例如 `http://192.168.1.20:1234/v1` 或 `https://api.openai.com/v1`）。API key 保存在 macOS 钥匙串里，不会同步到 iCloud。用 `http://` 连接互联网地址时（不是本机、局域网、Tailscale 的 100.x 地址或 MagicDNS 的 `*.ts.net` 名字），设置里会警告：API key 和聊天内容会以明文经过互联网，并给出对应的 `https://` 地址。Tailscale 走 WireGuard 加密，所以 `http://100.x…` 和 `http://….ts.net` 不警告。
- 会话的默认存放目录是 `~/Library/Application Support/Parley/Conversations`。这个位置不会被 iCloud 同步，可以在设置里修改。新建对话时也可以单独选择目录。
- 消息上的悬停按钮：复制、回滚到此处、从此处分叉、编辑并重发（用户消息）、重新生成（模型消息）。
- 思考内容：兼容 `reasoning_content`、`reasoning`，以及内联的 `<think>…</think>` 标签。
- **不思考（None）**：会话设置（⌘I）的推理强度可以直接选“None (no thinking)”，所有服务器都可以选（默认仍是“Not sent”，什么都不发）。按服务器类型发送：
  - 已确认的：Strata 发 `reasoning_effort: "none"`（实测）；llama.cpp 和 vLLM 发 `chat_template_kwargs: {"enable_thinking": false}`（是否生效取决于模型的聊天模板，例如 Qwen3 支持，gpt-oss 不支持；vLLM 旧版和 gpt-oss 会以 400 拒绝 `"none"`，所以不发它）；Ollama 发 `reasoning_effort: "none"`（0.12.4 起等于 `think: false`）。
  - 尽力而为的：LM Studio、在线 API 和还没识别出类型的服务器发 `reasoning_effort: "none"`。LM Studio 的文档没有写明它接受这个值（未验证）；OpenAI gpt-5.1 及以后、OpenRouter、Gemini 2.5 Flash 支持，有些模型会拒绝。
  - 服务器以 400/422 拒绝这个字段（错误里提到这个字段、reasoning 或 thinking）时，Parley 去掉它重试一次。重试成功，才在回复下方说明服务器没有接受 None、这条回复用了默认的思考方式，并在本次运行中对这个 Provider 的这个模型记住被拒的字段，之后不再发送，回复照样标注；重试也失败，说明不是这个字段的问题，显示原来的错误，什么都不记。上下文超长等其他 400 不重试；Strata 已确认接受 None，它的 400 也不重试。
  - 发了 None 却仍收到思考内容时，回复下方注明服务器或模型忽略了它（LM Studio 会提示该模型的设置里可能有思考开关，界面位置未核实）。连续几条回复是同一种情况时，后面的只显示一行简短说明。这些标注保存在会话文件里，旧版本仍能打开文件。
  - 刚启动、还没识别出服务器类型时，用 None 的消息会先等识别结果（最多 4 秒），用思考预算的最多等约 6.5 秒（没识别出 Strata 就不能发预算）；Stop 可以立即取消。其他设置不等待。
  - 以前在 Strata 上设为“Off”的会话，现在显示为 None；换到其他服务器时也会按上面的方式发送（以前其他服务器什么都收不到）。
- 回复因达到 token 上限而被截断时（`finish_reason: length`），消息下方会说明原因：用满了 Max Tokens 时，提示提高 Max Tokens、降低推理强度（或选 None），在 Strata 上也可以设置思考预算；没有设置 Max Tokens，或回复比 Max Tokens 短（上下文已满，Strata 会把 Max Tokens 缩短到剩余空间）时，提示新建对话、分叉或回滚。
- 推理速度：生成时，窗口右下角的状态条实时显示每秒 token 数（tok/s），每秒刷新几次。回复结束后，速度和首个 token 的等待时间会显示在消息底部的 token 用量旁边（设置里的“显示 token 用量”同时控制它）。服务器返回 usage 或 llama.cpp/Strata 的 timings 时用精确数值；否则按流式分块估算（一块约等于一个 token），并标上“≈”。等待第一个 token 时显示已等待的秒数；服务器报告读取提示词的进度时（Strata 引擎、llama.cpp），显示“Reading the prompt: 42% …”。
- 上下文长度：状态条显示“已用 / 上限（百分比）”，超过 80% 变橙色，超过 95% 变红。点击可查看详情：已用 token、上限及其来源、模型最大值、服务器类型和速度。
  - Parley 会向当前服务器读取模型的上下文长度：LM Studio（`/api/v1/models`，旧版 `/api/v0/models`）、llama.cpp（`/props`）、vLLM（`max_model_len`）、Ollama（`/api/ps`），以及在线 API 模型列表里的字段。
  - 上限的优先级：服务器报告的当前值 > 你自己填写的值 > 从服务器的超长错误里得知的值 > 模型最大值。只知道模型最大值时（例如 LM Studio 里还没加载的模型），状态条写成“max 256k”，因为实际加载的长度可能小得多。都不知道时显示“Context: unknown — set…”，可以在弹窗里填写一个数值（按服务器和模型分别保存）。服务器暂时连不上时不会记住“未知”，下次成功回复后会再问一次。
  - LM Studio 0.4 及以上可以在弹窗里“用 N tokens 重新加载模型”。这会在服务器上卸载并重新加载该模型，影响所有使用它的应用，所以必须先确认（回车不会触发），绝不会自动执行；填写的值和当前已加载的值相同时不能重新加载。重新加载在后台进行，关闭弹窗不会中断，失败信息会保留在弹窗和状态条里；同一服务器上的同一模型同时只能有一个重新加载。llama.cpp、vLLM、Ollama 和在线 API 无法在运行时修改，只能手动填写。
  - 已用 token 以最近一次服务器统计的 usage 为准，并扣除思考部分（思考内容不会再发回服务器）：服务器报告 reasoning_tokens 时用它，否则按思考文字估算（LM Studio、llama.cpp、Strata 都不报告）；之后的新消息和没有统计时按文字估算（中日韩字符约 1 字 1 token，其他约 4 字符 1 token），并标上“≈”。

## Strata
Parley 能识别 [Strata](https://github.com/Niko1221/Strata)，并针对它做了这些处理：
- **识别方式**：Strata 桌面版“在网络上共享”的端口（默认 47832）的模型列表写着 `owned_by: "strata"`；直接运行的 Strata 引擎（`serve/server.py`，默认 8080）则通过不需要 key 的 `GET /health`（`"service":"strata"`）识别。识别后弹窗里的“Server”显示 Strata。共享端口只有 `/v1/models`、`/v1/chat/completions`、`/v1/messages` 三个接口，所以 Parley 不会再向它发送其他探测请求。
- **上下文长度**：共享端口不报告上下文长度（Strata issue #3931），请在弹窗里填写 Strata 安装时选择的值（例如 131072），或者等第一次超长错误：Parley 会从错误里读出上下文长度（“learned from Strata's error”），保存下来，重启 Parley 后仍然有效；之后的超长错误给出不同数值时会更新它。你填写的值和从错误里得知的值以较新的为准：之后的超长错误给出与你填写的不同的数值时，会替换你填写的值（服务器刚说明了它实际用的大小）；之后再填写的值又优先于它，弹窗里会同时显示“Last error”那一行。引擎端口从 `/health` 和模型列表读取。Strata 在启动模型时就固定了上下文长度，API 无法修改，所以没有“重新加载”按钮；要改只能在 Strata 里重新设置。
- **多条线路共享**：同一个 Strata 可以通过多个地址访问（例如 Tailscale `http://100.x.x.x:47832/v1` 和 Cloudflare Tunnel `https://…/v1`，用同一个 key）。Parley 从 `/v1/models` 的 `meta.instanceId` 识别出它们是同一个实例，于是你填写的值和从错误里得知的值对这个模型的所有线路都生效（按实例 id + 模型保存）；没有实例 id 的服务器仍按“服务器 + 模型”分别保存。以前按单个 Provider 填写的值会在第一次读到实例 id 时迁移过去。Strata 重新启动模型后实例 id 会改变（实测同一个模型隔天换了 id），这时你填写的值会带到新 id 上，其他线路也跟着指向新 id；从错误里得知的值不带过去（重启后上下文可能不同，下一次超长错误会再告诉 Parley）。Provider 改成别的地址后，不再沿用原来实例的数值；没有任何线路再用到的旧实例数值会被删除。
- **超出上下文**：Max Tokens 总是按你的设置发送。Strata 默认（`fit_max_tokens` 开启）会把放不下的 Max Tokens 精确缩短到剩余空间；关闭 `fit_max_tokens` 时会报 400，并给出最多还能用多少。Strata 的超长错误会显示成可读的说明：对话有多少 token、上下文多大，以及下一步怎么做（新建对话、从更早的消息分叉、回滚，或把 Max Tokens 降到提示的数值）。错误里的上下文长度也会自动填入状态条。
- **思考**：推理强度照常发送 low/medium/high（Strata 把 high 当作最高档），“None (no thinking)”按服务器类型发送（见上面的“不思考”）。连接 Strata 时，会话设置里还多出“Thinking Budget”（`reasoning_budget_tokens`），它只发给 Strata，其他服务器收不到。
- **提示词进度与速度**：只对 Strata 发送 `return_progress: true`。Strata 引擎会返回读取提示词的进度和缓存命中的 token 数，Parley 会显示出来（引擎端口的这一点没有实测）；实测桌面版的共享端口目前不发送进度（读 6505 个 token 的提示词用了 4 秒，只有 keep-alive），所以通过共享端口时只显示已等待的秒数。10 秒后还没有进度和第一个 token 时提示“Strata may be loading the model or reading a long prompt”。tok/s 使用 Strata 自己报告的 `predicted_per_second`；弹窗里还显示提示词读取速度和缓存命中的 token 数。
- **图片**：共享端口单次请求最多 12 MB（运行时模式 4 MB），而每条消息都会重新发送之前的所有图片，所以超出时 Parley 在发送前就拒绝（不提供重试按钮，因为重试只会同样失败），并建议从第一张图片之前分叉或新建对话。模型没有开启图片读取（Pictures）时，Strata 会拒绝请求；Parley 会记住这一点（只在内存中），并在输入框上方提前警告：草稿里有图片时提示移除它；对话里之前已经有图片时（每条消息都会重新发送它们），提示在 Strata 里开启 Pictures 或从第一张图片之前分叉。
- **其他错误**：模型还在加载、没有加载模型、暂停了新请求、引擎正在启动或已停止、正忙（Strata 一次只处理一个请求，排队超时）、显存被其他程序占用、API key 错误、共享端口连不上（可能换了端口）等情况都会显示成明确的说明和重试建议（共享端口不转发 Retry-After）。
- 这些请求都只发往你配置的 Strata 地址本身（相同协议、主机和端口），与其他请求一样不跟随重定向。

## Cloudflare（Tunnel 或代理的域名）
适用于任何放在 Cloudflare 后面的服务器，不只是 Strata：
- **Cloudflare 自己的错误页**不会以 HTML 显示，而是存成一行（例如 `HTTP 524: Cloudflare error 524: A timeout occurred · Ray ID …`，“Details”里可以看到），并说明下一步：
  - 524：服务器 100 秒内没有开始回答（模型可能正在加载或正忙），过一分钟再试；Tailscale/局域网地址没有这个限制。
  - 530 / 错误 1033：Cloudflare Tunnel 没有连到服务器所在的电脑（cloudflared 或 Strata 没在运行，或电脑睡眠/离线）。
  - 520–523、502、504：Cloudflare 正常，但后面的服务器没有回应。525/526：Cloudflare 到服务器的 TLS 设置问题。
  - 403 质询或防火墙拦截（WAF、Bot Fight Mode、错误 1020）：API 客户端无法通过浏览器验证，需要在 Cloudflare 为 `/v1/*` 加跳过规则，或改用 Tailscale 地址。429 / 错误 1015：Cloudflare 的限速规则。
  - 重定向到 `*.cloudflareaccess.com`：这个地址受 Cloudflare Access 保护，需要浏览器登录，Parley 做不到（它从不跟随重定向，所以什么也没发到登录页）。其他重定向也会说明指向哪里；例如 http 被转到 https 时，提示把 Base URL 改成 https。
- 经过 Cloudflare 的**服务器自身错误**（Strata 的 401、超长、正忙等 JSON 错误）照常识别：只有 Cloudflare 专有的状态码、错误页标记、质询头或 Access 重定向才算 Cloudflare 的错误。
- **回复中途断开**：服务器已经开始回答后连接断了（隧道重启、电脑睡眠、网络切换），或者响应在没有 `finish_reason` / `[DONE]` 的情况下结束，都会显示“The connection dropped before the reply finished”，已经收到的文字保留，经过 Cloudflare 时会说明。Retry 会重新请求整条回复。
- **超时**：Parley 的请求超时是 600 秒（指两次收到数据之间的间隔）；Cloudflare 在 100 秒没有任何字节时返回 524。Strata 排队或读取提示词时每 10 秒内会发送 `: keep-alive`，所以流式回复不会因此中断；只有在第一个字节之前就等了 100 秒（例如冷启动加载模型）才会碰到 524。
- Cloudflare 响应里的 `nel` / `report-to` 头 Parley 自己不读也不处理；Parley 发出的请求仍然只发往你配置的地址。实测（尽力而为）：通过隧道收到两次带这些头的 401 后观察了 80 秒，没有任何到上报地址的连接；macOS 的网络框架里也找不到 NEL/Report-To 的实现，看起来系统不会按 NEL 上报。

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
