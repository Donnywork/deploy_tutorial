# 初级教程：一台服务器、一个域名、一条 HTTPS 网址

> **你会学到**：如何把自己编写的 Web 应用（含数据库）部署到一台真实的公网服务器上，让它 7×24 小时常驻运行、通过域名与 HTTPS 安全访问、每天自动执行备份（并亲手完成一次恢复演练），最后用一条命令完成日常更新与部署。
>
> **你需要准备**：
> - 一台自己的电脑（Windows、Mac 或 Linux 均可，能打开终端就行）
> - 一张支持线上支付的银行卡：租用 VPS 约 $4–6/月，购买域名约 $1–10/年
> - 3–5 小时专注时间。每章末尾都设有检查点，请确认全部通过后再进入下一章
>
> **你不需要具备**：任何运维经验。所有陌生概念在第一次出现时都会用大白话讲清楚。

**本册原则**：备份要演练、别把自己锁在门外、简单优先。

**约定**：
- **【本地】**表示在你自己电脑的终端里执行；**【服务器】**表示先通过 SSH 登录到服务器，再在服务器上执行。
- 教程中统一用 `203.0.113.10` 代表你的服务器公网 IP，用 `deploy-demo.example.com` 代表你的域名，用 `sam` 代表你的日常用户名——**实操时请全程替换成你自己的真实信息**。
- 如果代码块第一行带有 `# 文件: xxx` 注释，代表这是需要创建的完整文件内容。

---

## 第 0 章 术语速成班（10 分钟）

第一次部署应用时，拦住你的往往不是复杂的命令，而是满屏陌生的名词。这里用一句话把每个核心概念讲透：

| 术语 | 一句话解释 |
|---|---|
| VPS | 云厂商租给你的一台“远程电脑”，拥有独立的公网 IP 且 24 小时开机，也就是常说的“服务器” |
| SSH | 通过加密通道登录远程电脑并执行命令的方式，90% 的部署操作都要靠它完成 |
| 终端（Terminal） | 你电脑上用来敲命令的“黑窗口”；Mac 自带 Terminal，Windows 推荐使用 Windows Terminal |
| Linux 用户 | 服务器上的登录账号（如管理员 `root`、日常用户 `sam`），概念上和 Windows 的系统账户完全一样 |
| systemd | Linux 内置的“服务管理器”：负责让程序在后台常驻、开机自启、崩溃后自动拉起 |
| 服务（unit/service） | 被 systemd 托管的单个后台程序，配置文件形如 `demo-app.service` |
| 端口 | 服务器上从 1 到 65535 编号的“通信插座”。本教程会用到 22（SSH）、80（HTTP）、443（HTTPS）和 3000（应用） |
| Nginx | “反向代理”：站在你的应用前面迎客，负责处理 HTTPS 证书并将请求转发给后端应用 |
| DNS / A 记录 | 互联网的“电话簿”，负责把域名 `deploy-demo.example.com` 指向服务器 IP `203.0.113.10` |
| TLS / HTTPS | 给网站通信加上的“安全锁”。证书可由 Let's Encrypt 免费签发并自动续期 |
| 环境变量 | 程序运行时读取的外部配置（如数据库密码），通常保存在 `.env` 文件里，**永远不进 git** |
| 数据库迁移（migration） | 用来“修改数据库表结构”的版本化脚本，随代码一起提交，在每次部署时按序执行 |

读后文时如果遇到拿不准的词，随时翻回这张表对照即可。

---

## 第 1 章 一台属于你的服务器

### 1.1 买一台 VPS

主流云厂商都可以：Hetzner、DigitalOcean、Vultr、腾讯云轻量应用服务器、阿里云 ECS 任选其一即可。选购时按如下规格配置：

- **系统**：Ubuntu 24.04 LTS（本教程的所有命令均基于该版本验证）
- **配置**：选最低配即可（1 核 1GB 内存足够跑通 `demo-app`；如果计划做高级册的压测实验，建议选 2GB）
- **区域**：挑选离你或你的目标用户最近的机房

付款创建实例后，你会拿到两个关键信息：**公网 IP**（如 `203.0.113.10`）和 `root` 初始密码（部分厂商默认通过网页控制台或预设密钥登录）。

### 1.2 生成 SSH 密钥并第一次登录

**【本地】** 先检查本机是否已经有 SSH 密钥（如果已有就别重复生成）：

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ssh-keygen -t ed25519 -C "sam@laptop"
```

出现提示时一路按回车即可（教程练习阶段可将密钥口令留空，这样最省事；若是日常工作电脑，建议设置口令）。

> **为什么要用密钥**：SSH 密钥本质上是一对互相匹配的凭证文件。其中**私钥**（`id_ed25519`）相当于你家大门的钥匙，保存在你自己的电脑上，**绝不给任何人**；**公钥**（`.pub`）则相当于锁芯，需要放到服务器上。登录时，SSH 会用密钥完成加密签名来证明“我是我”，这比传统密码安全得多——密码可能被暴力猜解，而现代 SSH 密钥（如 `ed25519`）的加密强度在算力上根本猜不动。

你可以把公钥内容粘贴到云厂商控制台的“SSH 密钥”一栏（大部分厂商在创建服务器时都会提供这一选项），或者先使用 `root` 密码方案登录（下面第一次登录后再手动配置密钥）。

**【本地】** 发起第一次登录：

```bash
ssh root@203.0.113.10
```

首次连接一台陌生服务器时，终端会弹出如下确认信息：

```
The authenticity of host '203.0.113.10' can't be established.
ED25519 key fingerprint is SHA256:xxxxxxx...
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

