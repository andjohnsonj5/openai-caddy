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
- 将 `chatgpt.codex.hk` 的请求整体反代至 `https://chatgpt.com`，确保浏览与 `backend-api` 均可使用

## 配置改动
完整示例配置可参考仓库内的 `config/Caddyfile`，并在 `/etc/caddy/Caddyfile` 中应用。以下按站点拆分说明（均默认进行隐私加固：不向上游暴露客户端 IP，访问日志中删除 IP 字段）。

### `openai-proxy.codex.hk`

```caddy
# Reverse proxy for OpenAI API with SSE streaming support
openai-proxy.codex.hk {
    # 访问日志：使用 filter 编码器，删除客户端 IP 相关字段
    log {
        output file {$CADDY_LOG_DIR:/var/log/caddy}/openai-proxy.log
        format filter {
            wrap json
            fields {
                request>remote_addr delete
                request>remote_ip delete
                request>headers>x-forwarded-for delete
                request>headers>cf-connecting-ip delete
                request>headers>x-real-ip delete
                request>headers>true-client-ip delete
            }
        }
        level INFO
    }

    # 反向代理到 OpenAI API
    reverse_proxy https://api.openai.com {
        # 确保 Host/SNI 正确
        header_up Host api.openai.com
        # 仅透传鉴权等必要头，不上送任何客户端 IP 相关头
        header_up Authorization {http.request.header.Authorization}
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto {scheme}
        # 隐私加固：明确删除可能暴露客户端 IP 的头
        header_up -X-Forwarded-For
        header_up -Forwarded
        header_up -X-Real-IP
        header_up -CF-Connecting-IP
        header_up -True-Client-IP

        # SSE：尽量不缓冲响应，实时刷出
        flush_interval -1

        transport http {
            versions h2 h1.1
            tls_server_name api.openai.com
        }
    }
}
```

### `chatgpt.codex.hk`

`chatgpt.codex.hk` 复用相同的隐私策略，将整站流量转发至 `https://chatgpt.com`。

```caddy
# Reverse proxy chatgpt.codex.hk to chatgpt.com
chatgpt.codex.hk {
    log {
        output file {$CADDY_LOG_DIR:/var/log/caddy}/chatgpt.log
        format filter {
            wrap json
            fields {
                request>remote_addr delete
                request>remote_ip delete
                request>headers>x-forwarded-for delete
                request>headers>cf-connecting-ip delete
                request>headers>x-real-ip delete
                request>headers>true-client-ip delete
            }
        }
        level INFO
    }

    reverse_proxy https://chatgpt.com {
        header_up Host chatgpt.com
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up -X-Forwarded-For
        header_up -Forwarded
        header_up -X-Real-IP
        header_up -CF-Connecting-IP
        header_up -True-Client-IP

        flush_interval -1

        transport http {
            versions h2 h1.1
            tls_server_name chatgpt.com
        }
    }
}
```

说明：
- `flush_interval -1` 关闭响应缓冲，有利于 SSE token 逐步输出；对 `openai-proxy.codex.hk` 和 `chatgpt.codex.hk` 均启用，确保聊天与后台接口都能以 SSE 流式返回。
- `transport http { versions h2 h1.1 }` 允许与上游（OpenAI）使用 HTTP/2，进一步优化流式体验。
- 出于隐私，删除了所有可能上送客户端 IP 的头，并在访问日志中过滤 IP 字段。
- `chatgpt.codex.hk` 采用完整反向代理，前端页面与 `/backend-api` 等接口均直接命中 `chatgpt.com`。

## 应用配置
- 语法校验：`caddy validate --config /etc/caddy/Caddyfile`
- 重载生效：`systemctl reload caddy`

若需要查看服务状态：
- `systemctl status --no-pager caddy`
- `journalctl -u caddy --no-pager -n 200`

隐私校验：
- 发起一次请求后，查看 `/var/log/caddy/openai-proxy.log`，应看不到 `request.remote_ip` 或 `x-forwarded-for` 等字段。
- 使用 `curl -v` 访问 `/v1/models` 并抓包/查看请求头，应无 `X-Forwarded-For`、`X-Real-IP`、`Forwarded`、`CF-Connecting-IP`、`True-Client-IP` 等头被上送。

## 证书与监听
- Caddy 自动为 `openai-proxy.codex.hk` 申请并管理 TLS 证书（Let’s Encrypt/ACME）。
- 自动开启 80/443 监听与 HTTP→HTTPS 跳转。

## 本地部署 / 验证
1. 进入仓库根目录，准备日志目录：

   ```bash
   export CADDY_LOG_DIR="$(pwd)/logs"
   mkdir -p "$CADDY_LOG_DIR"
   ```

2. 校验配置并在前台启动 Caddy：

   ```bash
   caddy validate --config config/Caddyfile
   caddy run --config config/Caddyfile --watch
   ```

3. 另开终端（可选）运行 Responses API 测试脚本（需自备 `OPENAI_API_KEY`）：

   ```bash
   bash scripts/test_responses.sh payload.responses.json
   ```

   若不需要实时测试，可跳过此步。

4. 若需要停止，直接 `Ctrl+C` 结束 Caddy 前台进程即可。

## 验证

### `openai-proxy.codex.hk`

- 最小验证（未带 Key，预期 401）：

  ```bash
  curl -I https://openai-proxy.codex.hk/v1/models
  ```

  看到 `HTTP/2 401`，并包含 OpenAI/Cloudflare 相关响应头，说明代理链路正确。

- SSE 测试（需自备 OpenAI API Key）：

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

### `chatgpt.codex.hk → chatgpt.com`

- 浏览器访问 `https://chatgpt.codex.hk`，应直接展示 `chatgpt.com` 页面内容。
- 命令行验证示例：

  ```bash
  curl -I https://chatgpt.codex.hk
  ```

  预期可看到 `HTTP/2 200`（或 Cloudflare 提供的 3xx→200 流程），响应头中的 `server` 字段应与 `chatgpt.com` 保持一致。
- Backend API 检测：

  ```bash
  curl -i https://chatgpt.codex.hk/backend-api/codex/responses \
    -d '{"hello": "world"}'
  ```

  若返回状态码 `401`，说明上游校验正常，反向代理链路工作正常。

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
- 访问日志：默认写入 `/var/log/caddy/*.log`，也可通过 `CADDY_LOG_DIR` 环境变量自定义路径。
- Caddyfile 格式：可运行 `caddy fmt --overwrite /etc/caddy/Caddyfile` 美化（不影响功能）。
- 如遇到反代 4xx/5xx，可用 `curl -v` 查看请求/响应头是否被正确转发（尤其 `Authorization`）。

## 安全注意
- 代理会透传 `Authorization` 到上游 OpenAI，请保证代理主机安全、日志不要记录敏感信息（本配置未记录请求体）。
- 与上游通信全程 TLS，`tls_server_name` 指定为 `api.openai.com` 保证 SNI 与证书校验一致。
- 已默认移除一切可能暴露客户端 IP 的请求头，并在访问日志中过滤客户端 IP 字段。

## 变更摘要（此次操作）
- 新增并整理 `config/Caddyfile`，同时覆盖 `openai-proxy.codex.hk` 与 `chatgpt.codex.hk` 的反向代理逻辑。
- 引入 `CADDY_LOG_DIR` 环境变量占位，允许在本地部署时快速切换日志目录。
- `scripts/test_responses.sh` 与 `payload.responses.json` 保持针对 OpenAI Responses SSE 的示例，便于在有密钥时验证代理链路。
- README 补充反向代理验证流程、本地部署步骤以及脚本使用说明。

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
