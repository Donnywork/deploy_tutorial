# 中级教程：推送即部署，失败自动回滚

> **你会学到**：执行 `git push` 之后，GitHub Actions 会自动通知服务器依次完成“拉取 → 构建 → 预检 → 备份 → 迁移 → 原子切换 → 健康检查”，任何一步失败都会自动切回旧版本；即便部署凭证不慎泄露，攻击者最多也只能触发一次合法版本的部署，读不走你的任何密钥。
>
> **前置自查清单**（全部能答“是”再继续）：
> - [ ] 我知道 `journalctl -u xxx -n 50` 是干什么的，并且亲手用过
> - [ ] 我的服务器上已经配好：Nginx + HTTPS、systemd 管理的应用、Docker 跑的 Postgres，且 ufw 只开放了 22/80/443 端口
> - [ ] 我亲手做过至少一次数据库恢复演练（不是“知道怎么做”，而是真刀真枪恢复过）
> - [ ] 我能说出初级册结尾“朴素部署八宗罪”里的任意三条
>
> 如果有任意一条不确定，对应内容都在[初级教程](01-beginner.md)里，建议先回去补齐那一章。
>
> **本册核心原则**：回滚安全、健康检查必须断言真实版本、拒绝混合状态、最小权限、回滚是一等公民、全程可审计。

**本册产出**：一套完整、可迁移的生产级部署系统。所有脚本都在仓库的 `demo-app/deploy/` 目录下，安装到服务器后位于 `/opt/demo-app/bin/`。将来迁移到你自己的项目时，通常只需要修改一个 `app.conf` 配置文件。

---

## 第 1 章 从 v0 到 v1：我们要修什么

在初级册结尾，我们审判了 v0 朴素部署脚本的“八宗罪”。这一册的章节目录，就是针对那八条罪状逐一落地的整改方案：

| # | v0 的罪状 | v1 的解法 | 对应工程原则 |
|---|---|---|---|
| 1 | 停机窗口不可控 | 采用 `releases/<sha>/` 目录 + `current` 软链，版本切换变成内核级原子操作；只剩进程重启的短暂窗口（高级册将用蓝绿切换彻底消灭它） | 控制爆炸半径 |
| 2 | 在生产机上装依赖、跑构建 | 暂时保留（作为参考设计的基线），但构建失败绝不残留半成品；高级册会通过“在哪儿构建”对比实验来帮你做取舍 | 一次构建处处部署、简单优先 |
| 3 | 部署中断留下半成品状态 | 先在 `.partial` 暂存目录中完成构建，全部成功后才用 `mv` 提升为正式 release | — |
| 4 | 没有真正的健康检查 | 断言 `/version` 返回目标 SHA + 数据库真实读写探测 + worker 心跳新鲜度检查 + 30 秒观察期（soak 窗口） | 健康检查必须断言真实版本、拒绝混合状态 |
| 5 | 回滚全靠手速与记忆 | 提供独立的 `rollback.sh`：不依赖外网、不动数据库、耗时可预期的一等命令 | 回滚是一等公民 |
| 6 | 部署脚本拥有完整 sudo 权限 | 拆分独立的 `deploy` 用户 + SSH 强制命令 + sudoers 最小白名单（仅允许重启固定单元、备份、迁移、健康检查与记审计日志） | 最小权限 |
| 7 | 部署操作无迹可寻 | 同时写入 `audit.log` 与系统 `logger`（syslog），每次部署或回滚都留下一行结构化记录 | 可审计 |
| 8 | 数据库迁移与代码版本错配 | 迁移失败则绝不切换代码；严格执行“备份 → 迁移 → 切换”顺序；破坏性变更采用 expand/contract 模式（高级册详解） | 回滚安全 |

**v1 部署流水线全景图**（请先建立这张全局心智图，后续每一节都是在拆解其中的一块拼图）：

```
开发者                GitHub                      服务器
  │  git push          │                            │
  │───────────────────▶│ CI: install/test/build     │
  │                    │ (通过后才允许部署)          │
  │                    │                            │
  │                    │ ssh deploy@server          │
  │                    │   "deploy <40位SHA>"       │
  │                    │───────────────────────────▶│ deploy-entry(强制命令,只认这个格式)
  │                    │                            │   │ setsid 脱离 SSH(断线也继续)
  │                    │                            │   ▼
  │                    │                            │ deploy.sh(以 deploy 用户运行):
  │                    │   CI 跟随部署日志            │  冻结检查 ─▶ flock ─▶ 幂等检查
  │                    │◀═══════════════════════════│  ─▶ fetch+祖先校验 ─▶ 预检(磁盘/Node/lockfile)
  │                    │                            │  ─▶ 构建 .partial ─▶ 提升 release
  │                    │                            │  ─▶ 配置预检 ─▶ 备份 ─▶ 迁移
  │                    │                            │  ─▶ 原子切换 current ─▶ 重启
  │                    │                            │  ─▶ 健康检查+soak ──失败──▶ 自动回切
  │                    │                            │  ─▶ 保留策略 ─▶ 审计
```

---

## 第 2 章 服务器布局与三个用户

### 2.1 三个身份，各自能干什么

| 用户 | 角色定位 | 允许的操作 | 严禁的操作 |
|---|---|---|---|
| `root`（你，经 `sam` 的 sudo 提权） | 系统管理员 | 拥有最高权限；管理部署脚本、sudoers 配置以及 `deploy` 用户的 `authorized_keys` | ——（正因权力无限，仅在执行系统管理动作时使用） |
| `deploy` | CI 的线上化身 | 登录方式**仅限** SSH 强制命令；负责构建 release；经 sudo 白名单执行 5 类受控动作 | 读取 `runtime.env`、修改部署脚本、打开交互式 shell、随意传输文件 |
| `app` | 业务服务本身 | 运行 web 与 worker 进程、读取 `runtime.env`、读写 `storage/`、连接数据库 | 通过 SSH 登录、修改应用代码、触碰部署脚本 |

> **为什么要拆成三个用户（最小权限原则）**：不妨设想最坏情况——CI 的 SSH 私钥不幸泄露。即便攻击者拿到了这把私钥，他能做的也仅仅是“触发一次 `main` 分支上某个合法提交的部署”以及“调用白名单里的几个固定命令”。他读不到数据库密码，也改不了服务器上的部署脚本；就算想部署恶意代码，传入的 SHA 也必须先通过 `main` 分支的祖先校验，而 `main` 分支本身受分支保护规则限制。这样一来，凭证泄露的爆炸半径就被压到了极致。到了高级册第 5 章，我们还会进一步量化对比“长期静态密钥”与“短期证书”的安全性差异。

### 2.2 目录布局

```
/opt/demo-app/              # "机器"的部分:root 拥有,deploy/app 都不可写
├── bin/                     #   部署脚本(deploy.sh、rollback.sh、backup.sh ...)
├── env/runtime.env          #   root:app 0640 —— 只有 app 读得到
├── compose/                 #   docker-compose.yml + .env(Postgres)
└── freeze                   #   存在即拒绝部署(紧急开关)

/srv/demo-app/               # "应用"的部分
├── repo.git/                #   bare 镜像缓存,deploy 用户持有(只读 deploy key)
├── releases/<40位SHA>/      #   每次部署一个完整目录,不可变
├── current → releases/<SHA> #   原子切换的开关(systemd 顺着它找当前版本)
└── storage/                 #   文件存储,app 用户写

/var/log/demo-app/           # 部署日志(保留 20 份)+ audit.log
/var/backups/demo-app/       # db/ + storage/ 备份
/run/demo-app/               # 部署锁(tmpfs,重启即清,由 tmpfiles.d 重建)
```