> **这是什么**：服务器正在出示它自己的身份“指纹”，询问你“要记住我吗”。这种机制叫作 TOFU（Trust On First Use，首次使用即信任）。严谨的做法是先去云厂商控制台核对指纹完全一致后再回答 `yes`——**中级教程会讲到，一旦服务器指纹对不上，自动化部署必须直接失败退出**，这里先埋下一颗种子。

输入 `yes` 并回车。当命令行提示符变成 `root@ubuntu:~#` 时，说明你已经站在服务器里面了。**这个终端窗口千万别关**——在第 1.4 节修改 SSH 配置时，它是你的“保命通道”。

### 1.3 基础更新

**【服务器】**：

```bash
apt update && apt upgrade -y
timedatectl set-timezone Asia/Shanghai   # 换成你的时区
apt install -y unattended-upgrades && dpkg-reconfigure -f noninteractive unattended-upgrades
```

> `unattended-upgrades` 会让系统在后台自动安装安全补丁。对于平时没人专职值守的小服务器来说，这是最低限度的自我保护。

### 1.4 创建日常用户，关掉 root 登录

日常一直顶着 `root` 身份干活非常危险——手滑敲错一条命令就是整机级别的事故，“最小权限”原则首先要从管住自己开始。我们来创建一个日常操作用户 `sam`：

**【服务器】**：

```bash
adduser sam              # 设个密码,其他信息直接回车
usermod -aG sudo sam     # 把 sam 加进 sudo 组,需要 root 权限时用 sudo 临时提升
```

把你的公钥复制给 `sam`（假设你在 1.2 节的公钥已经配在了 `root` 账号下）：

```bash
mkdir -p /home/sam/.ssh && cp ~/.ssh/authorized_keys /home/sam/.ssh/ \
  && chown -R sam:sam /home/sam/.ssh && chmod 700 /home/sam/.ssh && chmod 600 /home/sam/.ssh/authorized_keys
```

**新开一个本地终端窗口**测试登录（**切记别关刚才那个 `root` 窗口**）：

**【本地】**：

```bash
ssh sam@203.0.113.10
sudo whoami             # 输入 sam 的密码,输出 root → sudo 正常
```

确认 `sam` 既能正常登录、又能执行 `sudo` 提权之后，就可以禁用 `root` 的 SSH 直接登录了：

**【服务器】**（在 `sam` 的窗口中执行）：

```bash
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sshd -t && echo CONFIG_OK     # 语法检查,输出 CONFIG_OK 才能继续!
sudo systemctl reload ssh
```

> ⚠️ **原则：不要把自己锁在门外**。刚才这三行命令，正是全世界运维锁死事故的经典来源。为此我们专门上了三道保险：
> 1. `sshd -t` 只检查配置语法，一旦检查不通过，后面的 `reload` 根本不会执行；
> 2. 使用 `reload`（而不是 `restart`）不会掐断已建立的 SSH 连接，因此你的 `root` 老窗口依然连着；
> 3. 改完配置后，**务必在旧窗口保持登录的状态下测试新连接能否成功登录**。万一真的把 SSH 锁死了，云厂商控制台提供的网页终端（VNC）就是你最后的带外救急通道——趁现在就去控制台看一眼它的入口在哪里，免得真出事时现找。

✅ **检查点**：
- [ ] `ssh sam@203.0.113.10` 能正常登录
- [ ] `ssh root@203.0.113.10` 被拒绝（提示 `Permission denied`）
- [ ] 云厂商控制台的 VNC / 网页终端入口位置你已经找过并确认过了

### 1.5 防火墙（ufw）

**【服务器】**：

```bash
sudo ufw allow OpenSSH     # 先放行 22 端口!
sudo ufw allow 80/tcp      # HTTP
sudo ufw allow 443/tcp     # HTTPS
sudo ufw enable            # 顺序!先放行 SSH 再 enable,否则当场锁死自己
sudo ufw status
```

预期输出包含：

```
To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere
```

> 防火墙只对外开放这三个端口。应用本身监听的 3000 端口和数据库的 5432 端口**故意不对公网开放**——它们只应该被服务器本机的 Nginx 和应用进程访问。

✅ **检查点**：`sudo ufw status` 显示只开放了 22、80、443 三个端口；新开一个终端窗口依然能通过 SSH 登录进来。

---

## 第 2 章 认识 demo-app，在本地跑起来

### 2.1 拿到代码

本课程配套的教学示例应用就在你正在阅读的仓库里（`demo-app/` 目录）。先把它复制出来，作为你自己的第一个独立项目：

**【本地】**：

```bash
cp -r /path/to/deploy_tutorial/demo-app ~/Projects/demo-app
cd ~/Projects/demo-app
rm -rf node_modules        # 如果复制过来时带了依赖缓存
git init -b main
pnpm install               # 首次安装,同时生成 pnpm-lock.yaml
git add -A && git commit -m "demo-app v1: web + worker + migrations"
```

> **为什么 `pnpm-lock.yaml` 必须提交进仓库**：它锁定了“每一个依赖包的精确版本”。后续在服务器上执行 `pnpm install --frozen-lockfile` 时，会严格按照这份清单安装**一模一样**的版本——否则，“在我电脑上明明好好的，到服务器上就跑不起来”的经典悲剧迟早会重演（中级册会专门演练这一幕）。

应用的代码结构非常精简，每个文件都在 50 行以内，先混个脸熟：

