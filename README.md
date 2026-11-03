# Parley

一个简易的 macOS LLM 聊天客户端，使用 OpenAI 兼容 API。纯 Swift / SwiftUI，没有任何第三方依赖。

## 构建与运行
```bash
./build.sh            # 生成 build/Parley.app（ad-hoc 签名）
open build/Parley.app
swift test            # 175 个测试：核心层 147 个，App 层 28 个；集成测试会自动启动 tools/mock_server.py
```
只装了 Command Line Tools 就能构建，不需要 Xcode。

## 用法
- **设置 → Providers**：填写 Base URL（需包含 `/v1`，例如 `http://192.168.1.20:1234/v1` 或 `https://api.openai.com/v1`）。API key 保存在 macOS 钥匙串里，不会同步到 iCloud。
- 会话的默认存放目录是 `~/Library/Application Support/Parley/Conversations`。这个位置不会被 iCloud 同步，可以在设置里修改。新建对话时也可以单独选择目录。
- 消息上的悬停按钮：复制、回滚到此处、从此处分叉、编辑并重发（用户消息）、重新生成（模型消息）。
- 思考内容：兼容 `reasoning_content`、`reasoning`，以及内联的 `<think>…</think>` 标签。
- 推理速度：生成时，窗口右下角的状态条实时显示每秒 token 数（tok/s），每秒刷新几次。回复结束后，速度和首个 token 的等待时间会显示在消息底部的 token 用量旁边（设置里的“显示 token 用量”同时控制它）。服务器返回 usage 或 llama.cpp 的 timings 时用精确数值；否则按流式分块估算（一块约等于一个 token），并标上“≈”。
- 上下文长度：状态条显示“已用 / 上限（百分比）”，超过 80% 变橙色，超过 95% 变红。点击可查看详情：已用 token、上限及其来源、模型最大值、服务器类型和速度。
  - Parley 会向当前服务器读取模型的上下文长度：LM Studio（`/api/v1/models`，旧版 `/api/v0/models`）、llama.cpp（`/props`）、vLLM（`max_model_len`）、Ollama（`/api/ps`），以及在线 API 模型列表里的字段。
  - 上限的优先级：服务器报告的当前值 > 你自己填写的值 > 模型最大值。只知道模型最大值时（例如 LM Studio 里还没加载的模型），状态条写成“max 256k”，因为实际加载的长度可能小得多。都不知道时显示“Context: unknown — set…”，可以在弹窗里填写一个数值（按服务器和模型分别保存）。服务器暂时连不上时不会记住“未知”，下次成功回复后会再问一次。
  - LM Studio 0.4 及以上可以在弹窗里“用 N tokens 重新加载模型”。这会在服务器上卸载并重新加载该模型，影响所有使用它的应用，所以必须先确认（回车不会触发），绝不会自动执行；填写的值和当前已加载的值相同时不能重新加载。重新加载在后台进行，关闭弹窗不会中断，失败信息会保留在弹窗和状态条里；同一服务器上的同一模型同时只能有一个重新加载。llama.cpp、vLLM、Ollama 和在线 API 无法在运行时修改，只能手动填写。
  - 已用 token 以最近一次服务器统计的 usage 为准（服务器报告 reasoning_tokens 时扣除思考部分）；之后的新消息和没有统计时按文字估算（中日韩字符约 1 字 1 token，其他约 4 字符 1 token），并标上“≈”。

## 加密格式
- 每次保存时对整个会话重新加密，然后原子写入（先写临时文件，再 rename）。文件里只有版本、KDF 参数、salt 和 id 是明文，标题、消息数和时间都在密文里。
- 加密方式：PBKDF2-HMAC-SHA256（60 万次迭代）派生密钥，再用 AES-256-GCM 加密，明文头部作为 AAD 防止篡改。
- 密码只在解锁时用来派生密钥，之后只有密钥保存在内存里。“锁定”会把密钥从内存中清除。

## 隐私
- 网络请求只发往你配置的 API 地址，并且会拒绝 HTTP 重定向。URLSession 是 ephemeral 模式：没有缓存，也没有 cookie。
- 读取上下文长度只会向同一个服务器（相同的协议、主机和端口）发送只读 GET 请求，超时 5 秒，失败时静默忽略。LM Studio、llama.cpp、Ollama 的原生接口只对本机、局域网或 Tailscale 地址（或模型列表显示是 LM Studio/llama.cpp 时）尝试。不会查询任何第三方的模型数据库。
- 聊天请求会附带 `stream_options: {include_usage: true}` 以获得 token 统计；如果服务器以 400/422 拒绝这个字段，会去掉它重试一次，并在本次运行中记住。
- 没有遥测，也不会把消息内容写进日志。Markdown 渲染不会加载远程图片。
- 复制按钮使用 `.currentHostOnly`，不会经由通用剪贴板同步到其他设备。
- 已知限制：在消息正文里选中文字后按 ⌘C，走的是系统默认剪贴板。