> **为什么要用 `releases/<sha>` 而不是在原目录直接 `git pull`**：每次部署生成一个完整且独立的版本目录，会同时带来三大好处——天然支持秒级回滚（只需切回软链）、天然具备可审计性（目录名就是线上正在运行的 Git SHA），以及构建产物不可变（永远不会出现“代码拉了一半、依赖装了一半”的脏工作区）。这也是经典部署工具 Capistrano 十几年来未曾改变的核心设计，非常值得借鉴。

### 2.3 从 v0 布局迁移到 v1

**【服务器】** 先把 v0 留下的代码目录、systemd 单元和 Compose 进程清理干净（**数据库里的数据不会丢**，它们安全地存放在 Docker 数据卷里）：

```bash
sudo systemctl disable --now demo-app
sudo rm /etc/systemd/system/demo-app.service
sudo cp /srv/demo-app/.env /tmp/demo-compose.env        # 保住数据库密码
cd /srv/demo-app && sudo docker compose down      # 卷保留(demo-app_pgdata);app 不在 docker 组,直接 sudo
cd /srv && sudo mv demo-app demo-app-v0-backup
```

接着把仓库最新代码拉到服务器上（部署脚本需要从仓库里安装），并运行引导脚本 `install.sh`：

```bash
cd ~ && git clone git@github.com:你的用户名/demo-app.git demo-app-bootstrap
cd demo-app-bootstrap/deploy
sudo ./install.sh git@github.com:你的用户名/demo-app.git
```

`install.sh`（位于仓库 `deploy/install.sh`，约 100 行，非常建议通读一遍）会一口气完成 9 件事：创建 `app` 和 `deploy` 用户并锁定密码 → 建立上一节展示的目录结构 → 将部署脚本安装到 `/opt/demo-app/bin`（归 `root` 所有）→ 安装 sudoers 规则并用 `visudo -cf` 校验语法 → 安装 systemd 单元（仅 `enable` 暂不 `start`）→ 就位 Compose 配置与 `runtime.env` → 克隆 `repo.git` 裸仓库缓存 → 配置每日自动备份 cron → 打印后续操作指引。

现在把刚才备份出来的 v0 数据库密码接回新目录，并确认初级册写入的数据完好无损：

```bash
sudo cp /tmp/demo-compose.env /opt/demo-app/compose/.env && rm /tmp/demo-compose.env
sudo rm -f /opt/demo-app/env/runtime.env    # 让下一步重新生成(用上面的密码)
sudo ./install.sh git@github.com:你的用户名/demo-app.git   # 幂等,重跑即可
docker exec demo-app-db psql -U demo_app -d demo_app -Atc "SELECT count(*) FROM notes"
# 你在初级册造的数据条数 —— 数据没丢,搬家成功
```

别忘了把本地文件存储 `storage/` 也一并迁过来（它同样是备份体系里的一等公民，此前保存在 v0 的旧目录中）：

```bash
sudo rm -rf /srv/demo-app/storage
sudo cp -a /srv/demo-app-v0-backup/storage /srv/demo-app/storage
sudo chown -R app:app /srv/demo-app/storage
```

> `install.sh` 被设计成了幂等脚本：已经就位的文件和配置不会被重复破坏。日后如果你修改了仓库里的部署脚本，升级方式就是“提交代码 → 在服务器上重跑一次 `install.sh`”（至于“改了脚本却忘了重跑”导致的线上脚本漂移问题，高级册第 7 章会加上自动检测机制）。

✅ **检查点**：执行 `ls -la /opt/demo-app/bin | head -5`，确认所有脚本的属主都是 `root`；执行 `sudo ls -la /opt/demo-app/env/`，确认 `runtime.env` 的权限和属主为 `-rw-r----- root app`。

---

## 第 3 章 deploy 用户的钥匙：SSH 强制命令

### 3.1 生成 CI 专用的密钥对

**【本地】**：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/demo_deploy_key -N "" -C "ci-deploy@demo-app"
```

生成的私钥（`demo_deploy_key`）稍后会配置到 GitHub Secrets 中；而**公钥**现在就要部署到服务器上。

### 3.2 authorized_keys：一把“只能开一扇门”的钥匙

**【服务器】**：

```bash
sudo mkdir -p /home/deploy/.ssh
sudo tee /home/deploy/.ssh/authorized_keys >/dev/null <<'EOF'
restrict,command="/opt/demo-app/bin/deploy-entry" ssh-ed25519 AAAA... ci-deploy@demo-app
EOF
# ↑ 把 AAAA... 换成 ~/.ssh/demo_deploy_key.pub 的内容(一整行)
sudo chown -R root:root /home/deploy/.ssh
sudo chmod 0755 /home/deploy/.ssh && sudo chmod 0644 /home/deploy/.ssh/authorized_keys
```

这段配置里有三个关键细节，每一处都大有讲究：

1. **`restrict`**：一键关闭这把公钥的所有“附加特权”——禁止分配伪终端（加 `-t` 会直接报错）、禁止端口转发（`-L`、`-R`、`-D` 全部失效）、禁止 X11 和 ssh-agent 转发，除了触发受控入口外什么都干不了。
2. **`command="..."`**：无论 SSH 客户端在命令行里请求执行什么命令，sshd 都会无视它，强制改为执行 `/opt/demo-app/bin/deploy-entry`。客户端原本想跑的那串命令会被放进环境变量 `SSH_ORIGINAL_COMMAND` 中，交由 `deploy-entry` 自行审查和裁决。
3. **`.ssh` 目录与 `authorized_keys` 文件均归 `root` 所有**：这意味着 `deploy` 用户自己（以及任何攻陷了 `deploy` 会话的人）**根本无法篡改自己的公钥配置或摘掉强制命令限制**。后面我们会亲手验证这道防线。

> 这就是参考设计中“通过 SSH 通知服务器部署”的完全体安全形态：虽然 22 端口依然对公网开放（高级册介绍的 Pull 模式会把这扇门彻底关上），但门后只留了一条一厘米宽的投递缝。

### 3.3 deploy-entry：只接受一种输入

来看 `/opt/demo-app/bin/deploy-entry`（归 `root` 所有，完整代码位于仓库 `deploy/deploy-entry`）：

```sh
#!/bin/sh
set -eu

fail() { echo "deploy-entry: $*" >&2; exit "$1"; }

cmd="${SSH_ORIGINAL_COMMAND:-}"
[ -n "$cmd" ] || fail 64 "no command; only 'deploy <sha>' is allowed"

case "$cmd" in
  "deploy "*) sha="${cmd#deploy }" ;;
  *) fail 64 "refused: only 'deploy <sha>' is allowed (got: $cmd)" ;;
esac

case "$sha" in
  ""|*[!0-9a-f]*) fail 65 "sha must be exactly 40 lowercase hex chars (got: $sha)" ;;
esac
[ "${#sha}" -eq 40 ] || fail 65 "sha must be exactly 40 chars (got ${#sha})"

