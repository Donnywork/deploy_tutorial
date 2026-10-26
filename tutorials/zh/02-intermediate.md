# 中级教程:推送即部署,失败自动回滚

> **你会学到**:`git push` 之后,GitHub Actions 自动通知服务器完成"拉取 → 构建 → 预检 → 备份 → 迁移 → 原子切换 → 健康检查",任何一步失败都自动回到旧版本;部署凭证被盗,攻击者也只能触发一次合法部署,读不走你的任何密钥。
>
> **前置自查清单**(全部能答"是"再继续):
> - [ ] 我知道 `journalctl -u xxx -n 50` 是干什么的,并且亲手用过
> - [ ] 我的服务器上有:Nginx + HTTPS、systemd 管理的应用、Docker 跑的 Postgres、ufw 只开 22/80/443
> - [ ] 我做过至少一次数据库恢复演练(不是"知道怎么做",是做过)
> - [ ] 我能说出初级册结尾"八宗罪"里的任意三条
>
> 如果某条不确定:对应内容都在[初级教程](01-beginner.md),先补那一章。
>
> **本册原则**:回滚安全、健康检查要断言版本、不接受混合状态、最小权限、回滚是一等公民、可审计。

**本册产出**:一套完整可迁移的部署系统,全部脚本在仓库 `demo-app/deploy/` 下,服务器上落在 `/opt/demo-app/bin/`。换项目时通常只改一个 `app.conf`。

---

## 第 1 章 从 v0 到 v1:我们要修什么

初级册结尾我们审判了 v0 部署脚本的八宗罪。本册的目录就是判决书:

| # | v0 的罪 | v1 的方案 | 对应原则 |
|---|---|---|---|
| 1 | 停机窗口不可控 | `releases/<sha>/` + `current` 软链,切换是原子操作;重启窗口是唯一残余(高级册的蓝绿实验消灭它) | 控制爆炸半径 |
| 2 | 生产机上装依赖、构建 | 保留(参考设计),但构建失败绝不留半成品;高级册"在哪儿构建"用对比实验决策 | 一次构建处处部署、简单优先 |
| 3 | 半成品状态 | `.partial` 暂存目录,全部成功才 `mv` 成 release | — |
| 4 | 没有健康检查 | 断言 `/version` == 目标 SHA + DB 真实读写 + worker 心跳新鲜度 + 30s soak 窗口 | 健康检查要断言版本、不接受混合状态 |
| 5 | 回滚靠手速 | `rollback.sh`:不依赖外网、不动数据库、可计时的一等命令 | 回滚是一等公民 |
| 6 | 部署脚本拥有整个 sudo | 独立 `deploy` 用户 + SSH 强制命令 + sudoers 白名单(能做的只有:重启固定单元/备份/迁移/健康检查/审计) | 最小权限 |
| 7 | 无记录 | `audit.log` + `logger`(syslog),每次操作一行 | 可审计 |
| 8 | 迁移与代码错配 | 迁移失败 → 代码不切换;部署顺序:备份 → 迁移 → 切换;破坏性迁移用 expand/contract(高级册) | 回滚安全 |

**v1 的部署流程全景**(记住这张图,后面每节都是它的一块):

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

### 2.1 三个身份,各自能干什么

| 用户 | 是谁 | 能干什么 | 不能干什么 |
|---|---|---|---|
| `root`(你,经 `sam` 的 sudo) | 管理员 | 一切;拥有部署脚本、sudoers、deploy 的 authorized_keys | ——(所以你只在做管理动作时用它) |
| `deploy` | CI 的化身 | 登录方式**只有** SSH 强制命令;构建 release;经 sudo 白名单执行 5 个动作 | 读 `runtime.env`、改脚本、开 shell、传文件 |
| `app` | 服务本身 | 跑 web/worker、读 `runtime.env`、写 storage、连数据库 | 登录、改代码、碰部署脚本 |

> **为什么这么分**(最小权限):设想最坏情况——CI 的 SSH 私钥泄露。攻击者能做的只有"触发一次 main 上某个 SHA 的部署"和"刷白名单里的命令"。读不到数据库密码,改不了部署脚本(想部署恶意代码?SHA 必须是 main 的祖先,而 main 是受保护的)。爆炸半径被压到了最小。高级册第 5 章会量化对比静态密钥 vs 短期证书。

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

