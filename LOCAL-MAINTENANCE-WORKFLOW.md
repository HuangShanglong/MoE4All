# MoE4All 本地维护与贡献 Workflow

> **本地文档。** 主工作树里的这份已写入 `.git/info/exclude`（`git status` 看不到、
> 不会被误提交、**也永不进任何 PR**）；同一内容另有一份同步在 fork 的
> `local/workflow` 分支上用于版本化。
>
> 路径：`$REPO/LOCAL-MAINTENANCE-WORKFLOW.md`
> 维护者：HuangShanglong ｜ 更新：2026-10-04

> **本文件为脱敏版**：不含本机具体标识，统一用占位符表示 —— `$REPO` = 本地克隆
> 路径，`$ROOT` = 其父目录，`<HOSTNAME>` = 主机名，`<USER>` = 用户名，
> `<LOCAL_DIR>` / `<MODEL_DIR>` = 本机目录名。

首次使用先导出克隆路径，下文命令即可直接复制：

```bash
export REPO=<你的克隆路径>
```

这个文档记录"向 `Headmaster218/MoE4All` 提交与维护 issue/PR"的完整流程，包括巡检、
新建、本地排查。每一步的命令都是在本机跑通过的。

---

## 0. 一次性环境事实

| 项 | 值 |
|---|---|
| 本地仓库 | `$REPO` |
| `origin` | `https://github.com/Headmaster218/MoE4All.git`（**上游，只读**） |
| `fork` | `git@github.com:HuangShanglong/MoE4All.git`（**自己的，可写**） |
| 提交身份 | `huangsl <haorenhl@126.com>`（该邮箱已绑定 GitHub 账号） |
| GitHub 账号 | `HuangShanglong`（数字 ID `28332672`） |
| `gh` CLI | `~/.local/bin/gh`（非 apt 安装，v2.102.0，已登录 `HuangShanglong`） |

### ⚠️ 本机禁用 IPv6 —— 所有网络操作必须强制 IPv4

IPv6 连接会**认证成功但挂起**（`ssh -T git@github.com` 走 `fc00::26` 时 `exit=124`）。
因此：

```bash
GIT_SSH_COMMAND='ssh -4' git push …        # 所有 git over SSH
curl -4 …                                  # 所有 curl
```

> `gh` 自身的 HTTP 目前可用；若将来它开始挂起，优先怀疑 IPv6。

### ⚠️ 两块硬前置检查（否则会出现"假失败"）

```bash
# 1) 磁盘：构建/测试前必须有余量。曾因 / 100% 满导致 rustc 报 exit 101，
#    看起来像代码错误，实际是 "No space left on device"。
df -h / | tail -1

# 2) GPU：跑 GPU 测试或 infr 前必须空闲（llama-server 会独占 ~22 GiB）。
cat /sys/class/drm/card0/device/mem_info_vram_used   # 期望 < 1 GiB
pgrep -af llama-server
```

**GPU 是可以停的**：本机允许完全停止 llamacpp 进程用于测试，**测完不需要重启它**。

---

## 1. 巡检：检查已提 PR / issue 状态

### 1.1 我提了哪些、状态如何

```bash
cd $REPO

# 我的 PR（状态 / 可合并 / 文件数 / head）
gh pr list --repo Headmaster218/MoE4All --author HuangShanglong \
  --json number,title,state,mergeable,changedFiles,headRefOid \
  --template '{{range .}}#{{.number}} {{.state}} mergeable={{.mergeable}} files={{.changedFiles}} {{.title}}{{"\n"}}{{end}}'

# 我的 issue
gh issue list --repo Headmaster218/MoE4All --author HuangShanglong \
  --json number,title,state,comments

# 仓库全部开放 PR（看是否有别人会改动 main、或与我的工作重叠）
gh pr list --repo Headmaster218/MoE4All --state open \
  --json number,title,author
```

### 1.2 有没有新回复（**最关键的一步**）

> 教训：曾以为"只剩等维护者"，实际 #60/#61 已有新回复却没看到。

```bash
# 每个 PR 的评论数与最新一条（先扫一遍，有没有新东西）
for n in 58 59 60 61; do
  printf "#%s  评论=%s  " "$n" \
    "$(gh api repos/Headmaster218/MoE4All/issues/$n/comments --jq 'length')"
  gh api repos/Headmaster218/MoE4All/issues/$n/comments \
    --jq '.[-1] | "\(.user.login) @ \(.created_at)"'
done

# 读全文（含中英双语原文）
gh api repos/Headmaster218/MoE4All/issues/60/comments \
  --jq '.[] | "===== \(.user.login) @ \(.created_at) =====\n\(.body)\n"'

# 行内 review 评论（挂在具体代码行上的，容易漏）
gh api repos/Headmaster218/MoE4All/pulls/58/comments \
  --jq '.[] | "\(.path):\(.line)  \(.body)"'

# review 状态（approved / changes requested）
gh pr view 58 --repo Headmaster218/MoE4All \
  --json reviewDecision,mergeStateStatus
```