. /opt/demo-app/bin/app.conf
mkdir -p "$LOG_DIR"

# 日志保留最近 20 份
ls -1t "$LOG_DIR"/deploy-*.log 2>/dev/null | tail -n +20 | xargs -r rm -f
LOG="$LOG_DIR/deploy-$(date -u +%Y%m%dT%H%M%S)_$$.log"
touch "$LOG" && chmod 640 "$LOG"

logger -t deploy-entry "accepted sha=$sha from=${SSH_CONNECTION:-local}"

# 关键设计:部署进程用 setsid 脱离 SSH 会话
setsid /opt/demo-app/bin/deploy.sh "$sha" >"$LOG" 2>&1 </dev/null &
pid=$!
tail -n +1 -f "$LOG" --pid="$pid" || true
wait "$pid"
```

这里有两个精妙的设计值得细品：

- **参数解析即白名单**：两段 `case` 模式匹配只放行形如 `deploy <40 位小写十六进制字符>` 的输入。无论是缩写 SHA、大写字母、多余空格，还是 `rm -rf` 或命令注入拼接（如 `deploy abc && ...`），统统在第一关就被拒之门外。
- **利用 `setsid` 脱离 SSH 会话**：真正的部署脚本 `deploy.sh` 运行在由 `setsid` 创建的独立会话中。哪怕中途 SSH 连接意外断开（例如 CI 任务超时被取消，或者你在本地触发时不小心合上了笔记本电脑），服务器上的部署依然会稳稳跑完，绝不会卡在半途变成僵尸状态。与此同时，SSH 客户端通过 `tail -f` 实时“旁观”日志文件——断线只是停止了旁观，丝毫不影响后台执行。而一旦连接保持到结束，最后的 `wait "$pid"` 会把 `deploy.sh` 的真实退出码原样传回给 SSH 客户端，让 GitHub Actions 能够准确标绿或标红。

### 3.4 deploy 用户的 GitHub 钥匙（让 repo.git 能够拉取代码）

```bash
# 注意:/home/deploy/.ssh 是 root 拥有的(deploy 改不了自己的钥匙),
# 所以密钥由 root 生成、再转交给 deploy:
sudo ssh-keygen -t ed25519 -f /home/deploy/.ssh/id_ed25519 -N "" -C "deploy@server fetch key"
sudo chown deploy:deploy /home/deploy/.ssh/id_ed25519 /home/deploy/.ssh/id_ed25519.pub
sudo cat /home/deploy/.ssh/id_ed25519.pub
# 贴到 GitHub → Settings → Deploy keys(read-only!)
# 预置 GitHub 的主机密钥(否则 git clone 会卡在指纹确认):
sudo ssh-keyscan -t ed25519 github.com > /home/deploy/.ssh/known_hosts
sudo chown root:root /home/deploy/.ssh/known_hosts && sudo chmod 0644 /home/deploy/.ssh/known_hosts
```

> 请注意这两把钥匙的职责分离：`deploy@server fetch key` 只能**只读拉取**代码仓库（供服务器上的 `git fetch` 使用），而 CI 持有的 `ci-deploy@demo-app` 只能**触发部署指令**。任何一把钥匙单独泄露，都不足以构成完整攻击链。

配好 GitHub Deploy Key 之后，我们来补完第 2 章里因为还没配好密钥而跳过的裸仓库克隆步骤（`install.sh` 是幂等的，直接重跑即可）：

```bash
cd ~/demo-app-bootstrap/deploy && sudo ./install.sh git@github.com:你的用户名/demo-app.git
# 这次 "== 7/9 仓库镜像缓存" 应该成功
sudo ls /srv/demo-app/repo.git/HEAD >/dev/null && echo repo-cache-OK
```

### 3.5 连接测试矩阵

**【本地】** 逐条执行下面的命令，对照注释检查输出是否符合预期：

```bash
KEY=~/.ssh/demo_deploy_key; H=deploy@203.0.113.10

ssh -i $KEY $H "uptime"
# deploy-entry: refused: only 'deploy <sha>' is allowed (got: uptime)

ssh -i $KEY $H "deploy abc123"
# deploy-entry: sha must be exactly 40 lowercase hex chars

ssh -i $KEY $H "deploy 0000000000000000000000000000000000000000 extra"
# deploy-entry: sha must be exactly 40 lowercase hex chars (got: 0000...0000 extra)

echo hello | ssh -i $KEY $H "cat > /tmp/x"
# deploy-entry: refused(文件传输?不存在的)

ssh -t -i $KEY $H
# deploy-entry: no command; only 'deploy <sha>' is allowed(交互 shell 被拒)

ssh -i $KEY -L 9999:localhost:5432 $H "deploy 0000000000000000000000000000000000000000" -N
# (立刻失败或被拒 —— restrict 禁止端口转发,数据库摸不到)
```

再来试最后一条“格式完全合法的部署请求”（传入 40 个 `0` 组成的假 SHA；它能通过 `deploy-entry` 的格式检查，但因为不在 `main` 分支的历史上，会在进入部署管线后的第 4 步被拦截）：

```bash
ssh -i $KEY $H "deploy 0000000000000000000000000000000000000000" 2>&1 | tail -3
# ... FAILED step=verify: SHA is not an ancestor of origin/main — rejected
```

✅ **检查点**：前六条非法请求在门口就被 `deploy-entry` 干净利落地拦下，报错原因清晰；最后一条格式合法但内容伪造的 SHA 则在管线内部的祖先校验阶段被拒绝——门卫与安检各司其职。

---

## 第 4 章 sudoers：最小权限白名单

`deploy.sh` 全程以非特权的 `deploy` 用户身份运行，但管线中有六个动作必须借用 `root` 权限：重启 systemd 单元、执行数据库备份（需要调用 `docker exec`）、运行迁移包装脚本、执行配置预检、执行健康检查，以及写入审计日志。为此，我们在 sudoers 中定义了一份精确到“具体脚本路径 + 允许参数模式”的最小白名单：

**【服务器】** 查看 `cat ~/demo-app-bootstrap/deploy/demo-app.sudoers`（刚才已被 `install.sh` 安装到 `/etc/sudoers.d/demo-app`）：

```sudoers
deploy ALL=(root) NOPASSWD: /opt/demo-app/bin/backup.sh premigrate, \
    /opt/demo-app/bin/backup.sh daily, \
    /opt/demo-app/bin/backup.sh manual, \
    /opt/demo-app/bin/migrate-wrapper.sh [0-9a-f]*, \
    /opt/demo-app/bin/check-config.sh [0-9a-f]*, \
    /opt/demo-app/bin/healthcheck.sh [0-9a-f]*, \
    /opt/demo-app/bin/audit.sh *, \
    /usr/bin/systemctl restart demo-app-web, \
    /usr/bin/systemctl restart demo-app-worker, \
    /usr/bin/systemctl restart demo-app-web.service, \
    /usr/bin/systemctl restart demo-app-worker.service, \
    /usr/bin/systemctl restart demo-app-web demo-app-worker, \
    /usr/bin/systemctl restart demo-app-web.service demo-app-worker.service