```
demo-app/
├── src/
│   ├── server.js     # web 进程:/health/ready、/version、/api/notes...
│   ├── worker.js     # worker 进程:消费任务队列,SIGTERM 优雅退出
│   ├── migrate.js    # 数据库迁移器(advisory lock 防并发)
│   ├── config.js     # 配置校验(--check-config 入口)
│   └── db.js         # 数据库连接池
├── migrations/       # SQL 迁移文件
├── build.mjs         # "构建":复制到 dist/ 并注入版本号
├── docker-compose.yml# Postgres(只绑定 127.0.0.1)
└── deploy/           # 部署相关(本册只用其中 naive/ 部分)
```

### 2.2 本地跑一遍（可选但强烈建议）

这一步需要你本地装有 Docker（Mac 或 Windows 可安装 Docker Desktop 或 Rancher Desktop）。如果本地没有 Docker 也没关系，可以先跳过本节，直接去第 3 章在服务器上跑，回头有空再补上。

**【本地】**：

```bash
cp .env.example .env
# 编辑 .env:POSTGRES_PASSWORD=随手填一个(仅本地)
docker compose up -d db          # 只起数据库,绑定 127.0.0.1:5432
pnpm run migrate                 # 建表
pnpm run build
DATABASE_URL="postgres://demo_app:你刚才的密码@127.0.0.1:5432/demo_app" \
APP_ENV=dev STORAGE_DIR=$PWD/storage pnpm run dev
```

预期输出：

```
demo-app web listening on 127.0.0.1:3000 (version dev)
```

用浏览器打开 `http://localhost:3000`，同时另开一个终端窗口测试健康检查接口：

```bash
curl -s localhost:3000/health/ready
# {"ok":true,"db":true,"lastPingId":1,"notes":0}
```

返回结果中的 `"db":true` 说明应用已经实打实地往数据库里完成了一次写入校验。接着再试一次完整的业务链路（创建笔记 → 任务入队 → worker 消费处理）：

```bash
curl -s -X POST localhost:3000/api/notes -H 'content-type: application/json' -d '{"title":"hello"}'
# {"note":{...},"jobId":1}
pnpm run worker          # 另一个终端启动 worker,几秒后 Ctrl-C
curl -s localhost:3000/api/jobs/1
# {"id":"1",...,"status":"done","result":{"shouted":"HELLO","length":5},...}
```

在本地把完整流程跑通之后，心里有了底，上服务器部署就不慌了。

### 2.3 推到你自己的 GitHub 仓库

**【本地】**：

```bash
gh repo create demo-app --private --source=. --push    # 装了 GitHub CLI 的话
# 或者:网页上新建空私有仓库 demo-app,然后:
# git remote add origin git@github.com:你的用户名/demo-app.git && git push -u origin main
```

✅ **检查点**：打开你 GitHub 上的私有仓库，能看到 `pnpm-lock.yaml` 和全部源码文件；同时 `.env` 文件**不在**仓库里（已被 `.gitignore` 挡在门外）。

---

## 第 3 章 服务器安家：Docker、Postgres、Node、代码

### 3.1 安装 Docker 和 Postgres

**【服务器】**：

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker sam
# 重新登录一次(exit 后再 ssh sam@...),让 docker 组生效
docker version          # 能打印版本就 OK
```

代码仓库里的 `docker-compose.yml` 负责拉起一个 Postgres 容器。请特别看一眼其中的关键配置行：

```yaml
ports:
  - "127.0.0.1:5432:5432"
```

> **为什么只绑定 `127.0.0.1`**：如果把容器端口映射写成 `"5432:5432"`，Docker 会默认监听服务器上的**所有网卡**，相当于绕过防火墙把数据库直接暴露到公网上（哪怕设了密码，也是完全不必要的受攻击面）。写成 `127.0.0.1:5432:5432` 之后，只有服务器本机才能连上数据库。这是新手用 Docker 部署服务时最常踩的安全坑之一。

数据库的初始化密码通过同目录下的 `.env` 文件传入（注意它和代码仓库里的 `.env.example` 模板是两码事，服务器上的 `.env` **永远不进 git**）。我们先创建应用目录：

```bash
cd /srv
sudo mkdir -p demo-app && sudo chown sam:sam demo-app && cd demo-app
# 先把代码弄进来(下一节),docker-compose.yml 就在仓库里
```

### 3.2 安装 Node 24 和 pnpm

**【服务器】**：

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
node -v          # v24.x.x
sudo npm install -g pnpm@11
pnpm -v
```

> 代码仓库里有一个 `.node-version` 文件，里面写着 `24.22.1`。中级册的部署脚本会自动校验“服务器当前的 Node 主版本号是否等于仓库声明的主版本号”——运行环境版本漂移，正是造成“本地好好的、服务器报错”的另一大根源。另外提一句：2026-10-21 Node.js 官方修复了 10 个 CVE 安全漏洞（包含可导致远程代码执行的 Brotli 解码漏洞），因此**锁定运行时版本时，永远要锁定到打过最新安全补丁的版本**（22 主线对应 `22.23.4`，本教程统一采用 Active LTS 的 `24.22.1`）。

### 3.3 创建运行应用的专用用户和拿代码

我们既不用日常账号 `sam`、更不用最高权限的 `root` 来跑应用，而是专门创建一个名为 `app` 的系统用户（最小权限原则：万一应用被攻破，攻击者拿到的也只是这个没有任何管理特权的受限身份）：

```bash
sudo useradd --system --create-home --shell /bin/bash app
```

接着给它配置一把 GitHub 的**只读部署密钥（deploy key）**——这把钥匙只能拉取代码、不能推送修改，就算不慎泄露，损失也完全可控：