### 1.3 上游 main 是否移动（决定要不要 rebase）

```bash
git fetch origin -q
git rev-parse --short origin/main
git log -1 --format='%h %s' origin/main
# 我的分支落后多少
git rev-list --left-right --count origin/main...docs/linux-build-guide
```

### 1.4 CI 是否在跑

```bash
gh pr checks 58 --repo Headmaster218/MoE4All
```

> 首次贡献者会显示 `no checks reported` —— GitHub 需要**维护者点 Approve and run**
> 才执行 workflow。这不是配置错误，也不要在描述里当作失败。

---

## 2. 新增 issue

### 2.1 原则（来自维护者反馈）

> "The unrelated … failures should remain outside this PR and be **reported separately**."

- **只写现象 + 原始 log，不写推测**。不要写"这说明是 XX 的 bug"、"应该是 XX 导致的"。
- 失败信息里**测试自身打印的**文字（如 `the backward de-rope is missing…`）属于原始
  log，可以保留；**自己加的判断**一律删掉。
- 标注清楚：与哪个 PR 无关、CI 是否覆盖（`#[ignore]` / 不带 `--include-ignored`）。

### 2.2 先本地复现（并让子 Agent 独立复核）

```bash
# 在干净的 origin/main worktree 上复现，不要用自己分支的树
git worktree add --detach /tmp/repro origin/main
cd /tmp/repro && cargo test -p infr-llama --release --test <test> -- --include-ignored --nocapture
cd - && git worktree remove --force /tmp/repro && git worktree prune
```

> 复现这类命令**委托子 Agent**跑一遍更好：独立复核 + 不污染主分支工作区。

### 2.3 提交

```bash
gh issue create --repo Headmaster218/MoE4All \
  --title "<组件>: <一句话现象>" \
  --body-file /tmp/issue.md
```

issue 正文骨架：`Summary`（现象 + 是否被 CI 覆盖 + 声明独立于任何 PR）
→ `Environment`（GPU / 驱动 / OS / kernel / 构建 commit）
→ `Repro`（**一条命令**）→ `Observed output`（逐字原始输出）
→ `Notes`（纯事实，如"测试是 synthetic，无需下载模型"）。

---

## 3. 新增 PR

### 3.1 分支基线：永远从最新 main 开

```bash
git fetch origin
git checkout -b <type>/<short-name> origin/main
```

### 3.2 提交信息：Conventional Commits + scope

仓库风格：`feat(llama): …` / `fix(hostmem): …` / `docs(guide): …` / `perf(linux): …`。
仓库**没有** CONTRIBUTING / PR 模板 / 分支保护，但 CI 会跑
`fmt`（`cargo fmt --all -- --check`）、`clippy -D warnings`、`nextest`、`doc`、`build --release`。

### 3.3 cherry-pick 后必须重置作者

```bash
git cherry-pick <sha>…
git rebase --exec 'git commit --amend --no-edit --reset-author' origin/main
```

> cherry-pick 会保留**原作者**，不改的话提交显示为 `<原作者占位身份>`（占位身份，
> GitHub 无法关联）。

### 3.4 提交前的本地验证（**硬规则**）

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked                    # 期望 exit=0
cargo test --doc --workspace --locked
cargo build --release --workspace --locked
```

- 新增/修改 **任何脚本或命令，都必须先在本机实测**（含真实运行，而不只是语法检查）。
- **测试失败先看是不是环境问题**：磁盘满 / 显存被占 / 服务在跑，都曾造成"假失败"。

### 3.5 泄露审计（**推之前必跑**）

```bash
# 作者/提交者里不能有占位身份
git log --format='%an <%ae> %cn <%ce>' origin/main..HEAD | grep -i <HOSTNAME>

# 提交信息里不能有本机信息 / 内部文档引用
git log --format='%B' origin/main..HEAD | \
  grep -inE '<HOSTNAME>|/home/<USER>|<LOCAL_DIR>|<MODEL_DIR>|addendum|findings'

# diff 里不能有本机绝对路径 / 密钥
git diff origin/main..HEAD | grep -E '^\+' | \
  grep -inE '/home/<USER>|/tmp/|<LOCAL_DIR>|<MODEL_DIR>|192\.168\.|ssh-rsa|BEGIN .*PRIVATE|api_key *='