> **为什么是 `releases/<sha>` 而不是原地 `git pull`**:每个版本一份完整目录 = 天然的回滚能力(切软链即可)、天然的审计(目录名就是版本)、构建产物不可变(不存在"部署到一半的工作副本")。这也是 Capistrano 十几年来不变的核心设计——它值得被抄。

### 2.3 从 v0 布局迁移到 v1

**【服务器】** v0 的 checkout、unit 和 compose 先收拾干净(**数据库数据不动**,它在 Docker 卷里):

```bash
sudo systemctl disable --now demo-app
sudo rm /etc/systemd/system/demo-app.service
sudo cp /srv/demo-app/.env /tmp/demo-compose.env        # 保住数据库密码
cd /srv/demo-app && sudo docker compose down      # 卷保留(demo-app_pgdata);app 不在 docker 组,直接 sudo
cd /srv && sudo mv demo-app demo-app-v0-backup
```

把仓库最新代码弄到服务器(deploy 脚本要从里面安装),然后跑引导脚本:

```bash
cd ~ && git clone git@github.com:你的用户名/demo-app.git demo-app-bootstrap
cd demo-app-bootstrap/deploy
sudo ./install.sh git@github.com:你的用户名/demo-app.git
```

`install.sh`(仓库 `deploy/install.sh`,约 100 行,建议通读)做了 9 件事:创建 `app`/`deploy` 用户并锁密码 → 建上面那张目录表 → 安装脚本到 `/opt/demo-app/bin`(root 拥有)→ 装 sudoers 并 `visudo -cf` 校验 → 装 systemd 单元(enable 不 start)→ 安排 compose 与 `runtime.env`(把你刚才保住的密码填回去)→ 克隆 `repo.git` → 挂每日备份 cron → 打印下一步。

把 v0 的数据库密码接上,并确认数据还在:

```bash
sudo cp /tmp/demo-compose.env /opt/demo-app/compose/.env && rm /tmp/demo-compose.env
sudo rm -f /opt/demo-app/env/runtime.env    # 让下一步重新生成(用上面的密码)
sudo ./install.sh git@github.com:你的用户名/demo-app.git   # 幂等,重跑即可
docker exec demo-app-db psql -U demo_app -d demo_app -Atc "SELECT count(*) FROM notes"
# 你在初级册造的数据条数 —— 数据没丢,搬家成功
```

文件存储也要搬回来(它是备份范围的一等公民;v0 的 storage 在旧目录里):

```bash
sudo rm -rf /srv/demo-app/storage
sudo cp -a /srv/demo-app-v0-backup/storage /srv/demo-app/storage
sudo chown -R app:app /srv/demo-app/storage
```

> `install.sh` 是幂等的:已存在的东西不动。以后升级部署脚本本身就是"改仓库 → 重跑 install.sh"(脚本漂移问题,高级册第 7 章会给它加自动检测)。

✅ **检查点**:`ls -la /opt/demo-app/bin | head -5` 里所有文件 owner 都是 root;`sudo ls -la /opt/demo-app/env/` 里 `runtime.env` 是 `-rw-r----- root app`。

---

## 第 3 章 deploy 用户的钥匙:SSH 强制命令

### 3.1 生成 CI 专用的密钥对