```bash
sudo -u app mkdir -p /home/app/.ssh
sudo -u app ssh-keygen -t ed25519 -f /home/app/.ssh/id_ed25519 -N "" -C "app@server pull key"
sudo -u app cat /home/app/.ssh/id_ed25519.pub
# 把这串公钥贴到 GitHub:仓库 → Settings → Deploy keys → Add(不勾 write access)
sudo -u app ssh-keyscan -t ed25519 github.com >> /tmp/kh && sudo -u app tee -a /home/app/.ssh/known_hosts < /tmp/kh >/dev/null
```

> 上面的 `ssh-keyscan` 命令会把 GitHub 的主机密钥指纹**预先**记录到 `known_hosts` 中，这样稍后执行 `git clone` 时就不会卡在“要不要信任这个指纹”的交互式提问上了。

现在克隆代码并完成首次安装与构建（注意 `/srv/demo-app` 目录归 `app` 用户所有）：

```bash
sudo chown -R app:app /srv/demo-app
sudo -u app git clone git@github.com:你的用户名/demo-app.git /srv/demo-app
sudo -u app bash -c 'cd /srv/demo-app && pnpm install --frozen-lockfile && pnpm run build'
```

### 3.4 配置文件和数据库

接下来创建两份配置文件（作用和 2.2 节本地运行时的配置一样，只是换成了服务器上的标准路径与权限）：

**【服务器】** `# 文件: /srv/demo-app/.env`（供 Docker Compose 使用的数据库密码）：

```bash
cd /srv/demo-app
sudo -u app bash -c 'umask 077 && echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)" > .env'
sudo -u app grep -c PASSWORD .env    # 输出 1,确认写进去了(别 cat 出来,密码看一眼少一眼)
```

启动数据库容器：

```bash
sudo docker compose up -d db     # 注意:app 用户不在 docker 组里,直接 sudo
docker ps --format '{{.Names}} {{.Status}}'
# demo-app-db Up 2 minutes (healthy)
docker exec demo-app-db pg_isready -U demo_app
# accepting connections
```

**【服务器】** `# 文件: /srv/demo-app/runtime.env`（应用运行时配置，供稍后的 systemd 服务读取）：

```bash
PW=$(sudo -u app sed -n 's/^POSTGRES_PASSWORD=//p' .env)
sudo bash -c "umask 077 && cat > /srv/demo-app/runtime.env <<EOF
DATABASE_URL=postgres://demo_app:$PW@127.0.0.1:5432/demo_app
APP_ENV=production
STORAGE_DIR=/srv/demo-app/storage
PORT=3000
EOF"
sudo chown root:app /srv/demo-app/runtime.env && sudo chmod 0640 /srv/demo-app/runtime.env
```

> **为什么属主是 `root:app` 且权限设为 `0640`**：这份文件里保存着生产数据库的密码。`root:app 0640` 的意思是“只有 `root` 能读写、`app` 组成员只读、其他任何人免谈”——这样运行应用的 `app` 用户能够正常读取配置，而你日常登录的 `sam` 用户无法直接查看。到了中级册，我们还会让“就连专门负责部署的 `deploy` 用户也读不到这份密码”成为可验证的事实。

执行数据库迁移，创建表结构：

```bash
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && pnpm run migrate'
# migrate: applying 001_init.sql
# migrate: applying 002_add_status.sql
# migrate: applied 2 file(s), done
```

### 3.5 手动跑一次，然后看着它“死掉”

```bash
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && node dist/server.js'
# demo-app web listening on 127.0.0.1:3000 (version dev)
```

另开一个终端窗口登录服务器验证接口，然后切回第一个窗口按下 `Ctrl-C`：

```bash
curl -s localhost:3000/version
# {"gitSha":"dev"}
# Ctrl-C 之后再 curl → curl: (7) Failed to connect
```

**这正是本章要揭示的核心问题**：手动跑起来的进程是跟着你当前的终端会话走的，只要你的 SSH 连接一断开，或者顺手按下了 `Ctrl-C`，应用当场就没了。无论是 `nohup`、加 `&` 放后台，还是塞进 `tmux` 里，都只是临时凑合的创可贴——下一章，我们用 systemd 正面解决它。

✅ **检查点**：
- [ ] `docker ps` 里能看到 `demo-app-db` 的状态为 `healthy`
- [ ] 用 `sudo -u app` 能正常跑起 `dist/server.js`，且 `curl localhost:3000/health/ready` 返回 `"db":true`
- [ ] `/srv/demo-app/runtime.env` 的权限确认为 `-rw-r-----  root app`
- [ ] `ufw` 防火墙依然只开放了 22、80、443 三个端口

---

## 第 4 章 systemd：让应用永不缺席

### 4.1 写一个服务单元

**【服务器】** 创建 `# 文件: /etc/systemd/system/demo-app.service`：

```ini
[Unit]
Description=demo-app web (v0 naive)
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
User=app
Group=app
WorkingDirectory=/srv/demo-app
EnvironmentFile=/srv/demo-app/runtime.env
ExecStart=/usr/bin/node /srv/demo-app/dist/server.js
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

花两分钟逐行读懂它（以后你为自己的项目编写后台服务，无非就是改这几行）：

| 配置行 | 含义说明 |
|---|---|
| `Wants=/After=` | 声明启动顺序：期望在网络就绪且 Docker 服务启动之后再启动本服务（因为数据库跑在 Docker 里） |
| `User=app` | 指定以 `app` 用户身份运行进程，而不是 `root`（最小权限原则） |
| `EnvironmentFile=` | 启动进程前自动加载这份环境变量文件（就是上一节权限为 `0640` 的那个文件） |
| `ExecStart=` | 实际要执行的启动命令，**必须写绝对路径** |
| `Restart=always` | 无论进程因为什么原因挂掉（代码崩溃或被系统 OOM 杀掉），一律自动重新拉起 |
| `WantedBy=multi-user.target` | 声明“开机自启”所挂载的系统运行级别目标 |

加载配置并启用服务：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now demo-app
systemctl status demo-app --no-pager
```

