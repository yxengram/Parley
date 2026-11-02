# Parley

一个简易的 macOS LLM 聊天客户端，使用 OpenAI 兼容 API。纯 Swift / SwiftUI，没有任何第三方依赖。

## 构建与运行
```bash
./build.sh            # 生成 build/Parley.app（ad-hoc 签名）
open build/Parley.app
swift test            # 108 个单元测试和集成测试（集成测试会自动启动 tools/mock_server.py）
```
只装了 Command Line Tools 就能构建，不需要 Xcode。

## 用法
- **设置 → Providers**：填写 Base URL（需包含 `/v1`，例如 `http://192.168.1.20:1234/v1` 或 `https://api.openai.com/v1`）。API key 保存在 macOS 钥匙串里，不会同步到 iCloud。
- 会话的默认存放目录是 `~/Library/Application Support/Parley/Conversations`。这个位置不会被 iCloud 同步，可以在设置里修改。新建对话时也可以单独选择目录。
- 消息上的悬停按钮：复制、回滚到此处、从此处分叉、编辑并重发（用户消息）、重新生成（模型消息）。
- 思考内容：兼容 `reasoning_content`、`reasoning`，以及内联的 `<think>…</think>` 标签。

## 加密格式
- 每次保存时对整个会话重新加密，然后原子写入（先写临时文件，再 rename）。文件里只有版本、KDF 参数、salt 和 id 是明文，标题、消息数和时间都在密文里。
- 加密方式：PBKDF2-HMAC-SHA256（60 万次迭代）派生密钥，再用 AES-256-GCM 加密，明文头部作为 AAD 防止篡改。
- 密码只在解锁时用来派生密钥，之后只有密钥保存在内存里。“锁定”会把密钥从内存中清除。

## 隐私
- 网络请求只发往你配置的 API 地址，并且会拒绝 HTTP 重定向。URLSession 是 ephemeral 模式：没有缓存，也没有 cookie。
- 没有遥测，也不会把消息内容写进日志。Markdown 渲染不会加载远程图片。
- 复制按钮使用 `.currentHostOnly`，不会经由通用剪贴板同步到其他设备。
- 已知限制：在消息正文里选中文字后按 ⌘C，走的是系统默认剪贴板。