```

> - **强制使用绝对路径**：sudoers 规则中的所有命令都必须写成完整绝对路径（如 `/usr/bin/systemctl`），这是防范“攻击者在 `PATH` 前面塞一个同名假程序骗取提权”的经典基本功。
> - **参数也是权限边界的一部分**：在 sudoers 看来，`systemctl restart demo-app-web` 与 `systemctl restart demo-app-web demo-app-worker` 是两条完全独立的规则——它会把“命令 + 完整参数列表”当作一个整体去匹配。想借机执行 `systemctl stop ssh`？白名单里没有这条规则，直接免谈。
> - **通配符 `glob` 只是第一道防线**：sudoers 语法里的 `[0-9a-f]*` 中的 `*` 理论上可以跨空格匹配出额外参数，因此绝不能只靠 sudoers 通配符做参数校验。每个受控包装脚本（如 `migrate-wrapper.sh`）内部开头都会再次严格校验“有且仅有一个 40 位小写十六进制参数”——这就是纵深防御。
> - **`audit.sh *` 是一处有意为之的权衡**：`deploy` 用户确实可以通过它伪造一行审计日志，但考虑到 `deploy` 本来就有权触发真实部署，这并不会扩大实质攻击面。到了高级册第 8 章，我们会通过将 syslog 实时转发到远端日志服务器来彻底封死本地篡改的可能。

🧪 **动手验证**（**【服务器】** 模拟 `deploy` 用户视角测试权限边界）：

```bash
sudo -u deploy sudo systemctl restart demo-app-web
# (成功 —— 在白名单里)
sudo -u deploy sudo ls /root
# Sorry, user deploy is not allowed to execute '/bin/ls /root' as root
sudo -u deploy cat /opt/demo-app/env/runtime.env
# cat: ... Permission denied   ← 数据库密码,deploy 读不到(权限分层的体现)
```

修改 sudoers 有一条铁律：每次改完必须执行 `sudo visudo -cf /etc/sudoers.d/demo-app` 校验语法。**一旦写入了语法错误的 sudoers 文件，整台机器的 `sudo` 都会瞬间瘫痪**——到那时你就只能去云厂商后台开救援控制台了。

---

## 第 5 章 systemd 单元：web + worker，优雅退出

在 v1 架构中，我们将应用拆成了两个独立的 systemd 单元（`deploy/demo-app-web.service` 与 `deploy/demo-app-worker.service`，均已由 `install.sh` 安装就位）。来看看 web 单元的核心配置：

```ini
[Service]
User=app
Group=app
WorkingDirectory=/srv/demo-app/current        # ← 顺着软链找到当前版本
EnvironmentFile=/opt/demo-app/env/runtime.env # ← root:app 0640 的那份
ExecStart=/usr/bin/node /srv/demo-app/current/dist/server.js
Restart=on-failure
RestartSec=2
TimeoutStopSec=15                             # ← 给优雅退出的宽限期
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
```

对比初级册的 v0 单元，这里的每一处改动都有明确的工程意图：

- **`WorkingDirectory` 与 `ExecStart` 统一指向 `current` 软链**：每次部署只需原子切换 `current` 软链并执行 `systemctl restart`，systemd 单元文件本身一行都不用改。
- **`TimeoutStopSec=15`**：执行 `restart` 时，systemd 会先向进程发送 `SIGTERM` 信号。`server.js` 收到信号后会停止接收新连接、等待在途请求处理完毕再退出；`worker.js` 则会把当前手头的任务跑完再退出（配合任务队列实现“至少一次”投递语义）。如果超过 15 秒仍未退出，systemd 就会补发 `SIGKILL` 强制终结——因此应用层的优雅退出逻辑必须有超时意识。
- **使用 `Restart=on-failure` 而非 `always`**：当管理员主动执行 `systemctl stop` 时，服务应当老老实实停下，而不该被自动拉起。另外请注意 systemd 默认的启动频率限制：如果进程在短时间内连续崩溃 5 次，单元就会进入 `failed` 状态并**停止继续重启**。这是保护机制而非缺陷——无限崩溃循环不该被无声地掩盖，而第 7 章健康检查里的 30 秒观察期（soak 窗口）正是为了揪出这种“启动几秒后开始崩”的隐蔽故障。
- **最后四行安全加固指令**：禁止进程获取新特权、隔离私有 `/tmp` 目录、将系统目录与用户主目录设为只读或不可见。寥寥四行，既收敛了攻击面，又不会引入复杂的容器化心智负担。

至于单元之间的启动顺序（web 和 worker 都配置了 `Wants=docker.service`），它负责在机器重启时尽量先拉起 Docker；而万一应用启动时数据库容器还没就绪，则由应用自身的连接重试加上 `Restart=on-failure` 来稳稳兜底。

---

## 第 6 章 备份 v1：范围、保留、演练

相比初级册的朴素备份脚本，`/opt/demo-app/bin/backup.sh`（归 `root` 所有，由 sudoers 或 cron 调用）完成了三项关键升级：

1. **备份范围完整化**：不仅用 `pg_dump -Fc` 备份数据库，**还把 `storage/` 文件上传目录一并纳入备份**。“只备数据库、漏掉用户上传文件”是许多参考设计常犯的真实缺陷，我们在 v1 中直接补齐。
2. **保留策略采用“按份数 + 按时间”双重保护**：每个类别保留最近 N 份备份（`daily` 保留 14 份，`premigrate` 保留 10 份），**同时规定 7 天以内的备份无论如何一律不删**。如果只按份数保留，一旦某天连续部署十几次，高频生成的备份就会把几天前的历史备份全部挤掉。
3. **两类备份职责分明**：既有每天定时运行的 `daily` 备份，也有每次执行数据库迁移前自动触发的 `premigrate` 备份。一旦部署后需要回滚数据，手头总有一份紧挨着迁移前生成的最新快照可用。

🧪 **动手验证与恢复演练**（与初级册 6.3 节流程相同，熟练之后 30 秒即可跑完）：

```bash
sudo /opt/demo-app/bin/backup.sh manual
# backup[manual]: db=24K storage=4.0K
LATEST=$(sudo ls -1t /var/backups/demo-app/db | head -1) && echo "$LATEST"
docker run -d --name restore-drill -e POSTGRES_PASSWORD=drill -e POSTGRES_USER=drill -e POSTGRES_DB=drill postgres:16-alpine
sudo docker cp /var/backups/demo-app/db/$LATEST restore-drill:/tmp/r.dump   # 目录 0700,docker cp 也要 sudo
time docker exec restore-drill pg_restore -U drill -d drill --no-owner /tmp/r.dump
docker exec restore-drill psql -U drill -d drill -Atc "SELECT count(*) FROM notes"
docker rm -f restore-drill
```

> **没有经过恢复演练验证的备份，等于没有备份**。请把上面 `time` 命令输出的恢复耗时记录下来——这就是你手头第一份真实的 RTO（恢复时间目标）基线数据。到了高级册第 6 章，我们会针对不同数据规模测出完整的 RPO/RTO 量化表格。

---

## 第 7 章 部署管线逐行精读

这是本册最核心的一章。`deploy.sh` 全长约 150 行（完整源码见仓库 `deploy/deploy.sh`），我们将按管线执行的 16 个步骤逐一拆解。阅读每一步时，请思考以下三个问题：**这一步做什么？为什么要这么做？如果失败了会发生什么？**

### 7.1 第 0–2 步：参数校验、冻结开关、串行锁

```bash
SHA="${1:-}"
case "$SHA" in ""|*[!0-9a-f]*) die 65 arg "usage: deploy.sh <40-hex-sha>" ;; esac
[ "${#SHA}" -eq 40 ] || die 65 arg "sha must be 40 hex chars"