预期能看到 `Active: active (running)`。接着测试健康检查接口：

```bash
curl -s localhost:3000/health/ready && echo
# {"ok":true,"db":true,...}
```

### 4.2 三件事证明它“永不缺席”

**🧪 实验 1：强行杀掉它**

```bash
sudo kill -9 $(systemctl show -p MainPID --value demo-app)
sleep 3 && systemctl is-active demo-app    # active —— 自动拉起了
```

**🧪 实验 2：查看日志**（systemd 已经替你把进程的 `stdout` 和 `stderr` 全都收集好了）：

```bash
journalctl -u demo-app -n 20 --no-pager    # 最近 20 行
journalctl -u demo-app -f                  # 实时滚动(Ctrl-C 退出,不影响服务)
```

> 从今往后，排查“应用怎么突然挂了”的第一反应就是敲：`journalctl -u 服务名 -n 100`。

**🧪 实验 3：重启整台服务器**

```bash
sudo reboot
# 等 1 分钟,本地重新 ssh 进去
curl -s localhost:3000/health/ready && echo
# {"ok":true,...} —— 开机自启成立,Postgres 也回来了
```

✅ **检查点**：以上三个实验的结果你都亲眼见证过了。从此以后，“线上应用到底在不在跑”这个问题有了标准答案：`systemctl is-active demo-app`。

---

## 第 5 章 Nginx + HTTPS：给应用一个正式的门牌

### 5.1 域名解析

登录你购买域名的服务商后台，添加一条 **A 记录**：

```
主机记录: deploy-demo     (即 deploy-demo.example.com 的前缀)
记录值:   203.0.113.10
```

**【本地】** 验证 DNS 解析是否生效（通常几分钟内即可生效）：

```bash
dig +short deploy-demo.example.com
# 203.0.113.10
```

### 5.2 Nginx 反向代理

**【服务器】**：

```bash
sudo apt install -y nginx
sudo tee /etc/nginx/sites-available/demo-app >/dev/null <<'EOF'
server {
    listen 80;
    server_name deploy-demo.example.com;   # 换成你的域名

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
sudo ln -sfn /etc/nginx/sites-available/demo-app /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

> **反向代理到底在干什么**：我们的应用只监听本机的 `127.0.0.1:3000`（公网流量根本连不进来），而由 Nginx 站在公网的 80 和 443 端口收下所有外部请求，再转发给本机应用。这样做的好处很明显：TLS 证书统一归 Nginx 管理、以后调整应用内部端口完全不用动域名、即便后端应用挂了，Nginx 至少还能给用户返回一个体面的错误页。

现在用浏览器访问 `http://deploy-demo.example.com`——你应该能看到 `demo-app` 的首页了。

### 5.3 上 HTTPS（Let's Encrypt）

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d deploy-demo.example.com
# 输入邮箱 → 同意条款 → 是否分享邮箱随意
# 选 Redirect(强制 HTTPS)
```

`certbot` 在背后替你干了三件大事，值得了解：第一，向 Let's Encrypt 证明你确实控制着这个域名（它会在本机放一个临时验证文件，让对方通过 80 端口访问核验）；第二，自动改写 Nginx 配置文件，挂上刚签发的证书并配置 HTTPS 跳转；第三，在系统里设置好自动续期的定时器。我们来验证一下续期机制：

```bash
sudo certbot renew --dry-run
# Congratulations, all simulated renewals succeeded
sudo systemctl list-timers | grep certbot
```

```bash
curl -sI https://deploy-demo.example.com | head -3
# HTTP/2 200 ...
```

> 如果手头暂时没有域名怎么办？请见文末附录 A。但请记住：**在生产环境里，HTTPS 绝不是可选项**。没有它，用户与服务器之间传输的所有明文流量（包括登录态 Cookie）在沿途任何网络中间人眼里都一览无余，随时可以被窃听或篡改。

✅ **检查点**：用浏览器打开 `https://deploy-demo.example.com` 时地址栏带有安全小锁图标；执行 `curl -I http://deploy-demo.example.com` 会收到 `301` 响应并自动跳转到 `https`。

---

## 第 6 章 备份与恢复演练：没演练过的备份等于没有

> 本章源于一条血泪教训：在 2017 年著名的 GitLab 生产删库事故中，团队事先准备的多套备份机制在关键时刻**全都不可用**。因此，本章的交付物不是一份“备份脚本”，而是一份“**你亲手用它恢复成功过的备份脚本**”。

### 6.1 写备份脚本

**【服务器】** `# 文件: /home/sam/backup-naive.sh`（内容与代码仓库中的 `deploy/naive/backup-naive.sh` 一致）：

