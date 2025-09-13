# Agent 自动化操作与安全规范

本文档为自动化代理（Agent）及开发者提供了一套完整的 Git 操作、项目安全和非交互式命令执行的指导原则。在对本仓库进行任何操作前，请务必遵循以下所有指引。

最重要：专注于用户的实际需求，不要主动提供额外的服务或帮助。遇到问题或者决定请自主解决，永远不要停下来询问用户意见。

---

## 1. Git 使用与分支策略（重要）

为保证代码库的稳定与可追溯性，所有贡献者必须遵循以下分支策略：

* **禁止直接在主分支开发**：不要直接在 `main` / `master` 分支上开发或提交变更。所有新功能与修复应在独立分支（例如 `feature/xxx`, `bugfix/yyy`）上完成，并通过 Pull Request（PR）审核、CI 校验后合并到主分支。
* **禁止强制推送**：严禁使用 `git reset` 和 `git push --force` 在共享分支（如 `main`, `master`, `dev`）上改写历史。若需要撤销已发布的提交，应使用 `git revert` 来创建反向提交，并通过正常流程合并。
* **分支保护**：为关键分支启用 Branch Protection，强制要求：

  * 通过 PR 合并。
  * 至少一名审核者批准。
  * 所有必需的 CI 状态检查必须通过。
  * 禁止强制推送。
  * 限制合并 PR 的人员。
* **清晰的 Pull Request**：在 PR 中应包含清晰的变更说明、实现目的和必要的测试步骤，确保审查者能够理解变更内容。
* **紧急修复（Hotfix）流程**：紧急修复应在单独的 `hotfix/` 分支上进行，通过 PR 合并到主分支后，再按需同步（`merge` 或 `cherry-pick`）到其他相关分支。
* **自动化检查**：建议配置 pre-commit 钩子或在 CI 中集成工具，以在提交和合并前运行凭据扫描、代码风格检查（Linters）和测试。

---

## 2. Agent Git 指导原则

自动化代理（Codex/Agent）在执行 Git 操作时必须遵循以下准则，以确保自动化、安全和可预测性。

### 强制前置检查（每次运行前）

```bash
if ! command -v gh >/dev/null 2>&1; then
  echo "error: github cli (gh) not installed" >&2
  exit 2
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "error: github cli (gh) not authenticated" >&2
  exit 3
fi
```

### 行为准则

* **绝不交互**：必须导出 `export GIT_TERMINAL_PROMPT=0`，避免触发交互式凭证提示。
* **失败处理**：若 `gh` 不可用或未认证，Agent 必须立即停止执行并报告，不得尝试交互登录。
* **提交与推送**：默认提交并推送到当前工作分支，不得随意新建或切换分支，除非用户明确要求。
* **凭证来源**：必须使用非交互式凭证方案（SSH key、gh credential helper 或 CI 环境变量）。

### 推荐的自动化脚本头部

```bash
#!/bin/bash
set -euo pipefail

# 禁止交互
export GIT_TERMINAL_PROMPT=0

# 前置检查
if ! command -v gh >/dev/null 2>&1; then
  echo "error: github cli (gh) not installed" >&2
  exit 2
fi
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "error: github cli (gh) not authenticated" >&2
  exit 3
fi

# 在此之后可以安全地执行 git fetch/push 等操作
```

---

## 3. 非交互式 Git 操作技术指引

### 核心原则

* **禁止终端交互**：始终导出 `GIT_TERMINAL_PROMPT=0`。
* **自动凭证**：使用 SSH key、credential helper 或 `GIT_ASKPASS` 脚本自动提供凭证。
* **避免明文凭证**：不要硬编码 token 或密码。

### 常用非交互化方案（推荐顺序）

1. **SSH Key（最稳妥）**

   * 使用 `BatchMode` 确保 SSH 不阻塞：

     ```bash
     GIT_SSH_COMMAND='ssh -o BatchMode=yes' git push origin HEAD
     ```

2. **GitHub CLI (gh) 作为 Credential Helper**

   * CI 登录：

     ```bash
     echo "$GITHUB_TOKEN" | gh auth login --with-token
     git config --local credential.helper "!gh auth git-credential"
     ```

3. **GIT\_ASKPASS 脚本**

   * 输出凭证的脚本：

     ```bash
     export GIT_ASKPASS=/path/to/script.sh
     ```

4. **HTTP extraHeader（CI 推荐）**

   * 单次命令注入：

     ```bash
     GIT_TERMINAL_PROMPT=0 git -c http.extraHeader="Authorization: Bearer $GITHUB_TOKEN" clone https://github.com/OWNER/REPO.git
     ```

### 容错与安全

* **容错**：在脚本中检查返回值，例如：

  ```bash
  if ! GIT_TERMINAL_PROMPT=0 git push origin main; then
    echo "error: non-interactive git authentication failed." >&2
    exit 1
  fi
  ```
* **凭证安全**：

  * 使用 CI Secrets 机制存储 token。
  * 凭证文件权限设为 600。
  * 使用最小权限原则。