**【本地】**:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/demo_deploy_key -N "" -C "ci-deploy@demo-app"
```

私钥(`demo_deploy_key`)稍后放进 GitHub Secrets;**公钥**现在就上服务器。

### 3.2 authorized_keys:一把"只能开一扇门"的钥匙

**【服务器】**:

```bash
sudo mkdir -p /home/deploy/.ssh
sudo tee /home/deploy/.ssh/authorized_keys >/dev/null <<'EOF'
restrict,command="/opt/demo-app/bin/deploy-entry" ssh-ed25519 AAAA... ci-deploy@demo-app
EOF
# ↑ 把 AAAA... 换成 ~/.ssh/demo_deploy_key.pub 的内容(一整行)
sudo chown -R root:root /home/deploy/.ssh
sudo chmod 0755 /home/deploy/.ssh && sudo chmod 0644 /home/deploy/.ssh/authorized_keys
```

三个细节,每个都有讲究:

1. **`restrict`**:关掉这把钥匙的一切"附加功能"——不能开终端(`-t` 失败)、不能端口转发(`-L/-R/-D` 失败)、不能 X11/agent 转发、不能碰 `SSH_ORIGINAL_COMMAND` 以外的东西。
2. **`command="..."`**:不管客户端发什么命令,sshd 都强制执行这一个。客户端真正想跑的命令会放进环境变量 `SSH_ORIGINAL_COMMAND`,由 `deploy-entry` 自己裁决。
3. **目录和文件都是 root 拥有**:deploy 用户(以及偷到 deploy 密码的任何人)**改不了自己的钥匙**。接下来几节会动手验证这一点。

> 这就是参考设计的"SSH 通知服务器"的安全形态:端口 22 必须对公网开着(高级册的 Pull 模式会把这道门整个关掉),但门后只有一个一厘米宽的缝。

### 3.3 deploy-entry:只接受一种输入

`/opt/demo-app/bin/deploy-entry`(root 拥有,内容见仓库 `deploy/deploy-entry`):

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

读懂两个设计:

- **参数即白名单**:`case` 的模式匹配只放行 `deploy ` + 40 位小写十六进制。短 SHA、大写、带空格、`rm -rf`、环境变量注入(`deploy abc && ...`)全部被拒。
- **`setsid` 脱离**:部署进程跑在新的会话里,SSH 连接断掉(CI 超时、笔记本合盖)它也不受影响;SSH 客户端通过 `tail -f` "看"日志,断线只是看不到了,不影响执行。`wait "$pid"` 把部署的真实退出码还给 SSH,CI 那头能正确标红。

### 3.4 deploy 用户的 GitHub 钥匙(repo.git 要能 fetch)

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

> 两把钥匙分工明确:`deploy@server fetch key` 只能**读**仓库(给 git fetch 用);CI 的 `ci-deploy@demo-app` 只能**触发部署**。任何一把单独泄露都不够造成事故。

钥匙配好后,补完第 2 章没完成的那一步(install.sh 是幂等的,重跑即可):

```bash
cd ~/demo-app-bootstrap/deploy && sudo ./install.sh git@github.com:你的用户名/demo-app.git
# 这次 "== 7/9 仓库镜像缓存" 应该成功
sudo ls /srv/demo-app/repo.git/HEAD >/dev/null && echo repo-cache-OK
```

### 3.5 连接测试矩阵

**【本地】** 逐条试,右边是预期:

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

最后一条"真的部署"(40 个 0 不在 main 历史上,会在部署脚本的第 4 步被拒,但那已经是**进入部署管线之后**的事了):

```bash
ssh -i $KEY $H "deploy 0000000000000000000000000000000000000000" 2>&1 | tail -3
# ... FAILED step=verify: SHA is not an ancestor of origin/main — rejected
```

✅ **检查点**:六条非法输入全部被拒且理由清晰;最后一条走到了"管线内部拒绝"——门卫和安检各司其职。

---

## 第 4 章 sudoers:最小权限白名单

deploy.sh 以 deploy 用户运行,但有六个动作需要 root:重启单元、备份(docker exec)、迁移包装、配置预检、健康检查、审计。sudoers 白名单精确到"哪个脚本 + 什么参数":

**【服务器】** `cat ~/demo-app-bootstrap/deploy/demo-app.sudoers`(已由 install.sh 装到 `/etc/sudoers.d/demo-app`):

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

> - **绝对路径**:sudoers 里的命令必须写绝对路径(`/usr/bin/systemctl`),这是防"我放一个假 systemctl 到 PATH 里"的经典骗术。
> - **参数即边界**:`systemctl restart demo-app-web` 和 `systemctl restart demo-app-web demo-app-worker` 是两条不同的规则——sudoers 把"命令 + 精确参数"整体匹配。想 `systemctl stop ssh`?没这条规则,免谈。
> - **glob 只是第一层**:`[0-9a-f]*` 理论上可能匹配出带空格的参数(sudoers 的 `*` 能跨空格),所以每个包装脚本内部还会再验一次"恰好一个 40 位十六进制"——这是第二层纵深防御。
> - **`audit.sh *` 是已知让步**:deploy 能伪造审计行(它本来就能触发部署)。高级册第 8 章用转发到另一台机器的 syslog 修正。

🧪 **验证**(【服务器】以 deploy 身份):

```bash
sudo -u deploy sudo systemctl restart demo-app-web
# (成功 —— 在白名单里)
sudo -u deploy sudo ls /root
# Sorry, user deploy is not allowed to execute '/bin/ls /root' as root
sudo -u deploy cat /opt/demo-app/env/runtime.env
# cat: ... Permission denied   ← 数据库密码,deploy 读不到(权限分层的体现)
```

改 sudoers 的铁律:改完必 `sudo visudo -cf /etc/sudoers.d/demo-app`。**写坏 sudoers 文件可能让整个 sudo 瘫痪**——那你只能靠厂商控制台救援了。

---

## 第 5 章 systemd 单元:web + worker,优雅退出

v1 有两个单元(`deploy/demo-app-web.service`、`deploy/demo-app-worker.service`,install.sh 已安装)。web 单元关键行:

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

与 v0 的差异都有理由:

- **`WorkingDirectory`/`ExecStart` 走 `current` 软链**:部署切换软链 + `systemctl restart`,服务的配置文件一个字都不用改。
- **`TimeoutStopSec=15`**:restart 时 systemd 先发 SIGTERM。server.js 收到后排干在途请求再退出;worker 处理完手头任务再退出(至少一次语义)。15 秒还没退就 SIGKILL——所以应用的优雅退出代码要有时间意识。
- **`Restart=on-failure` 而非 `always`**:我们自己 `stop` 时不该被自动拉起。注意 systemd 默认的启动限流:连续崩 5 次进 `failed` 态**不再拉起**。这是特性不是 bug——崩溃循环不该被无限掩盖,健康检查的 soak 窗口就是为抓它设计的。
- 最后四行是最小加固:进程拿不到新特权、有私有 /tmp、文件系统大部分只读。够用且不喧宾夺主。

单元间的依赖(web/worker 都 `Wants=docker.service`)在开机时保证顺序;真实的"数据库没就绪怎么办"由应用自身的重试 + `Restart=on-failure` 兜住。

---

## 第 6 章 备份 v1:范围、保留、演练

`/opt/demo-app/bin/backup.sh`(root 拥有,由 sudoers/cron 调用)相对 v0 的三个升级:

1. **范围**:数据库(`pg_dump -Fc`)**加** `storage/` 文件目录。"只备数据库、漏掉文件存储"在参考设计里是真的缺陷,v1 直接修掉。
2. **保留策略 = 按次数 + 按时间组合**:每类保留最近 N 份(daily 14 / premigrate 10),**且 7 天内的一律不删**。只按次数的原始设计在部署频繁时会把历史挤光(保留策略的另一半)。
3. **两类备份分开**:每日定时 `daily` + 每次迁移前 `premigrate`(部署时自动触发)。回滚时优先用最近的 `premigrate`。

🧪 **验证 + 演练**(和初级册 6.3 同样的动作,这次 30 秒完成):

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

> **备份的要求是"有真实恢复演练证据"**。把这条命令的输出存好——它是你的 RTO 第一手数据。高级册第 6 章会测出完整表格(大小/耗时/RPO)。

---

## 第 7 章 部署管线逐行精读

这是本册的核心章。`deploy.sh` 约 150 行(全文见仓库 `deploy/deploy.sh`),我们按 16 步走读。每步都回答三个问题:**做什么?为什么?失败了会怎样?**

### 7.1 第 0–2 步:参数、冻结开关、串行锁

```bash
SHA="${1:-}"
case "$SHA" in ""|*[!0-9a-f]*) die 65 arg "usage: deploy.sh <40-hex-sha>" ;; esac
[ "${#SHA}" -eq 40 ] || die 65 arg "sha must be 40 hex chars"