```bash
#!/usr/bin/env bash
set -euo pipefail
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST=$HOME/backups/demo-app
mkdir -p "$DEST/db" "$DEST/storage"

echo "==> dumping database"
docker exec demo-app-db pg_dump -U demo_app --format=custom demo_app > "$DEST/db/$STAMP.dump"

echo "==> archiving file storage"
tar -czf "$DEST/storage/$STAMP.tar.gz" -C /srv/demo-app storage

echo "==> pruning: keep newest 14"
ls -1t "$DEST/db" | tail -n +15 | while read -r f; do rm -f "$DEST/db/$f"; done
ls -1t "$DEST/storage" | tail -n +15 | while read -r f; do rm -f "$DEST/storage/$f"; done

echo "==> latest:"
ls -lh "$DEST/db" | tail -3
```

这里有两个关键要点：
- `pg_dump --format=custom` 会生成经过压缩的二进制备份文件，恢复时配合 `pg_restore` 使用，还支持按需选择性恢复单张表；
- **备份范围里必须包含 `/srv/demo-app/storage`**（文件存储目录）。只备份数据库而漏掉磁盘文件，是最典型的备份盲区：真出事恢复完一看，数据库记录毫发无损，用户上传的文件却全没了。

赋予执行权限并手动跑一次：

```bash
chmod +x ~/backup-naive.sh && ~/backup-naive.sh
# ==> latest:
# -rw-r--r-- 1 sam sam 12K 2026-10-25 12:00 20261025T040000Z.dump
```

### 6.2 每天自动跑（cron）

```bash
crontab -e
# 在文件末尾加一行(每天服务器时间 03:17 执行;避开整点,减少撞车):
17 3 * * * /home/sam/backup-naive.sh >> /home/sam/backups/backup.log 2>&1
```

> `crontab` 时间表达式的五列依次是：分、时、日、月、周。明天早上起来执行 `ls ~/backups/demo-app/db`，能看到凌晨自动生成的新备份文件就算成功。

### 6.3 恢复演练（本章的灵魂）

🧪 **实验：假装线上灾难已经发生，现在要把数据库恢复到 5 分钟前的备份时间点。**

我们先往线上写入两条分属备份前后的测试数据：

```bash
curl -s -X POST https://deploy-demo.example.com/api/notes -H 'content-type: application/json' -d '{"title":"before backup"}'
~/backup-naive.sh
curl -s -X POST https://deploy-demo.example.com/api/notes -H 'content-type: application/json' -d '{"title":"after backup (should vanish)"}'
```

接着拉起一个**临时的**恢复演练用数据库容器（与线上生产库完全独立、互不相干）：

```bash
docker run -d --name restore-drill -e POSTGRES_PASSWORD=drill \
  -e POSTGRES_USER=drill -e POSTGRES_DB=drill postgres:16-alpine
LATEST=$(ls -1t ~/backups/demo-app/db | head -1)
docker cp ~/backups/demo-app/db/$LATEST restore-drill:/tmp/restore.dump
time docker exec restore-drill pg_restore -U drill -d drill --no-owner /tmp/restore.dump
```

对照演练库与生产库里的数据：

```bash
docker exec restore-drill psql -U drill -d drill -Atc "SELECT title FROM notes ORDER BY id"
# before backup          ← 备份之后写入的 "after backup" 不在,符合预期(RPO = 备份间隔)
docker exec demo-app-db psql -U demo_app -d demo_app -Atc "SELECT title FROM notes ORDER BY id"
# before backup
# after backup (should vanish)
docker rm -f restore-drill
```

**从这一刻起，有两个核心运维概念真正属于你了**（高级册还会带大家用实验严格测量它们）：

- **RPO**（Recovery Point Objective，恢复点目标）：灾难发生时最多能容忍丢失多久的数据。按你现在的每日备份方案，最坏情况下会丢掉 24 小时的数据。
- **RTO**（Recovery Time Objective，恢复时间目标）：从灾难发生到恢复服务需要多久。刚才 `time` 命令打印出的耗时，就是你亲手测得的第一手 RTO 数据——请把它记下来。

### 6.4 异地副本

如果备份文件和生产数据库放在同一台机器、同一块硬盘上，一旦机器故障就等于“火烧连营”。成本最低的异地容灾做法，就是定期把备份拉回你自己的电脑：

**【本地】** 把服务器上的备份同步回本机：

```bash
mkdir -p ~/demo-app-backups
rsync -av sam@203.0.113.10:backups/demo-app/ ~/demo-app-backups/
```

你同样可以把这条命令放进本机的定时任务里（Mac 用 `crontab -e`；Windows 用“任务计划程序”定期跑同一条命令）。更进阶的云端异地方案（对象存储 + `rclone`）将在高级册第 6 章介绍。

✅ **检查点**：
- [ ] 手动跑过一次备份脚本，`~/backups/demo-app/db` 目录下有 `.dump` 文件
- [ ] 完整做过一次恢复演练，确认备份后写入的 `"after backup"` 那条记录确实没有恢复出来（你要验证的正是这个证据）
- [ ] 服务器 `cron` 已配置妥当；你本地电脑上也同步了一份备份拷贝
- [ ] 你能脱口而出回答：我这套备份方案当前的 RPO 是多少？

---

## 第 7 章 第一条部署流水线：deploy-v0 与它的八宗罪

到现在为止，每次改完代码还得手动登录服务器敲一串命令更新。我们先把这套动作脚本化——然后再诚实地直面这份朴素脚本里的每一个缺陷。这八个问题，恰恰就是中级教程的章节目录。

### 7.1 v0 部署脚本

**【服务器】** `# 文件: /home/sam/deploy-naive.sh`（内容同代码仓库中的 `deploy/naive/deploy-naive.sh`）：