```

> 踩过的坑：提交信息里留了 `see Addendum 5`、`MoE4All-linux-perf-findings.md`
> 这类**仓库外文件名**；虽然不含路径，但属于本机内部产物，必须改成自包含表述。

### 3.6 先推 fork 的预览分支，自审通过再动 PR

```bash
# 预览分支（不触发 PR 更新）
GIT_SSH_COMMAND='ssh -4' git push -u fork <preview-branch>

# 对比视图（把 <base-sha> 换成当时的 origin/main，fork 上没有旧 main 时用 SHA 比对）
#   https://github.com/HuangShanglong/MoE4All/compare/<base-sha>...<preview-branch>
```

确认无误后，才把它推到 **PR 的目标分支**（推到 PR 分支 = PR 自动更新）：

```bash
git checkout -B <pr-branch> <preview-branch>
GIT_SSH_COMMAND='ssh -4' git push --force-with-lease fork <pr-branch>
```

### 3.7 开 PR

```bash
gh pr create --repo Headmaster218/MoE4All \
  --base main \
  --head HuangShanglong:<branch> \
  --title "<conventional title>" \
  --body-file /tmp/pr-body.md
```

**正文用中英双语**（维护者双语回复，本项目惯例如此）。骨架：
`Why`（问题）→ `What`（改动，逐文件）→ `Verification`（**实测证据**，非声称）
→ `Scope / Out of scope` → `CI`（若 `no checks reported` 说明是首次贡献者待批准）。

### 3.8 堆叠 PR 的限制（GitHub 机制）

**PR 的 base 必须是"目标仓库"里存在的分支**。所以：

- 若 B 分支基于 A 分支，而 A 只存在你自己的 fork → **无法**把 base 指向 A；
- 只能对 `main` 开 PR，并在正文顶部显著标注：
  `> **Stacked on #A** — this branch is based on … this PR currently shows that
  PR's commits too. Review/merge #A first.`
- 或者等 A 合并后，把 B rebase 到 main 再开。

### 3.9 PR 元信息必须与内容一致（**踩过的坑**）

内容改了（从"纯文档"变成"文档 + 脚本 + 测试"）之后，**标题和正文要同步更新**，
否则正文里会残留 "Docs only — no code, no behavior change" 这类**与事实矛盾**的陈述。

```bash
gh pr edit <n> --repo Headmaster218/MoE4All \
  --title "…" --body-file /tmp/pr-body.md
```

> 注意：`gh pr edit` 作用于**上游仓库里的那个 PR**（PR 本身存在于上游）；而
> `git push` 只能推到你的 fork。两者不是一回事。

---

## 4. 根据 PR / issue 回复在本地排查

标准循环：

1. **取全文**（见 §1.2，别漏行内 review 评论）；
2. **判断性质**：
   - 只是**放置/措辞**类 → 改文档即可；
   - **行为/设计**类（如"这个改动范围太大"）→ 先做架构分析再回复，**不要急着改代码**；
3. **本地复现 / 定位**：用 §2.2 的干净 worktree，或在当前分支上复现；
4. **改 → 测 → 推预览 → 自审 → 更新 PR 分支**（§3.4–3.6）；
5. **若涉及设计分歧**：先给回复草案（含证据与取舍），**等确认再动代码**；
6. 处理完**回头核对 PR 元信息**（§3.9）。

> 维护者的风格：认同根因分析，但**偏好收窄改动范围**、保留可回退的显式开关、
> 反对"过宽"的默认值变更；文档一律进 `documentation/` 树（`docs/` 已废弃）。

### 4.1 上游文档结构（2026-10 起）

`docs/` 已被移除，改为 `documentation/`：

```
documentation/guide/        用户指南   (README.md 是索引)
documentation/development/  开发手册   (README.md 是索引)
documentation/reference/    参考（configuration / model-capabilities / …）
documentation/architecture/ 架构（memory/runtime-resource-lifecycle.md 等）
```

新文档需带 YAML frontmatter：

```yaml
---
kind: guide | development-guide | architecture | index
status: current | mixed
scope: <topic-slug>
last_verified: YYYY-MM-DD
verified_commit: <sha>
---
```

---

## 5. 硬规则清单（每条都踩过）