[ ! -e "$FREEZE_FILE" ] || die 70 freeze "deploys frozen: $FREEZE_FILE exists"

exec 9>"$LOCK_FILE"
flock -n 9 || die 75 lock "another deploy is running"
```

- **冻结开关**:`touch /opt/demo-app/freeze` 之后所有部署被明确拒绝并留下日志。出事故时"先止血"比"赶紧修"优先。
- **flock**:两个部署同时来,第二个**立刻失败**而不是排队或交错执行。workflow 的 `concurrency` 是第一道防线(第 8 章),flock 是第二道——它不依赖 GitHub,手动触发、定时任务、卡死的 runner 都会被它拦住。锁文件在 `/run`(内存盘),机器重启自动清空,不会死锁。

### 7.2 第 3–5 步:幂等、来源校验、旧提交跳过

```bash
CURRENT=$(basename "$(readlink "$SRV_ROOT/current")")
if [ "$CURRENT" = "$SHA" ] && healthcheck ok; then exit 0; fi          # 幂等

git --git-dir="$REPO_CACHE" fetch --prune -q origin || die 11 ...
git --git-dir="$REPO_CACHE" merge-base --is-ancestor "$SHA" refs/heads/main \
  || die 12 verify "SHA is not an ancestor of origin/main"             # 祖先校验