```bash
#!/usr/bin/env bash
set -e
cd /srv/demo-app
echo "==> pulling latest code"
sudo -u app git pull --ff-only origin main
echo "==> installing dependencies (on the PRODUCTION machine)"
sudo -u app pnpm install --frozen-lockfile
echo "==> building (on the PRODUCTION machine)"
sudo -u app pnpm run build
echo "==> migrating"
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && pnpm run migrate'
echo "==> restarting"
sudo systemctl restart demo-app
echo "deployed: $(sudo -u app git -C /srv/demo-app rev-parse --short HEAD)"
```

赋予可执行权限：

```bash
chmod +x ~/deploy-naive.sh
```

### 7.2 全流程体验一次

**【本地】** 改一行代码并推送到仓库，走一遍完整发版流程：

```bash
cd ~/Projects/demo-app
sed -i '' 's/<h1>demo-app<\/h1>/<h1>demo-app v2<\/h1>/' src/server.js   # Mac;Linux 用 sed -i
git commit -am "v2: change title" && git push
```

**【服务器】**：

```bash
~/deploy-naive.sh && curl -s https://deploy-demo.example.com | grep h1
# <h1>demo-app v2</h1>
```

恭喜，你已经拥有了第一条部署流水线！现在，诚实面对问题的时刻到了。

### 7.3 八宗罪审判

**🧪 罪状 #1：停机窗口。** 在部署脚本执行 `systemctl restart` 期间，到达服务器的请求是会直接失败的。我们来亲手把它测出来：

**【本地】** 一边以 0.2 秒的间隔狂发请求，一边在服务器上触发部署：

```bash
while true; do
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://deploy-demo.example.com/health/ready || echo FAIL
  sleep 0.2
done
```

**【服务器】** 在另一个终端窗口运行 `~/deploy-naive.sh`，同时观察本地终端的输出。你会看到若干行 `000 ...s` 或 `FAIL`——那就是用户视角下的“网站挂了”。**请记下连续失败持续的时长**（通常在几百毫秒到几秒之间）。中级册会通过软链原子切换大幅缩短这个窗口，而高级册的蓝绿部署实验会把它进一步压到接近于零。

**🧪 罪状 #2：构建在生产机上。** `pnpm install` 和 `pnpm run build` 直接跑在正在为用户服务的生产机器上：不仅会争抢 CPU 与内存（在小规格机器上足以让线上响应延迟肉眼可见地变差），而且**一旦断网就彻底无法部署**。不妨亲手试试（注意我们的 Git `origin` 是 SSH 形式，走 22 端口，因此要把 22 和 443 两条出站规则都堵上；不用担心你现有的 SSH 会话断掉——`iptables` 的 `OUTPUT` 规则只拦截“新建”的出站连接）：

```bash
sudo iptables -A OUTPUT -p tcp --dport 22 -j DROP    # git@github.com 走这里
sudo iptables -A OUTPUT -p tcp --dport 443 -j DROP
~/deploy-naive.sh        # 预期:git pull 阶段直接失败
sudo iptables -D OUTPUT -p tcp --dport 22 -j DROP    # 测完记得删掉这两条
sudo iptables -D OUTPUT -p tcp --dport 443 -j DROP
```

**🧪 罪状 #3：半成品状态。** 假设 `build` 步骤中途失败（比如你在本地故意写个语法错误推上去）：虽然 `set -e` 会让脚本停下来，但请留意——**如果失败恰好发生在 `migrate` 之后、`restart` 之前**，此时数据库已经是新表结构（schema），而线上跑的却还是旧代码。刚才没出事，纯属运气好。

**🧪 罪状 #4：没有健康检查。** 脚本跑完最后一行就径直宣布部署成功了。至于新版本进程到底起没起来、`/health/ready` 接口通不通，完全没人知道。在真实世界里，进程重启后 30 秒内因为内存溢出（OOM）或缺少环境变量而崩溃的案例数不胜数。

**🧪 罪状 #5：回滚靠手速。** 新版本上线后挂了怎么办？你只能手忙脚乱地执行 `git reset`、重新 `build`、再 `restart`，而且此时旧版本的构建产物很可能已经被覆盖清掉了。**回滚应当是一条和部署一样顺手的一等公民命令**（即中级册的 `rollback.sh`）。

**🧪 罪状 #6：权限过大。** 这个脚本以 `sam` 身份运行，而 `sam` 拥有完整的 `sudo` 权限。然而部署逻辑在理论上只需要“重启一个服务、跑一次数据库迁移、做一次备份”——最小权限原则要求我们把部署通道的权限严格收窄到这几个动作之内。

**🧪 罪状 #7：没有记录。** 究竟是谁、在什么时候、部署了哪个版本、结果成功还是失败？现在全靠去翻个人的 shell 历史记录，谈不上任何可审计性。

**🧪 罪状 #8：代码与迁移的错配窗口。** 脚本里的顺序是 `migrate → restart`：在迁移执行完成之后、新代码启动完成之前，线上实际上处于**“旧代码 + 新数据库”**的混跑状态。大多数只增不减的兼容式迁移（additive migration）还能相安无事，但一旦遇到破坏性迁移，就会当场打死正在运行的旧代码（这也是回滚安全的核心痛点）。正确的两阶段演进姿势（expand/contract）将在高级册第 6 章详解。

### 7.4 初级册总结

走到这里，你已经拥有了一套**能够日常使用**的上线流程，外加一份诚实的问题清单。接下来的中级教程，会把这“八宗罪”逐一变成严谨的工程方案：