| # | 规则 | 原因 |
|---|---|---|
| 1 | 网络操作一律 `ssh -4` / `curl -4` | 本机 IPv6 会挂起 |
| 2 | 动 GPU 前停 llama-server；**测完不自动重启** | GPU 互斥；用户授权可停 |
| 3 | 构建/测试前查磁盘余量 | 磁盘满会伪装成编译错误 |
| 4 | 任何脚本/命令先本机实测 | 用户明确要求 |
| 5 | cherry-pick 后 `--reset-author` | 否则作者是占位身份 |
| 6 | 推之前跑泄露审计 | 不得泄露本机信息 |
| 7 | 先推 `preview/` 分支自审，再动 PR 分支 | 推 PR 分支会自动更新 PR |
| 8 | PR 元信息与内容同步 | 否则正文自相矛盾 |
| 9 | 改内容后重跑 CI 门禁 | fmt/clippy/test 都会拦 |
| 10 | 设计分歧先回复、后改码 | 避免白做 |

---

## 6. 命令速查

```bash
# —— 巡检 ——
gh pr list --repo Headmaster218/MoE4All --author HuangShanglong \
  --json number,state,mergeable,changedFiles,headRefOid
gh api repos/Headmaster218/MoE4All/issues/<n>/comments \
  --jq '.[] | "\(.user.login) @ \(.created_at): \(.body[0:200])"'
gh api repos/Headmaster218/MoE4All/pulls/<n>/comments --jq '.[] | "\(.path):\(.line) \(.body)"'
git fetch origin -q && git rev-parse --short origin/main
gh pr checks <n> --repo Headmaster218/MoE4All

# —— 建分支 / 提交 ——
git checkout -b <type>/<name> origin/main
git cherry-pick <sha>… && git rebase --exec 'git commit --amend --no-edit --reset-author' origin/main

# —— 门禁 ——
cargo fmt --all -- --check && \
cargo clippy --workspace --all-targets --locked -- -D warnings && \
cargo test --workspace --locked && \
cargo test --doc --workspace --locked && \
cargo build --release --workspace --locked

# —— 推送（强制 IPv4）——
GIT_SSH_COMMAND='ssh -4' git push -u fork <preview-branch>
GIT_SSH_COMMAND='ssh -4' git push --force-with-lease fork <pr-branch>

# —— 新建 / 更新 ——
gh pr create --repo Headmaster218/MoE4All --base main \
  --head HuangShanglong:<branch> --title "…" --body-file /tmp/pr-body.md
gh pr edit <n> --repo Headmaster218/MoE4All --title "…" --body-file /tmp/pr-body.md
gh issue create --repo Headmaster218/MoE4All --title "…" --body-file /tmp/issue.md

# —— 同步 fork 的 main ——
GIT_SSH_COMMAND='ssh -4' git push fork origin/main:main
```

---

## 7. 当前状态快照（2026-10-04）

> 每次处理完更新这一段。分支 tip 会变，以 `gh pr view` / `git ls-remote` 为准。

**我的分支（fork `HuangShanglong/MoE4All`）**

| 分支 | tip | 对应 PR |
|---|---|---|
| `main` | `41345e6f`（与 upstream 同步） | — |
| `local/workflow` | orphan，仅含本文件（tip 用 `git ls-remote fork local/workflow` 查） | —（**永不作 PR head**） |
| `docs/linux-build-guide` | `d1b7ac01` | #58 |
| `preview/linux-build-guide` | `d1b7ac01` | （预览，与 PR 分支同一提交） |
| `fix/hostmem-arena-guard` | `30e133ff` | #59 |
| `linux/engine-owned-host-arena` | `0754fefa` | #60 |
| `feat/linux-warm-page-cache` | `1f059716` | #61（堆叠在 #60 上） |

**PR / issue**

| # | 标题 | 状态 | 待办 |
|---|---|---|---|
| 58 | `feat(linux): add the Linux build guide, launcher and smoke test` | OPEN / MERGEABLE（9 文件） | 标题与正文**已更新**，与内容一致；等维护者审阅 + **批准 CI 运行**（首次贡献者 `no checks reported`） |
| 59 | `fix(hostmem): cap a host arena against physical RAM, not a 3 GiB tail` | OPEN / MERGEABLE | 等审阅（最易过） |
| 60 | `perf(linux): stop aliasing the host tier through VK_EXT_external_memory_host` | OPEN / MERGEABLE | **待回复**：要求收窄——拆分导入与传输队列、仅 Linux AMD 默认关闭、保留 RAM 层/fallback/传输队列、保留显式开启；反对 `dram_bypass` 做默认、反对按内核版本门控 |
| 61 | `feat(paging): INFR_WARM_PAGE_CACHE …` | OPEN / MERGEABLE | **待回复**：质疑必要性（倾向定位为基准/诊断选项，建议改为“自动 RAM 预算启用后端 Host tier”） |
| 64 | `deepseek4: two #[ignore]d Vulkan GPU tests fail on RDNA3` | OPEN | 已由子 Agent 在干净 origin/main worktree 独立复现（cosine 0.99985 / de-rope），**与 PR 无关**；等维护者分流 |