git merge-base --is-ancestor "$SHA" "$CURRENT" && { log "skip: older"; exit 0; }   # 旧提交跳过
```

- **祖先校验**:只部署"真的在 main 历史上"的提交。force-push 顶掉的 SHA、开发分支的 SHA、本地没推过的 SHA 一律拒绝——部署的就是 CI 测过的那份东西。
- **旧提交跳过**:排队的部署比线上还旧?跳过(线上不动)。注意推论:**不能用"重新部署旧 SHA"来回滚**——这正是 `rollback.sh` 必须存在的原因。

### 7.3 第 6–8 步:预检、构建、提升

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

- **构建注入 `GIT_SHA`**:`/version` 端点返回的就是它。健康检查靠它断言"新版本真的在线上"——不是"某个版本在线上"。
- **`.partial` 的生命周期**:构建失败就整个删掉,`releases/` 里永远只有"完整构建成功过的版本"。
- **`git archive` 而不是 `git pull`**:导出的是**提交的精确快照**,不带 `.git`、不受工作区状态影响。

> "在生产机构建的代价"依然存在:这一步要联网下载依赖、要吃 CPU。参考设计接受了这个代价,高级册第 3 章会用对比实验回答"什么时候不该接受"。

### 7.4 第 9–11 步:配置预检、备份、迁移

```bash
sudo -n /opt/demo-app/bin/check-config.sh "$SHA" \
  || die 22 check-config "new release would crash on missing env"

sudo -n /opt/demo-app/bin/backup.sh premigrate \
  || die 24 backup "pre-migration backup failed — refusing to migrate"

sudo -n /opt/demo-app/bin/migrate-wrapper.sh "$SHA" \
  || die 26 migrate "migration failed — code NOT switched"