[ ! -e "$FREEZE_FILE" ] || die 70 freeze "deploys frozen: $FREEZE_FILE exists"

exec 9>"$LOCK_FILE"
flock -n 9 || die 75 lock "another deploy is running"
```

- **紧急冻结开关**：一旦管理员执行了 `touch /opt/demo-app/freeze`，后续所有部署请求都会在第一时间被明确拒绝并记录日志。线上出事故时，“先止血、冻结变更”永远比“赶紧推个补丁修修看”更优先。
- **`flock` 串行互斥锁**：如果两个部署请求同时抵达服务器，后到的那一个会**立即报错退出**，绝不排队等待，更不会交错执行。第 8 章 GitHub Actions 里的 `concurrency` 配置是第一道防线，而服务器侧的 `flock` 则是兜底的第二道防线——它不依赖 GitHub，无论是管理员手动触发、定时任务还是卡死的 CI runner，都休想并发执行两次部署。锁文件存放在 `/run`（内存文件系统 tmpfs）下，即使机器断电重启也会自动清空，不存在陈旧锁文件导致死锁的隐患。

### 7.2 第 3–5 步：幂等检查、来源校验、旧提交跳过

```bash
CURRENT=$(basename "$(readlink "$SRV_ROOT/current")")
if [ "$CURRENT" = "$SHA" ] && healthcheck ok; then exit 0; fi          # 幂等

git --git-dir="$REPO_CACHE" fetch --prune -q origin || die 11 ...
git --git-dir="$REPO_CACHE" merge-base --is-ancestor "$SHA" refs/heads/main \
  || die 12 verify "SHA is not an ancestor of origin/main"             # 祖先校验

git merge-base --is-ancestor "$SHA" "$CURRENT" && { log "skip: older"; exit 0; }   # 旧提交跳过
```

- **祖先校验（来源可信）**：管线只允许部署“确凿无疑处在 `origin/main` 历史链上”的提交。被 `force-push` 覆盖掉的孤儿提交、尚未合并的功能分支提交，或是本地还没推上远端的提交，统统会被拒之门外——确保真正上线运行的代码，必定是经过 CI 完整验证的那一份。
- **旧提交自动跳过**：如果因为 CI 排队等原因，导致抵达服务器的部署目标 SHA 比当前线上正在运行的 `CURRENT` 还要古老，管线会直接跳过并正常退出，保持线上版本不动。注意这一设计带来的重要推论：**你不能靠“重新运行旧提交的部署任务”来回滚线上版本**——这也正是为什么我们必须提供独立的 `rollback.sh`。

### 7.3 第 6–8 步：环境预检、隔离构建、原子提升

```bash
df 检查剩余空间 >1GiB 否则拒绝
读目标提交的 .node-version,与服务器的 node 主版本比对
检查目标提交里有 pnpm-lock.yaml

PARTIAL="$SRV_ROOT/.partial"
git archive "$SHA" | tar -x -C "$PARTIAL"          # 导出精确的提交内容
( cd "$PARTIAL" && env GIT_SHA="$SHA" bash -c "$BUILD_CMD" ) \
  || { rm -rf "$PARTIAL"; die 20 build "build failed — live site untouched"; }

mv "$PARTIAL" "$SRV_ROOT/releases/$SHA"            # 原子提升
```

- **构建时注入 `GIT_SHA`**：应用的 `/version` 端点返回的正是这个值。随后的健康检查会靠它断言“新版本真的已经顶替旧版本跑起来了”，而不是含糊地满足于“某个进程正在监听端口”。
- **`.partial` 暂存目录的生命周期**：只要构建过程中出现任何报错，脚本会立刻将 `.partial` 连根删除。因此 `releases/` 目录下永远只会有“100% 构建成功的完整版本”，彻底杜绝半成品残留。
- **用 `git archive` 替代 `git pull`**：直接从裸仓库缓存中导出目标提交的**纯净快照**，既不携带冗余的 `.git` 目录，也绝不会被工作区里的未跟踪文件污染。

> 当然，“在生产服务器上执行构建”依然是有代价的：这一步需要联网拉取依赖，还会消耗生产机的 CPU 和内存。当前参考设计为了保持架构最简而接受了这一代价；到了高级册第 3 章，我们会用实测对比数据来回答“什么时候不该再让生产机承担构建”。

### 7.4 第 9–11 步：配置预检、迁前备份、数据库迁移

```bash
sudo -n /opt/demo-app/bin/check-config.sh "$SHA" \
  || die 22 check-config "new release would crash on missing env"

sudo -n /opt/demo-app/bin/backup.sh premigrate \
  || die 24 backup "pre-migration backup failed — refusing to migrate"

sudo -n /opt/demo-app/bin/migrate-wrapper.sh "$SHA" \
  || die 26 migrate "migration failed — code NOT switched"
```

- **`check-config` 配置预检**：切换代码之前，先以 **`app` 用户身份、加载线上真实的 `runtime.env`** 运行一次 `node dist/config.js --check-config`。这样一来，像“新版本新增了必填环境变量 `NEW_API_KEY`，但运维忘了在服务器上配置”这类常见事故，就会从“**切换后进程崩溃 → 触发回滚兜底**”前移为“**切换前直接拦截 → 线上业务完全无感**”。特别留意它是以 `app` 用户身份运行的：权限与环境变量视角跟真实运行时分毫不差，绝不是 `deploy` 用户的隔靴搔痒。
- **备份失败则拒绝迁移**：宁可让本次部署直接报错中止，也绝不在没有最新备份兜底的情况下裸奔执行数据库迁移。
- **迁移失败则绝不切换代码**：如果迁移脚本报错，当前线上的 `current` 软链纹丝不动，旧版代码配合未受破坏的数据库结构继续正常对外服务。那执行到一半的迁移文件怎么办？`migrate.js` 会把每个 `.sql` 文件包装在独立的数据库事务中执行，失败的文件会整体回滚，且不会写入 `schema_migrations` 记录表。
- **双层迁移并发防护**：外层有 `migrate-wrapper.sh` 的文件锁 `flock`（单机级别快速失败），内层有 `migrate.js` 里的 PostgreSQL 会话级咨询锁 `pg_advisory_lock`（数据库级别互斥，将来扩展到多台应用服务器时依然有效）。

🧪 **现场验证数据库迁移并发锁**（**【服务器】**）：

```bash
# 两个终端同时各跑一个迁移,第二个会在 advisory lock 上排队
sudo -u app bash -c 'cd /srv/demo-app/current && set -a && . /opt/demo-app/env/runtime.env && node dist/migrate.js' &
sudo -u app bash -c 'cd /srv/demo-app/current && set -a && . /opt/demo-app/env/runtime.env && node dist/migrate.js'
# 第一个输出: migrate: up to date ...
# 第二个输出: migrate: acquiring advisory lock 918273645 ... (等第一个结束才继续)
```

### 7.5 第 12–14 步：原子切换、重启服务、健康检查与自动回切

```bash
ln -sfn "releases/$SHA" "$SRV_ROOT/.current.tmp"
mv -T "$SRV_ROOT/.current.tmp" "$SRV_ROOT/current"      # 原子切换(两步是关键)