**记忆与工作区**

- 记忆分片当前挂在 `$ROOT`（本会话 cwd）；切到 `$REPO` 后需在**新会话**执行 `migrate`——见 §9。
- 已备份：`$ROOT/memory-backup-20261004.json`（347 条，**仓库外**）。

**下一步（暂停中）**

1. **切工作区**：在 `$REPO` 启动新会话 → 按 §9 迁移记忆（先 `dryRun`）；
2. **#60/#61 的设计回应**：先做架构分析（可委托 Oracle 读仓库代码）再回复，**不要直接改代码**；
3. #59 最简单，若维护者先看它会更快；
4. 每次开工前先跑 §1.2（有无新回复）与 §1.3（main 是否移动）。

---

## 8. 把本文件同步到 fork 的 `local/workflow` 分支

本文件**永不进 PR**（它不在任何 PR 分支上）。要版本化 / 多机同步时，把主工作树里
这份（脱敏版）推到 fork 的 orphan 分支 `local/workflow`（该分支已建好，仅含这
一个文件，无上游历史）：

```bash
cd "$REPO"

# 1) 推送前先做泄露检查（§3.5）
grep -nE '<HOSTNAME>|<USER>|<LOCAL_DIR>|<MODEL_DIR>' LOCAL-MAINTENANCE-WORKFLOW.md \
  && echo '有占位符未替换，先脱敏' && exit 1

# 2) 在专用 worktree 里更新那个分支并推送
wt=$(mktemp -d)
git worktree add -q "$wt" local/workflow        # 分支不存在时见下方“首次创建”
cp LOCAL-MAINTENANCE-WORKFLOW.md "$wt/"
( cd "$wt" \
  && git add -f LOCAL-MAINTENANCE-WORKFLOW.md \
  && git commit -q -m "docs(local): refresh maintenance workflow" \
  && GIT_SSH_COMMAND='ssh -4' git push fork local/workflow )
git worktree remove --force "$wt"; git worktree prune
```

首次创建（仅一次，已执行过，留作参考）：

```bash
wt=$(mktemp -d)
git worktree add -q --detach "$wt" origin/main
( cd "$wt" && git checkout -q --orphan local/workflow && git rm -rfq . \
  && git commit -q --allow-empty -m "docs(local): init local notes" )
git worktree remove --force "$wt"; git worktree prune
```

换机器 / 重装后拉回：

```bash
git fetch fork local/workflow
git show fork/local/workflow:LOCAL-MAINTENANCE-WORKFLOW.md > "$REPO/LOCAL-MAINTENANCE-WORKFLOW.md"
```

> ⚠️ fork 是**公开**仓库。推送前务必重跑 §3.5 的泄露检查——本文件已用 `$REPO` /
> `<HOSTNAME>` / `<USER>` / `<LOCAL_DIR>` 等占位符脱敏，新增内容也不要写实。

---

## 9. 记忆与工作区（memory 分片）

记忆插件按**工作目录**分片存放，数据在 `$HOME/.opencode-mem/data/projects/`。

- 每个工作目录一个 shard，用 `memory list-shards` 查看当前分片（tag / 路径 / 条数）。
- **`migrate` 的目标路径 = 执行时所在会话的工作目录**（工具**没有 `to` 参数**）。
  所以换目录后，必须在**新目录**里启动会话再迁移：

```bash
cd "$REPO"                                    # ← 以新目录为 cwd 启动会话
memory migrate fromPath=$ROOT dryRun=true      # 干跑：确认 newPath 已变为 $REPO
memory migrate fromPath=$ROOT                  # 确认无误后执行
```

- 前置：**目标分片必须为空**（`$REPO` 此前没有分片即可）；
  迁移是**整体搬移**，不能逐条挑；迁移后**旧目录会话不再持有这些记忆**。
- 备份 / 恢复（备份文件放仓库外，避免污染 git）：

```bash
# 备份（在旧目录会话执行）
memory export outputPath=$ROOT/memory-backup-<date>.json

# 恢复（在需要的目录会话执行；会重新 embedding，遇到重复 id 会中止）
memory import inputPath=$ROOT/memory-backup-<date>.json dryRun=true
memory import inputPath=$ROOT/memory-backup-<date>.json
```

- 新会话恢复 MoE4All 上下文的检索词：
  `moe4all` / `pr-60` / `host-tier` / `dflash2` / `kv-cache` / `environment`。
- 不要在本文件里记录分片 tag——它是路径的哈希，写出来等于间接暴露路径。