```

- **check-config**:以 **app 用户身份、加载真实 `runtime.env`** 跑 `node dist/config.js --check-config`。"新版本需要 `NEW_API_KEY` 但没人配"这类事故,从**切换后崩溃 → 回滚兜底**变成**切换前拒绝 → 线上无感**。注意它以 app 用户跑:和运行时完全同视角(权限、环境变量都一致),而不是 deploy 用户的想当然。
- **备份失败 = 拒绝迁移**:宁可部署失败,不可裸奔迁移。
- **迁移失败 = 代码不切换**:线上仍是旧版本,旧代码 + 未变的 schema,继续正常服务。已应用的迁移停在半路?`migrate.js` 每个文件一个事务,失败的文件整体回滚,`schema_migrations` 不会记录它。
- **迁移并发防护是双层的**:`migrate-wrapper.sh` 的 flock(主机级,快速失败)+ `migrate.js` 里的 `pg_advisory_lock`(数据库级,跨主机也成立)。

🧪 **迁移并发防护现场验证**(【服务器】):

```bash
# 两个终端同时各跑一个迁移,第二个会在 advisory lock 上排队
sudo -u app bash -c 'cd /srv/demo-app/current && set -a && . /opt/demo-app/env/runtime.env && node dist/migrate.js' &
sudo -u app bash -c 'cd /srv/demo-app/current && set -a && . /opt/demo-app/env/runtime.env && node dist/migrate.js'
# 第一个输出: migrate: up to date ...
# 第二个输出: migrate: acquiring advisory lock 918273645 ... (等第一个结束才继续)
```

### 7.5 第 12–14 步:原子切换、重启、健康检查

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

> **为什么 `ln -sfn` + `mv -T` 两步**:单独 `ln -sfn new current` 在大多数系统上**不是**原子的(它可能先删再建,中间有个不存在的瞬间)。先建临时软链、再用 `mv -T`(rename,内核级原子操作)顶替,才是教科书做法。这个细节是参考设计里最值得抄的一行。

**healthcheck.sh 断言五件事**(全文见仓库,这里是要点):

```bash
version=$(curl ... "$VERSION_URL")   # ① /version 的 gitSha == 目标 SHA(不是"端口通了")
ready=$(curl ... "$READY_URL")       # ② /health/ready 200 = DB 真实读写成功
hb=psql "SELECT now()-last_beat ..." # ③ worker 心跳 < 15s(覆盖 worker 单元)
for u in $UNITS; do is-active ...    # ④ 所有单元 active(不接受混合状态)
sleep "$SOAK_SECONDS"; 再全部查一遍   # ⑤ 30 秒 soak(抓"起来又崩"的循环)
```

①③⑤ 分别封堵三种假阳性:**旧进程还在应答**(切换其实没生效)、**worker 崩溃循环但 web 正常**、**起来 10 秒就崩但检查已通过**。"健康检查有假阳性"这个假设认为参考设计的健康检查拦不住前两种——v1 的实现就是修正本身。第 9 章会现场制造这两种假阳性给你看。

### 7.6 第 15–16 步:保留策略、审计

```bash
# 保留最近 5 个 release,永不删除:当前版、上一版
sudo -n /opt/demo-app/bin/audit.sh "$SHA" deploy ok "$(( $(date +%s) - START_TS ))"
```

`audit.log` 长这样:

```
2026-10-25T12:00:07Z actor=deploy action=deploy sha=1f2e... result=ok duration=94s
2026-10-25T12:40:11Z actor=sam action=rollback sha=0d9c... result=ok duration=9s
```

**退出码速查表**(runbook 引用的就是这张;与 `deploy.sh` 末尾注释一致):

| 退出码 | step | 含义 |
|---|---|---|
| 11 / 12 | fetch / verify | git fetch 失败 / SHA 不在 main 历史(force-push?) |
| 13 / 14 / 15 | preflight | 磁盘不足 / Node 主版本不符 / 提交里没有 lockfile |
| 20 | build | 构建失败(已清理 .partial,线上无感) |
| 22 | check-config | 新版本缺必需配置(切换前拦截) |
| 24 | backup | 迁移前备份失败(拒绝迁移) |
| 26 | migrate | 迁移失败(代码未切换) |
| 28 | restart | systemctl restart 失败 |
| 30 / 31 / 32 | health | 已自动回切且旧版健康 / 回切后仍不健康(需要人工)/ 首次部署失败且无退路 |
| 64 / 65 | arg | 参数非法 |
| 70 / 75 | freeze / lock | 部署被冻结 / 已有部署在进行 |

---

## 第 8 章 GitHub Actions:CI 通过即部署

### 8.1 workflow(仓库 `.github/workflows/ci.yml`,全文在仓库里)

两个 job:`check`(install → test → build → 配置预检烟测)和 `deploy`(`needs: check`,且 `if` 里限定 **push 到 main 或 main 上的手动触发**)。deploy job 的核心:

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

- **不使用现成的 SSH action**(如 appleboy/ssh-action):多一层依赖就多一层供应链风险,而且这 5 行能让你**看懂**每一次连接。想换 action,理解这 5 行之后再说。
- **`KNOWN_HOSTS` 固定主机指纹**:服务器被替换/中间人时,`ssh` 直接失败而不是提示"指纹变了,继续吗?"。部署通道对主机身份零容忍。

### 8.2 三个 Secrets + host key

**【本地】** 拿服务器的 host key(注意:要在你信任的网络下第一次拿,之后只认这一份):

```bash
ssh-keyscan -t ed25519 203.0.113.10
# 输出形如:203.0.113.10 ssh-ed25519 AAAAC3Nza...
```

GitHub → 你的仓库 → Settings → Secrets and variables → Actions → New repository secret,添加:

| Secret | 值 |
|---|---|
| `DEPLOY_HOST` | `203.0.113.10` |
| `DEPLOY_SSH_KEY` | `~/.ssh/demo_deploy_key` 私钥**全文**(`cat` 出来整段贴入) |
| `DEPLOY_KNOWN_HOSTS` | 上面 `ssh-keyscan` 的输出整行 |

### 8.3 首次部署

**【本地】**:

```bash
cd ~/Projects/demo-app
git commit --allow-empty -m "deploy: v1 pipeline ready" && git push
```

GitHub → Actions → 看着 `ci` workflow:`check` 绿 → `deploy` 跑起来,日志里应该看到服务器返回的部署流水输出(就是第 7 章那些步骤日志)。

**【服务器】** 双重验证:

```bash
curl -s localhost:3000/version
# {"gitSha":"1f2e3d..."}   ← 和 Actions 页面上本次 commit 的 SHA 一模一样
sudo tail -1 /var/log/demo-app/audit.log
# ... action=deploy sha=1f2e3d... result=ok duration=XXs
readlink /srv/demo-app/current
# releases/1f2e3d...
```

🎉 **从合并代码到线上新版本,中间没有任何人工步骤。** 下一章专门搞破坏。

---

## 第 9 章 故事会:八个坏提交(场景演练剧场)

> 每个剧本格式:**怎么造** → **推上去** → **该看到什么** → **验证了哪条原则**。做完记得 `git revert` 恢复。全部在**你的实验仓库**做。

### 剧本 1:bad-build(构建失败)

**【本地】** 造:在 `src/db.js` 里加一行语法错误(如 `const broken = {`),提交推送。

**该看到**:Actions 的 deploy job 里:

```
build: SYNTAX ERROR in src/db.js:
FAILED step=build: build failed — no release created, live site untouched
```

**【服务器】** 验证:`ls /srv/demo-app/releases | wc -l` 没多;`curl localhost:3000/version` 还是旧 SHA。**原则:爆炸半径最小——失败留在预检阶段,线上无感。**

### 剧本 2:lockfile-mismatch

造:`package.json` 里手动把 `pg` 的版本改成 `9.0.0`(不跑 `pnpm install`),推送。

该看到:服务器上 `pnpm install --frozen-lockfile` 拒绝(lockfile 与 manifest 不一致),step=build 失败。**原则:可复现性。**

### 剧本 3:wrong-node-version

造:把 `.node-version` 改成 `20.11.1`,推送。

该看到:`FAILED step=preflight: server Node major=24, .node-version wants=20`。线上无感。**原则:环境漂移在预检阶段暴露。**

### 剧本 4:bad-migration(迁移失败,代码不切换)

造:新建 `migrations/003_bad.sql`,内容 `ALTER TABLE notes ADD COLUMN boom; ALTER TABLE notes ADD COLUMN boom;`(重复列名必然报错),推送。

该看到:

```
migrate: applying 003_bad.sql
migrate: FAILED at 003_bad.sql: column "boom" of relation "notes" already exists
FAILED step=migrate: migration failed — code NOT switched, live still on ...
```

**【服务器】** 验证:`curl localhost:3000/version` 仍是旧 SHA;`/srv/demo-app/current` 没变;但**备份多了一份**(`ls /var/backups/demo-app/db/ | tail -2`,迁移前的 premigrate 备份)。**原则:回滚安全 + 爆炸半径可控——迁移失败不是灾难,是又一次被拒绝的变更。** 恢复:`git rm migrations/003_bad.sql && git commit && git push`。

### 剧本 5:bad-startup(迁移成功但起不来 → 自动回切)

造:在 `src/server.js` 的配置检查之后插入:

```js
if (process.env.APP_ENV === 'production') { throw new Error('boom: bad-startup fixture') }
```

(本地是 `dev`,CI 是 `ci`,都不炸;只有服务器上炸——这种"只在生产爆炸"的 bug 就是最阴的那种。)

该看到:部署走到健康检查,`version-mismatch` 一直失败,然后:

```
health check FAILED — rolling back to <旧SHA>
FAILED step=health: new release unhealthy; rolled back to <旧SHA> (healthy). DB stays migrated — see expand/contract
```

**【服务器】** 验证:`curl localhost:3000/version` 回到旧 SHA 且 `/health/ready` 是 200;`journalctl -u demo-app-web -n 20` 里能看到那个 `boom` 报错。**原则:自动回切把爆炸半径压到最小 + 回滚安全(数据库保持已迁移状态——本次没有破坏性迁移,所以旧代码照跑;如果迁移是破坏性的,这里就是事故现场,高级册 expand/contract 教你让这种时刻永远安全)。** 恢复:revert 后推送,看它再次部署成功。

### 剧本 6:bad-worker(web 正常 worker 崩溃 → 健康检查抓住)

造:在 `src/worker.js` 的 `main()` 开头加:

```js
setInterval(() => { throw new Error('crash loop fixture') }, 3000)
```

该看到:健康检查卡在 `worker-heartbeat=XXs`(心跳超龄),回切。如果 v0 的健康检查只看 web 端口,这个版本就会**被当成部署成功**——半夜 worker 全线罢工。**原则:健康检查要覆盖全部单元。** 恢复:revert。

### 剧本 7:needs-new-env(缺配置,切换前拦截)

造:在 `src/config.js` 的 `REQUIRED_ENV` 数组里加 `'NEW_SECRET_TOKEN'`(不配置它),推送。

该看到:

```
check-config: FAIL — missing required env: NEW_SECRET_TOKEN
FAILED step=check-config: new release would crash on missing env — kept current release
```

对比剧本 5:同样的缺陷,一个在**切换前**被拦(线上零影响),一个在**切换后**靠回滚兜底。**原则:把失败左移。** 恢复:revert。

### 剧本 8:重复部署与并发

- **幂等**:对同一个 SHA 再次手动触发(Actions → deploy workflow → Run workflow),预期 `sha already live and healthy — nothing to do`,audit 里多一条 `result=ok duration=1s`。
- **并发**:快速连续 push 两个提交,去 Actions 看:两个 deploy 排队(concurrency),先跑完旧的再跑新的,最后线上是第二个(旧的若更旧会被 skip)。服务器侧 flock 日志里留有证据。
- **断线不中断**:Actions 里 deploy 正在跑时,手动 Cancel workflow(CI 侧立刻"失败"),然后服务器上 `tail /var/log/demo-app/deploy-*.log | grep -E '===|FAILED'`——部署照常完成。CI 状态与真实结果短暂不一致,**这是设计使然(setsid),不是 bug**。

---

## 第 10 章 运维一页通(runbook)

把这一页打印出来。出事时不要翻教程。

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

部署骨架与语言无关。换项目时:

**只改一处**:`deploy/app.conf`(应用名/用户名/单元列表/健康检查 URL/构建命令/迁移命令/备份目录...)。

**常改两处**:`app.conf` 里的 `BUILD_CMD`、`MIGRATE_CMD`(如 `go build -o dist/app ./cmd/server`、`python -m alembic upgrade head`)。

**适配清单**:

| 检查项 | 你的应用需要提供 |
|---|---|
| `/version` 等价物 | 构建时注入版本号的端点(没有?加一个,10 行代码,值得) |
| `/health/ready` 等价物 | 检查关键依赖 + 真实读写 |
| `--check-config` 等价物 | 启动前校验必需环境变量的入口(中级册剧本 7 的价值) |
| worker 心跳等价物 | 后台任务写心跳表/文件,健康检查才能覆盖它 |
| 迁移机制 | 任何"版本化、可重放、带记录"的都行;**没有迁移机制的应用也应该有"(空)"** |
| 优雅退出 | SIGTERM 处理(在途请求/任务) |

**sudoers 里的单元名**和 **systemd 单元的路径**记得同步改。高级册第 11 章会把这套东西完整套到一个 Go 迷你项目上,并统计改动行数作为"可迁移性"的证据。

---

## 还没解决的问题(高级册的目录)

1. 重启窗口仍然存在(几十到几百毫秒)→ **蓝绿切换**
2. 构建仍在生产机上 → **CI 构建产物对比实验**
3. SSH 端口必须对公网开放 → **Pull 模式**
4. CI 私钥是长期静态的 → **短期 SSH 证书**
5. 破坏性迁移怎么做才安全 → **expand/contract 全流程**
6. 部署脚本被改了没重装,谁会发现?→ **漂移检测**
7. 备份的 RPO/RTO 到底是多少?→ **实测表格**

---

*下一册:[高级教程 —— 对比、量化与升级决策](03-advanced.md)*