sudo -n systemctl restart $UNITS || die 28 restart ...

if ! sudo -n /opt/demo-app/bin/healthcheck.sh "$SHA"; then
  # 回切到 $CURRENT,重启,再健康检查旧的
  #   旧的健康 → die 30(报告"已回滚成功")
  #   旧的也不健康 → die 31(报告"需要人工介入",绝不谎报成功)
fi
```

> **为什么要用 `ln -sfn` + `mv -T` 两步走**：在绝大多数类 Unix 系统上，单独执行 `ln -sfn new current` **并不是**原子操作（它的底层往往先 `unlink` 删掉旧软链，再 `symlink` 创建新软链，中间存在一个 `current` 完全不存在的微秒级空窗）。正确的教科书做法是：先创建一个指向新版本的临时软链 `.current.tmp`，再调用 `mv -T`（底层对应内核的 `rename(2)` 系统调用，属于严格的原子替换）瞬间覆盖 `current`。这一行虽短，却是整套参考设计中最值得照搬到任何项目的工程细节。

**`healthcheck.sh` 会严格断言以下五件事**（完整脚本见仓库，这里提炼核心逻辑）：

```bash
version=$(curl ... "$VERSION_URL")   # ① /version 的 gitSha == 目标 SHA(不是"端口通了")
ready=$(curl ... "$READY_URL")       # ② /health/ready 200 = DB 真实读写成功
hb=psql "SELECT now()-last_beat ..." # ③ worker 心跳 < 15s(覆盖 worker 单元)
for u in $UNITS; do is-active ...    # ④ 所有单元 active(不接受混合状态)
sleep "$SOAK_SECONDS"; 再全部查一遍   # ⑤ 30 秒 soak(抓"起来又崩"的循环)
```

其中第 ①、③、⑤ 项分别封堵了朴素健康检查中最容易漏网的三种“假阳性”故障：**切换未生效、依然是旧进程在应答**，**web 进程正常但后台 worker 陷入崩溃循环**，以及**新进程刚启动时能撑过前几秒探测、随后立刻崩溃**。许多初级部署脚本只用 `curl -f localhost:3000` 看一眼状态码就宣告部署成功，根本拦不住前两类故障——而 v1 的五重断言正是为此而生的完整修正。第 9 章我们将亲手制造这些故障场景，看健康检查如何把它们一一揪出来。

### 7.6 第 15–16 步：历史版本清理与审计落盘

```bash
# 保留最近 5 个 release,永不删除:当前版、上一版
sudo -n /opt/demo-app/bin/audit.sh "$SHA" deploy ok "$(( $(date +%s) - START_TS ))"
```

写入 `/var/log/demo-app/audit.log` 的记录格式如下：

```
2026-10-25T12:00:07Z actor=deploy action=deploy sha=1f2e... result=ok duration=94s
2026-10-25T12:40:11Z actor=sam action=rollback sha=0d9c... result=ok duration=9s
```

**部署管线退出码速查表**（第 10 章运维手册引用的就是这张表，与 `deploy.sh` 文件末尾的注释完全一致）：

| 退出码 | 故障阶段（step） | 含义与现场状态 |
|---|---|---|
| 11 / 12 | `fetch` / `verify` | `git fetch` 失败 / 目标 SHA 不在 `main` 分支历史中（可能遭遇了 `force-push`） |
| 13 / 14 / 15 | `preflight` | 磁盘剩余空间不足 / 服务器 Node 主版本与 `.node-version` 不符 / 提交中缺失 lockfile |
| 20 | `build` | 构建失败（已自动清理 `.partial` 暂存目录，线上服务完全无感） |
| 22 | `check-config` | 新版本缺失必需的环境变量配置（在切换软链前成功拦截） |
| 24 | `backup` | 迁移前自动备份失败（出于安全策略拒绝继续执行数据库迁移） |
| 26 | `migrate` | 数据库迁移失败（代码软链尚未切换，线上仍运行旧版本） |
| 28 | `restart` | `systemctl restart` 启动服务失败 |
| 30 / 31 / 32 | `health` | 新版本健康检查失败，已自动回切且旧版恢复健康 / 回切后旧版仍不健康（需人工介入）/ 首次部署即失败且无旧版本可退 |
| 64 / 65 | `arg` | 传入的参数格式非法 |
| 70 / 75 | `freeze` / `lock` | 部署已被 `freeze` 文件冻结 / 另一个部署进程正在运行中 |

---

## 第 8 章 GitHub Actions：CI 通过即部署

### 8.1 工作流配置（位于仓库 `.github/workflows/ci.yml`）

整个工作流包含两个任务：`check`（依次执行依赖安装 → 单元测试 → 构建校验 → 配置预检冒烟测试）和 `deploy`（声明 `needs: check`，并通过 `if` 条件严格限定**仅当推送到 `main` 分支或在 `main` 分支上手动触发时**才执行）。其中 `deploy` 任务的核心步骤只有寥寥几行：

```yaml
concurrency:
  group: deploy-production
  cancel-in-progress: false      # 不取消进行中的部署;排队行为高级册会讲
steps:
  - name: Deploy over SSH (forced command)
    env:
      HOST: ${{ secrets.DEPLOY_HOST }}
      KEY: ${{ secrets.DEPLOY_SSH_KEY }}
      KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
      SHA: ${{ github.sha }}
    run: |
      set -euo pipefail
      mkdir -p ~/.ssh
      printf '%s\n' "$KNOWN_HOSTS" > ~/.ssh/known_hosts
      install -m 600 /dev/stdin ~/.ssh/id_ed25519 <<<"$KEY"
      ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/known_hosts \
          -i ~/.ssh/id_ed25519 "deploy@$HOST" "deploy $SHA"
