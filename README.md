# Caddy 反向代理 OpenAI API（含 SSE）

本文档记录在 Debian 13 上使用 Caddy 将 `openai-proxy.codex.hk` 反向代理到 `api.openai.com` 的完整配置与验证步骤，确保对 Server‑Sent Events (SSE) 流式传输良好支持。

## 环境
- OS: Debian 13
- Caddy: 2.6.2（系统包安装，二进制位于 `/usr/bin/caddy`）
- Systemd 服务: `/lib/systemd/system/caddy.service`
- 主配置文件: `/etc/caddy/Caddyfile`

## 目标
- 将域名 `openai-proxy.codex.hk` 的请求代理到 `https://api.openai.com`
- 正确转发 `Authorization` 等头部
- 支持 OpenAI 的 SSE 流式响应（通过禁用响应缓冲、启用 HTTP/2 等）

## 配置改动
在 `/etc/caddy/Caddyfile` 中新增站点块：

```caddy
# Reverse proxy for OpenAI API with SSE streaming support
openai-proxy.codex.hk {
    # 该站点的访问日志
    log {
        output file /var/log/caddy/openai-proxy.log
        format console
        level INFO
    }

    # 反向代理到 OpenAI API
    reverse_proxy https://api.openai.com {
        # 确保 Host/SNI 正确
        header_up Host api.openai.com
        # 保留鉴权头与常见代理头
        header_up Authorization {http.request.header.Authorization}
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote}

        # SSE：尽量不缓冲响应，实时刷出
        flush_interval -1

        transport http {
            versions h2 h1.1
            tls_server_name api.openai.com
        }
    }
}
```

说明：
- `flush_interval -1` 关闭响应缓冲，有利于 SSE token 逐步输出。
- `transport http { versions h2 h1.1 }` 允许与上游（OpenAI）使用 HTTP/2，进一步优化流式体验。
- Caddy 默认会透传大部分头部，`X-Forwarded-*` 三行可选（可删除），保留不影响功能。

## 应用配置
- 语法校验：`caddy validate --config /etc/caddy/Caddyfile`
- 重载生效：`systemctl reload caddy`

若需要查看服务状态：
- `systemctl status --no-pager caddy`
- `journalctl -u caddy --no-pager -n 200`

## 证书与监听
- Caddy 自动为 `openai-proxy.codex.hk` 申请并管理 TLS 证书（Let’s Encrypt/ACME）。
- 自动开启 80/443 监听与 HTTP→HTTPS 跳转。

## 验证
最小验证（未带 Key，预期 401）：

```bash
curl -I https://openai-proxy.codex.hk/v1/models
```

看到 `HTTP/2 401`，并包含 OpenAI/Cloudflare 相关响应头，说明代理链路正确。

SSE 测试（需自备 OpenAI API Key）：

```bash
export OPENAI_API_KEY=sk-...  # 请替换
curl -N https://openai-proxy.codex.hk/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "model":"gpt-4o-mini",
        "messages":[{"role":"user","content":"hello"}],
        "stream":true
      }'
```

若输出逐行以 `data:` 开头的事件块，表示 SSE 正常实时推送。

## 客户端示例
- Python（`openai` SDK 新版）：
  ```python
  from openai import OpenAI
  client = OpenAI(base_url="https://openai-proxy.codex.hk/v1", api_key="sk-...")
  with client.chat.completions.stream.create(
      model="gpt-4o-mini",
      messages=[{"role": "user", "content": "hello"}],
  ) as stream:
      for event in stream:
          print(event)
  ```

- Node.js：
  ```js
  import OpenAI from "openai";
  const openai = new OpenAI({ baseURL: "https://openai-proxy.codex.hk/v1", apiKey: process.env.OPENAI_API_KEY });
  const res = await openai.chat.completions.create({
    model: "gpt-4o-mini",
    messages: [{ role: "user", content: "hello" }],
    stream: true,
  });
  for await (const part of res) {
    process.stdout.write(JSON.stringify(part));
  }
  ```

## 常见问题排查
- DNS：`openai-proxy.codex.hk` 必须正确解析到本机公网 IP。
- 防火墙/安全组：放通 80/443。
- 证书申请失败：看 `journalctl -u caddy` 中的 ACME 日志，确保 80/443 可被外网访问。
- 访问日志：`/var/log/caddy/openai-proxy.log`。
- Caddyfile 格式：可运行 `caddy fmt --overwrite /etc/caddy/Caddyfile` 美化（不影响功能）。
- 如遇到反代 4xx/5xx，可用 `curl -v` 查看请求/响应头是否被正确转发（尤其 `Authorization`）。

## 安全注意
- 代理会透传 `Authorization` 到上游 OpenAI，请保证代理主机安全、日志不要记录敏感信息（本配置未记录请求体）。
- 与上游通信全程 TLS，`tls_server_name` 指定为 `api.openai.com` 保证 SNI 与证书校验一致。

## 变更摘要（此次操作）
- 在 `/etc/caddy/Caddyfile` 新增 `openai-proxy.codex.hk` 站点块，反代到 `https://api.openai.com`。
- 启用访问日志：`/var/log/caddy/openai-proxy.log`。
- 配置 SSE 友好参数：`flush_interval -1`、上游 `h2`、`tls_server_name`。
- 通过 `caddy validate` 校验并 `systemctl reload caddy` 生效。
- 通过 `curl -I /v1/models` 验证连通性（返回 401 为预期）。

---
如需我将冗余的 `X-Forwarded-*` 三行移除并统一格式化 Caddyfile，可告知，我可直接更新并重载服务。

## 快速测试（隐藏 Bearer 示例）

本仓库附带了一个最小化的流式 Responses API 测试脚本与示例负载：

1) 设置密钥（示例中仅展示部分，实际请替换为完整密钥）

```bash
export OPENAI_API_KEY="sk-proj-***********************************A13cF"  # 示例，已部分隐藏
```

2) 运行测试脚本（使用 `-N` 关闭本地缓冲，便于实时查看 SSE）

```bash
bash scripts/test_responses.sh payload.responses.json
```

3) 期待输出

- 将看到以 `event:`、`data:` 开头的多行 SSE 事件，如：
  - `response.created`
  - `response.in_progress`
  - `response.output_text.delta`（内容逐步增量输出）

脚本说明：
- 默认请求地址为 `https://openai-proxy.codex.hk/v1/responses`，可通过环境变量 `API_BASE` 覆盖，例如：
  `API_BASE=https://openai-proxy.codex.hk bash scripts/test_responses.sh`
- 不在终端打印完整密钥；脚本仅显示头尾少量字符用于确认，避免泄露。