---

## 4. 项目安全指引

### 重要原则

* 禁止硬编码凭证。
* 外部化配置，使用环境变量或 CI Secrets。
* 日志中禁止打印敏感信息。
* 示例配置应使用 `.env.example`，并将真实 `.env` 文件加入 `.gitignore`。
* 及时撤销临时测试密钥。

### CI / GitHub Actions 指南

* 使用 GitHub Actions Secrets 存储敏感凭据。
* 禁止在 workflow 文件中明文写入。
* 避免在日志中输出 Secret。
* 使用 `::add-mask::` 屏蔽敏感输出。

### 代码审查与流程

* 审查代码中是否存在硬编码密钥或调试残留。
* 在合并前运行自动化扫描工具（如 gitleaks, truffleHog, detect-secrets）。

### 泄露响应

1. 撤销/轮换相关凭证。
2. 从 Git 历史中移除密钥。
3. 评估影响并通知相关方。

### 快速检查清单（PR 审核时使用）

* 代码中是否包含 API keys、私钥或密码？
* 是否提交了真实凭据的 `.env` 文件？
* CI workflow 是否泄露了 Secret？

---

## 5. 系统/发行版检测与非交互式系统命令

### 检查发行版

```bash
if [ -f /etc/os-release ]; then
  . /etc/os-release
  echo "detected os: $ID, version: $VERSION_ID"
fi
```

### 非交互式执行

* **Debian/Ubuntu**:

  ```bash
  DEBIAN_FRONTEND=noninteractive apt-get install -y <pkg>
  ```
* **RHEL/CentOS/Fedora**:

  ```bash
  dnf install -y <pkg>
  ```
* **Arch Linux**:

  ```bash
  pacman -S --noconfirm <pkg>
  ```

### 下载命令策略

```bash
curl --fail --silent --show-error --connect-timeout 10 --max-time 60 -o /tmp/file.zip "https://example.com/file.zip"
```

### 总体超时

在执行可能长时间运行的脚本时，应在调用层设置超时，避免无限挂起。这里的调用层指的是shell工具的调用是带超时参数的，不是指在bash里面使用timeout命令，当然必要时也可以配合使用timeout命令。

---

## 6. 通用非交互式命令执行指引

为了确保任何情况下、任何命令的执行都严格符合非交互式原则，必须遵循以下通用规范：

### 核心原则

1. **禁止人工交互**：命令不得要求用户输入，一旦遇到交互提示必须立即失败并退出。
2. **显式非交互模式**：在所有支持的命令中使用 `-y`、`--assume-yes`、`--noconfirm` 等参数，确保自动化执行。
3. **统一错误处理**：所有命令必须返回非零退出码以表示失败，并将错误输出到标准错误流。
4. **超时控制**：所有可能阻塞的命令必须使用 `timeout` 机制限制执行时间，例如 `timeout 60s command`。
5. **自动输入替代**：若命令确实需要输入，必须通过环境变量、配置文件或受控管道 (`yes | command`) 实现，禁止人工干预。
6. **幂等性**：脚本应具备可重复执行性，不依赖上一次交互状态。
7. **日志与安全**：执行日志需详细记录命令结果，但必须屏蔽敏感凭据。

### 后台命令执行指引

* **禁止使用 `nohup xxx &`**：任何情况下不得通过 `nohup` 与后台符号 `&` 运行进程，这种方式不可控且不安全。
* **必须使用 `systemd-run`**：所有后台执行的命令必须通过 `systemd-run` 方式启动，例如：

  ```bash
  systemd-run --unit=example-service \
      --working-directory=/opt/example \
      --setenv=PATH=/usr/local/bin:/usr/bin:/bin \
      /usr/bin/example-command --flag
  ```
* **限制参数**：除非必要，禁止在 `systemd-run` 中使用 `--scope` 或 `--user` 参数。
* **使用场景**：`systemd-run` 在非必要情况下不得出现在脚本中，仅限 Agent 的 Shell 工具在临时操作时使用。
* **日志与追踪**：后台命令必须由 systemd 管理，确保有日志、状态与清理机制，禁止孤儿进程存在。

### 通用实现方法

* **系统命令执行**：统一在命令后添加错误捕捉：

  ```bash
  command || { echo "error: command failed" >&2; exit 1; }
  ```

* **服务操作**：对 `systemctl` 等命令必须检查状态并返回明确结果：

  ```bash
  systemctl restart <service> || { echo "error: failed to restart <service>" >&2; exit 1; }
  ```

* **脚本设计要求**：所有脚本需在开头增加：

  ```bash
  #!/bin/bash
  set -euo pipefail
  ```

  确保遇到错误时立即退出。

* **下载与网络操作**：`curl`、`wget` 等必须包含超时、失败重试和错误返回：

  ```bash
  curl --fail --silent --show-error --connect-timeout 10 --max-time 60 -O <url>
  ```

通过这些指引，确保所有命令在任意场景下均可安全、可预测地以非交互方式执行。