| 罪状 | 中级册的解法 |
|---|---|
| #1 停机窗口 | `releases/<sha>` 目录 + `current` 软链原子切换（窗口缩小到 `restart` 一瞬） |
| #2 生产机构建 | （先保留，高级册做完对比实验后再用数据决策） |
| #3 半成品 | 先构建到 `.partial` 临时目录，全部检验成功才原子提升为正式 release |
| #4 无健康检查 | 断言 `/version` == 目标 SHA + 数据库读写 + worker 心跳 + soak 观察窗口 |
| #5 回滚靠手速 | `rollback.sh`：一等公民命令，秒级切换且不依赖外网 |
| #6 权限过大 | 专用 `deploy` 用户 + SSH 强制命令 + `sudoers` 白名单 |
| #7 无记录 | `audit.log`：每次部署自动记录一行（谁/何时/SHA/结果/耗时） |
| #8 错配窗口 | 迁移失败则代码绝不切换；破坏性变更严格按 expand/contract 两阶段执行 |

✅ **毕业检查点**：
- [ ] 能不查文档直接说出 `systemctl status`、`journalctl -u`、`ufw status` 的用途
- [ ] 完成过一次完整的恢复演练，并能说出自己当前方案的 RPO
- [ ] 亲手测过 v0 部署脚本的停机窗口，手头有实测数字
- [ ] 八宗罪里的每一条都能用自己的话讲上一遍

---

## 附录 A 没有域名怎么办

- **IP 直连 + 仅 HTTP**：直接跳过 `certbot` 那一节，Nginx 配置里的 `server_name` 写成 `_`。缺点：浏览器没有安全锁图标、全程明文传输、Cookie 裸奔。仅限临时体验。
- **sslip.io / nip.io**：访问 `203.0.113.10.sslip.io` 会自动解析到 `203.0.113.10`，完全零配置。非常适合用来练习 DNS 解析和证书签发，但由于共享域名存在触发 Let's Encrypt 限速的风险，**切勿用于生产环境**。
- **建议**：花 $2/年买一个真实域名，是最划算的学习投资。

## 附录 B 不想花钱：本地 VM 练习

使用 Multipass 只需三条命令，就能在本地拉起一台同款 Ubuntu 24.04 虚拟机：

```bash
brew install --cask multipass          # 或官方安装包
multipass launch --name lab --memory 2G --disk 10G 24.04
multipass shell lab                    # 效果等同 ssh,后续章节照做
multipass delete lab && multipass purge  # 用完销毁
```

局限性：本地虚拟机没有真实公网 IP → 第 5 章的 HTTPS 只能改用自签证书练习，而中级册的 GitHub Actions 真实部署链路需要改用“在宿主机上模拟 CI 的 `ssh` 调用”变体（具体方法见高级册附录 C）。**结论：学基础概念用本地 VM，学真实公网链路还是要有一台真 VPS。**

## 附录 C 迁移到你自己的应用

初级教程这套部署骨架是完全通用的，换成你自己的项目时，只需对照这张表过一遍：

| 换什么 | 在哪改 |
|---|---|
| 应用端口（3000） | `runtime.env` 里的 `PORT` + Nginx 配置里的 `proxy_pass` |
| “构建”命令（`pnpm run build`） | 产出可运行产物的任意命令（如 `go build`、`mvn package` 等） |
| 数据库（容器 Postgres） | 换 MySQL 或 SQLite 只是改 `docker-compose.yml` 和连接串的事；若没有数据库，直接删掉 `migrate` 相关步骤即可 |
| systemd 单元 | 改 `ExecStart` 那一行：Java 写 `java -jar app.jar`，Python 写 `.venv/bin/gunicorn ...` |
| 备份脚本 | 把 `pg_dump` 换成 `mysqldump` 或文件快照；**务必保留对 `storage` 目录的备份** |
| `/health/ready` | 强烈建议你的应用也提供该接口：检查关键依赖 + 执行一次真实读写 |

## 附录 D 常见报错速查

| 报错 | 原因 → 解法 |
|---|---|
| `Permission denied (publickey)` | 本地私钥与服务器公钥不配对，或传错了用户 → 用 `ssh -v` 查看它实际尝试了哪把钥匙 |
| `curl: (7) Failed to connect ... port 3000` | 应用进程没起来 → 检查 `systemctl status demo-app` 和 `journalctl -u demo-app -n 50` |
| `502 Bad Gateway`（Nginx 页面） | Nginx 活着但后端应用死了 → 排查方式同上，十有八九是应用进程崩了 |
| `EADDRINUSE` | 3000 端口被占用了 → 执行 `sudo ss -ltnp | grep 3000` 找到占位进程 |
| `password authentication failed for user "demo_app"` | `.env` 里的密码和 `runtime.env` 的 `DATABASE_URL` 不一致 → 对齐密码后执行 `docker compose up -d db` 重建（注意数据卷已存在时单改密码不会生效，可用 `docker compose down -v` 重来，**但 `docker compose down -v` 会删数据**） |
| `pnpm install` 报 lockfile 不匹配 | 本地改了 `package.json` 却没更新锁文件 → 在本地跑一次 `pnpm install` 后提交 `pnpm-lock.yaml` |
| 部署后页面还是旧的 | 构建产物没更新或浏览器缓存 → 在服务器跑 `curl -s 域名/version` 核对版本，并强制刷新浏览器 |
| `disk full` | 日志或备份把磁盘挤爆了 → 用 `df -h` 查看占用，执行 `journalctl --vacuum-size=200M` 清理日志，并清理 `~/backups` |

---

*下一册：[中级教程 —— 推送即部署，失败自动回滚](02-intermediate.md)*