```

- **为什么不用现成的第三方 SSH Action**（例如 `appleboy/ssh-action`）：在部署通道里每引入一个第三方 Action，就多一层供应链被投毒的风险；何况上面这 5 行原生命令清晰透明，能让你彻底**看懂**每一次 SSH 连接究竟传了什么。等你先把这 5 行吃透，日后是否要换成封装好的 Action 全凭你自己的取舍。
- **用 `KNOWN_HOSTS` 锁死服务器主机指纹**：一旦目标服务器 IP 被意外顶替或遭遇中间人攻击，`ssh -o StrictHostKeyChecking=yes` 会直接报错中止，绝不会傻乎乎地弹出交互提示问“指纹变了，要继续吗？”。自动化部署通道对主机身份假冒必须零容忍。

### 8.2 配置三个 Secrets 与主机指纹

**【本地】** 采集服务器的 SSH 主机公钥指纹（注意：务必在你信任的网络环境下完成首次采集，后续 CI 每次连接都只认这一份指纹）：

```bash
ssh-keyscan -t ed25519 203.0.113.10
# 输出形如:203.0.113.10 ssh-ed25519 AAAAC3Nza...
```

打开 GitHub 仓库页面 → Settings → Secrets and variables → Actions → New repository secret，依次添加以下三个密钥：

| Secret 名称 | 填写的值 |
|---|---|
| `DEPLOY_HOST` | `203.0.113.10`（替换成你的服务器公网 IP） |
| `DEPLOY_SSH_KEY` | 本地 `~/.ssh/demo_deploy_key` 私钥的**完整全文**（用 `cat` 打印出来，连同头尾标记整段贴入） |
| `DEPLOY_KNOWN_HOSTS` | 上面 `ssh-keyscan` 命令输出的那一整行内容 |

### 8.3 触发首次自动化部署

**【本地】**：

```bash
cd ~/Projects/demo-app
git commit --allow-empty -m "deploy: v1 pipeline ready" && git push
```

打开 GitHub → Actions 页面，观察 `ci` 工作流运行：先是 `check` 任务变绿，紧接着 `deploy` 任务启动。点开 `deploy` 的日志流，你应该能实时看到服务器传回来的部署管线输出——正是我们在第 7 章逐行读过的那些步骤日志。

**【服务器】** 登录服务器做一次双重验证：

```bash
curl -s localhost:3000/version
# {"gitSha":"1f2e3d..."}   ← 和 Actions 页面上本次 commit 的 SHA 一模一样
sudo tail -1 /var/log/demo-app/audit.log
# ... action=deploy sha=1f2e3d... result=ok duration=XXs
readlink /srv/demo-app/current
# releases/1f2e3d...
```

🎉 **从合并代码到新版本平稳上线，全程不再需要任何人工登录和敲命令。** 既然正常路径已经跑通，下一章我们就专门来搞破坏。

---

## 第 9 章 故事会：八个坏提交（场景演练剧场）

> 本章的每个剧本都遵循统一节奏：**怎么制造故障** → **推送到远端** → **应该看到什么现象** → **背后验证了哪条工程原则**。每演练完一个剧本，请记得用 `git revert` 恢复代码。所有操作均在**你自己的实验仓库与实验机**上进行。

### 剧本 1：bad-build（构建阶段失败）

**【本地】** **制造故障**：在 `src/db.js` 里故意加一行语法错误（比如写半截 `const broken = {`），提交并推送（为了观察服务器侧的构建拦截，你可以临时跳过 CI 的构建步骤或在分支设置里观察它如何被拦下）。

**预期现象**：在 Actions 的部署日志中看到：

```
build: SYNTAX ERROR in src/db.js:
FAILED step=build: build failed — no release created, live site untouched
```

**【服务器】** **现场验证**：执行 `ls /srv/demo-app/releases | wc -l`，确认没有多出半成品目录；执行 `curl localhost:3000/version`，返回的依然是旧版 SHA。**验证原则：控制爆炸半径——构建失败被牢牢关在预检与暂存阶段，线上服务完全无感。**

### 剧本 2：lockfile-mismatch（依赖锁文件不一致）

**制造故障**：打开 `package.json`，手动把 `pg` 的版本号改成 `9.0.0`（故意不运行 `pnpm install` 更新 `pnpm-lock.yaml`），直接提交并推送。

**预期现象**：服务器在执行 `pnpm install --frozen-lockfile` 时直接报错拒绝（因为 lockfile 与 `package.json` 的声明不一致），部署在 `step=build` 阶段干净利落地失败退出。**验证原则：构建可复现性——绝不允许在生产机上静默解析出未经测试的新依赖版本。**

### 剧本 3：wrong-node-version（运行时版本漂移）

**制造故障**：把仓库根目录下的 `.node-version` 改成 `20.11.1`，提交并推送。

**预期现象**：日志打印 `FAILED step=preflight: server Node major=24, .node-version wants=20`，管线在预检阶段直接中止，线上毫发无损。**验证原则：将环境漂移暴雷前移到预检阶段，而不是等新语法在运行时报错。**

### 剧本 4：bad-migration（数据库迁移失败，代码绝不切换）

**制造故障**：新建 `migrations/003_bad.sql`，写入两条重复添加同名字段的语句：`ALTER TABLE notes ADD COLUMN boom; ALTER TABLE notes ADD COLUMN boom;`（第二条必然报错），提交并推送。

**预期现象**：

```
migrate: applying 003_bad.sql
migrate: FAILED at 003_bad.sql: column "boom" of relation "notes" already exists
FAILED step=migrate: migration failed — code NOT switched, live still on ...
```

**【服务器】** **现场验证**：执行 `curl localhost:3000/version`，线上依然是旧版 SHA；`/srv/demo-app/current` 软链没有变动；去数据库里查 `notes` 表，由于单文件事务回滚，`boom` 字段也并未残留；唯独**备份目录里多出了一份最新快照**（执行 `ls /var/backups/demo-app/db/ | tail -2`，可以看到迁移前自动触发的 `premigrate` 备份）。**验证原则：回滚安全与爆炸半径可控——迁移失败不是线上事故，只是一次被平稳拒绝的变更。** 演练完毕后执行 `git rm migrations/003_bad.sql && git commit && git push` 恢复。

### 剧本 5：bad-startup（迁移成功但新进程启动即崩 → 自动回切）

**制造故障**：在 `src/server.js` 的配置检查之后插入一行“生产环境专属炸弹”：

```js
if (process.env.APP_ENV === 'production') { throw new Error('boom: bad-startup fixture') }
```

（本地开发时 `APP_ENV` 是 `dev`，CI 测试时是 `ci`，两边都能一路绿灯通过；唯独到了生产服务器上才会引爆——这也是现实中最阴险的一类线上故障。）

**预期现象**：部署一路走到切换与重启，随后在健康检查阶段连续报 `version-mismatch`，最终触发自动回切：

```
health check FAILED — rolling back to <旧SHA>
FAILED step=health: new release unhealthy; rolled back to <旧SHA> (healthy). DB stays migrated — see expand/contract
```

**【服务器】** **现场验证**：执行 `curl localhost:3000/version`，确认已自动切回旧版 SHA，且 `/health/ready` 返回 200；查看 `journalctl -u demo-app-web -n 20` 则能抓到刚才新版本抛出的 `boom: bad-startup fixture` 异常堆栈。**验证原则：自动回切将故障窗口压缩到秒级 + 回滚安全（注意此时数据库保持在已迁移状态——因为我们的迁移是向后兼容的，旧代码依然能正常跑；如果刚才跑的是删表删列的破坏性迁移，此刻旧代码切回来就会集体报错，而高级册第 6 章的 expand/contract 模式正是为了确保这一刻永远安全）。** 演练完毕后 `git revert` 并推送，观察流水线恢复全绿。

### 剧本 6：bad-worker（web 正常但 worker 崩溃循环 → 被健康检查精准捕获）

**制造故障**：在 `src/worker.js` 的 `main()` 函数开头塞入一个定时炸弹：

```js
setInterval(() => { throw new Error('crash loop fixture') }, 3000)
```

**预期现象**：健康检查在检测 `worker-heartbeat=XXs` 时发现心跳超龄，判定部署失败并自动回切到旧版本。试想如果还是 v0 那种只看 web 端口通不通的简陋检查，这次部署就会**被误判为成功上线**——直到半夜用户投诉后台任务全部卡死才会被发现。**验证原则：健康检查必须覆盖所有业务单元，绝不接受“半死不活”的混合状态。** 演练完毕后 `git revert`。

### 剧本 7：needs-new-env（缺失新增环境变量，在切换前被拦截）

**制造故障**：在 `src/config.js` 的 `REQUIRED_ENV` 数组里新增一项 `'NEW_SECRET_TOKEN'`（故意不在服务器的 `runtime.env` 里配置它），提交并推送。

**预期现象**：

```
check-config: FAIL — missing required env: NEW_SECRET_TOKEN
FAILED step=check-config: new release would crash on missing env — kept current release
```

不妨把剧本 7 与剧本 5 对照来看：同样是“新版本在生产环境启动必崩”的缺陷，剧本 7 在**切换软链之前**就被 `check-config` 提前拦下（线上零抖动、零重启），而剧本 5 则是在**切换之后**靠健康检查与自动回滚兜底。**验证原则：把故障发现尽可能左移。** 演练完毕后 `git revert`。

### 剧本 8：重复部署、并发排队与断线续跑

- **幂等性验证**：对当前线上已经运行的同一个 SHA 再次手动触发部署（GitHub Actions → 选择 workflow → Run workflow），预期日志直接打印 `sha already live and healthy — nothing to do`，且 `audit.log` 里新增一条 `result=ok duration=1s` 的记录。
- **并发防撞验证**：在本地快速连续推送两个空提交，去 Actions 页面观察：两个 `deploy` 任务会按序排队（由 `concurrency` 控制），先跑完第一个再跑第二个，最终线上停留在最新的第二个提交上（如果旧提交的部署任务排在了新提交后面，管线第 5 步的“旧提交跳过”逻辑也会直接将其跳过）。服务器端的 `flock` 锁则为并发安全提供了最后一道硬件级保障。
- **SSH 断线不中断部署**：当 Actions 里的 `deploy` 任务正在执行构建或 soak 观察期时，手动在网页上点击 Cancel workflow（CI 界面会立刻变红显示已取消），然后去服务器上执行 `tail /var/log/demo-app/deploy-*.log | grep -E '===|FAILED'`——你会发现服务器上的部署依然有条不紊地跑到了最后一步。在断线期间 CI 状态与服务器真实状态出现短暂不一致，**这正是 `setsid` 脱离会话机制的预期保护效果，而不是 bug**。

---

## 第 10 章 运维一页通（runbook）

建议把下面这一页直接打印出来贴在手边。线上真出事的时候，不要再去从头翻几万字的教程。

```text
═══ 部署失败了(Actions 红了)═══════════════════════════════
1. 看 Actions 日志最后几行:FAILED step=??? 就是答案
2. 服务器视角: ls -1t /var/log/demo-app/ | head -3 → tail -50 最新那份
3. audit:     sudo tail -10 /var/log/demo-app/audit.log
4. 对照本文第 7 章的"退出码速查表"定位阶段
═══ 线上挂了,先止血 ═══════════════════════════════════════
回滚(不需要外网,大约 10 秒):
  sudo /opt/demo-app/bin/rollback.sh          # 回到上一个 release
  sudo /opt/demo-app/bin/rollback.sh <SHA>    # 回到指定 release
注意:迁移不会被回滚。若怀疑是数据问题 → 见下一条。
═══ 数据出事了 ═════════════════════════════════════════════
1. 停止自动部署止血: sudo touch /opt/demo-app/freeze
2. 找备份: sudo ls -lt /var/backups/demo-app/db/ | head
3. 恢复演练流程:中级册第 6 章(先在临时容器里恢复验证,再动正式库)
═══ 怀疑部署卡死 ════════════════════════════════════════════
1. 锁: sudo fuser -v /run/demo-app/deploy.lock   (谁持着?)
2. 确认没人跑: ps aux | grep deploy.sh
3. 清理: fuser -k /run/demo-app/deploy.lock(谨慎),锁文件可删
═══ 改了部署脚本(仓库 deploy/)════════════════════════════
sudo ~/demo-app-bootstrap/deploy/install.sh <repo-url>   # 重新安装(幂等)
注意:线上不会自动更新部署脚本(漂移风险,高级册加检测)
```

---

## 第 11 章 迁移到你自己的项目

这套部署管线的骨架与编程语言完全无关。当你准备把它套用到自己的真实项目时，只需按下面的清单改造：

**通常只改一个文件**：`deploy/app.conf`（集中定义了应用名称、系统用户名、systemd 单元列表、健康检查 URL、构建命令、迁移命令以及备份目录等所有可变参数）。

**最常改的只有两行**：`app.conf` 里的 `BUILD_CMD` 和 `MIGRATE_CMD`（例如换成 Go 项目的 `go build -o dist/app ./cmd/server`，或者 Python 项目的 `python -m alembic upgrade head`）。

**应用层适配清单**：

| 检查项 | 你的应用需要配合提供的能力 |
|---|---|
| `/version` 等价端点 | 返回构建时注入的 Git SHA 的接口（还没有？花 5 分钟写一个，10 行代码换来确定性的版本断言，非常值） |
| `/health/ready` 等价端点 | 探活接口，内部需检查核心外部依赖并执行一次真实的数据库读写探测 |
| `--check-config` 等价入口 | 在正式启动监听前校验必填环境变量是否齐全的命令行入口（回顾第 9 章剧本 7 的左移拦截价值） |
| worker 心跳等价机制 | 后台任务定期刷新数据库心跳表或本地时间戳文件，让健康检查能够覆盖到 worker 进程 |
| 数据库迁移机制 | 任何“版本化、可重放、有迁移记录表”的工具皆可；**哪怕项目目前不需要数据库迁移，也应在配置中显式保留“（空操作）”的占位概念** |
| 优雅退出处理 | 捕获 `SIGTERM` 信号，排干在途请求或当前任务后再退出 |

此外，别忘了同步修改 **sudoers 白名单里的服务单元名称**以及 **systemd 单元文件中的路径与启动命令**。到了高级册第 11 章，我们会把整套部署骨架原封不动地迁移到一个用 Go 编写的迷你项目上，并精确统计修改的代码行数，用实测数据证明它的可迁移性。

---

## 还没解决的问题（高级册的目录）

走到这里，你已经拥有了一套足够支撑绝大多数中小团队日常迭代的自动化部署系统。但如果你再往前深究一步，会发现还有 7 个问题留着悬念——而它们正是高级册的章节目录：

1. `systemctl restart` 期间依然存在几十到几百毫秒的重启窗口 → **如何用蓝绿切换实现零停机部署？**
2. 依赖安装与构建依然跑在生产服务器上 → **什么时候该切到 CI 构建产物？两者实测差距有多大？**
3. 服务器的 SSH 22 端口依然必须对公网开放 → **如何改造成服务器主动拉取的 Pull 模式？**
4. GitHub Secrets 里的 SSH 私钥依然是长期静态的 → **如何升级为短期有效的 SSH 证书？**
5. 如果遇到删列、改类型这类破坏性数据库迁移，怎么发布才不会炸？ → **expand/contract（扩展/收缩）全流程演练**
6. 万一有人改了仓库里的 `deploy/` 脚本却忘了上服务器重跑 `install.sh`，谁能第一时间发现？ → **脚本与配置漂移自动检测**
7. 我们的备份策略到底能保证多大的 RPO 与 RTO？ → **不同数据量级下的备份恢复实测表格**

---

*下一册：[高级教程 —— 对比、量化与升级决策](03-advanced.md)*
