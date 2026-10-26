# 初级教程:一台服务器、一个域名、一条 HTTPS 网址

> **你会学到**:把自己写的一个 Web 应用(含数据库)放到一台真实的公网服务器上,让它 7×24 常驻运行、通过域名 + HTTPS 访问、每天自动备份(并且真的恢复过一次),最后用一条命令完成更新部署。
>
> **你需要**:
> - 一台自己的电脑(Windows/Mac/Linux 都行,能开终端)
> - 一张能网上支付的卡:VPS 约 $4–6/月 + 域名约 $1–10/年
> - 3–5 小时。每章末尾有检查点,全部通过再往下走
>
> **你不需要**:任何运维经验。所有概念第一次出现时都会解释。

**本册原则**(来自[设计文档](../../deploy-experiment-prompt.md)的 13 条业界原则,每章会标注涉及的条目):P5 备份要演练、P8 别把自己锁在门外、P13 简单优先。

**约定**:
- **【本地】** = 在你自己电脑的终端执行;**【服务器】** = 先 SSH 登录服务器,再执行。
- 教程用 `203.0.113.10` 代表你的服务器 IP,`deploy-demo.example.com` 代表你的域名,`sam` 代表你的日常用户名 —— **请全程替换成你自己的**。
- 代码块第一行是 `# 文件: xxx` 的,表示要创建的文件完整内容。

---

## 第 0 章 术语速成班(10 分钟)

第一次部署,拦住你的往往不是命令,而是名词。每个词一句话:

| 术语 | 一句话解释 |
|---|---|
| VPS | 云厂商租给你的一台"远程电脑",有公网 IP,24 小时开机,就是你的"服务器" |
| SSH | 加密地登录到远程电脑执行命令的方式,部署的 90% 都靠它 |
| 终端(Terminal) | 你电脑上那个"黑窗口",Mac 叫 Terminal,Windows 推荐 Windows Terminal |
| Linux 用户 | 服务器上的账号(如 `root`、`sam`),和 Windows 的账户一个意思 |
| systemd | Linux 的"服务管理器":让程序在后台常驻、开机自启、崩了自动拉起 |
| 服务(unit/service) | 被 systemd 管理的一个程序,如 `demo-app.service` |
| 端口 | 服务器上 65535 个"插座"编号。本教程会用到 22(SSH)、80(HTTP)、443(HTTPS)、3000(应用) |
| Nginx | "反向代理":站在你的应用前面,负责 HTTPS 证书和转发请求 |
| DNS / A 记录 | 把域名 `deploy-demo.example.com` 指到 IP `203.0.113.10` 的那本"电话簿" |
| TLS / HTTPS | 给网站加的"锁"。证书由 Let's Encrypt 免费签发,自动续期 |
| 环境变量 | 程序运行时读的配置(如数据库密码),放在 `.env` 文件里,**永远不进 git** |
| 数据库迁移(migration) | "改表结构"的版本化脚本,和代码一起提交,部署时执行 |

后文遇到不确定的词,回这张表查。

---

## 第 1 章 一台属于你的服务器

### 1.1 买一台 VPS

任何一家都行:Hetzner、DigitalOcean、Vultr、腾讯云轻量、阿里云 ECS。选择:

- **系统**:Ubuntu 24.04 LTS(本教程所有命令基于它)
- **配置**:最低配即可(1 核 1GB 内存够 demo-app 用;高级册压测实验建议 2GB)
- **区域**:离你用户近的

付款后你会得到:**公网 IP**(如 `203.0.113.10`)和 root 密码(有些厂商用网页控制台登录)。

### 1.2 生成 SSH 密钥并第一次登录

**【本地】** 检查是否已有密钥(有就别重复生成):

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ssh-keygen -t ed25519 -C "sam@laptop"
```

一路回车(口令可留空,教程阶段这样最省事;工作电脑建议设置口令)。

> **为什么**:SSH 密钥 = 一对文件。私钥(`id_ed25519`,相当于家门钥匙,**绝不给任何人**)放你电脑;公钥(`.pub`,相当于锁)放到服务器。登录时 SSH 用密钥证明"我是我",比密码安全得多——密码可以被猜,现代 SSH 密钥(如 ed25519)的强度实际上猜不动。

把公钥贴到厂商控制台的"SSH 密钥"栏(大部分厂商在创建服务器时让你贴),或者用 root 密码方案(下面第一次登录后手动配置)。

**【本地】** 第一次登录:

```bash
ssh root@203.0.113.10
```

第一次会看到:

```
The authenticity of host '203.0.113.10' can't be established.
ED25519 key fingerprint is SHA256:xxxxxxx...
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

> **这是什么**:服务器在出示自己的"指纹",问你"要记住吗"。这叫 TOFU(Trust On First Use,首次使用即信任)。正经做法是去厂商控制台核对指纹一致再答 yes——**中级教程会讲指纹对不上时部署必须直接失败**(原则 P7/A5 场景),这里先埋个种子。

输 `yes`。看到提示符变成 `root@ubuntu:~#`,你已经在服务器里了。**这个窗口别关**——第 1.4 节改 SSH 配置时,它是你的"保命通道"。

### 1.3 基础更新

**【服务器】**:

```bash
apt update && apt upgrade -y
timedatectl set-timezone Asia/Shanghai   # 换成你的时区
apt install -y unattended-upgrades && dpkg-reconfigure -f noninteractive unattended-upgrades
```

> `unattended-upgrades` 让安全补丁自动装上。小服务器没人值守,这是最低限度的自我保护。

### 1.4 创建日常用户,关掉 root 登录

一直用 root 干活很危险(手滑一条命令就是全机器级事故,原则 P7"最小权限"从你自己做起)。我们建一个日常用户 `sam`:

**【服务器】**:

```bash
adduser sam              # 设个密码,其他信息直接回车
usermod -aG sudo sam     # 把 sam 加进 sudo 组,需要 root 权限时用 sudo 临时提升
```

把你的公钥复制给 sam(如果你 1.2 的公钥已经在 root 手里):

```bash
mkdir -p /home/sam/.ssh && cp ~/.ssh/authorized_keys /home/sam/.ssh/ \
  && chown -R sam:sam /home/sam/.ssh && chmod 700 /home/sam/.ssh && chmod 600 /home/sam/.ssh/authorized_keys
```

**开一个新终端**测试(**别关 root 那个窗口**):

**【本地】**:

```bash
ssh sam@203.0.113.10
sudo whoami             # 输入 sam 的密码,输出 root → sudo 正常
```

确认 sam 能登录、能 sudo 之后,禁用 root 的 SSH 登录:

**【服务器】**(sam 窗口):

```bash
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sshd -t && echo CONFIG_OK     # 语法检查,输出 CONFIG_OK 才能继续!
sudo systemctl reload ssh
```

> ⚠️ **P8 原则:不要把自己锁在门外**。刚才这三行是全世界锁死事故的经典来源。三条保险:
> 1. `sshd -t` 只检查语法,检查不过就 `reload` 不执行;
> 2. `reload`(不是 `restart`)不会掐断现有连接,root 老窗口还连着;
> 3. 改完**先在旧窗口保持登录的状态下测试新登录**。真锁死了,还有厂商控制台的网页终端(VNC)这条带外通道——现在就去控制台看一眼它在哪里,真出事时不至于现找。

✅ **检查点**:
- [ ] `ssh sam@203.0.113.10` 能登录
- [ ] `ssh root@203.0.113.10` 被拒绝(`Permission denied`)
- [ ] 厂商控制台的 VNC/网页终端入口你已知道在哪

### 1.5 防火墙(ufw)

**【服务器】**:

```bash
sudo ufw allow OpenSSH     # 先放行 22 端口!
sudo ufw allow 80/tcp      # HTTP
sudo ufw allow 443/tcp     # HTTPS
sudo ufw enable            # 顺序!先放行 SSH 再 enable,否则当场锁死自己
sudo ufw status
```

预期输出包含:

```
To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere
```

> 只开这三个口。应用的 3000 端口、数据库的 5432 端口**故意不对公网开放**——它们只应该被本机的 Nginx / 应用访问。

✅ **检查点**:`sudo ufw status` 只有 22/80/443;新开一个终端还能 SSH 进来。

---

## 第 2 章 认识 demo-app,在本地跑起来

### 2.1 拿到代码

配套的示例应用就在你正在读的仓库里(`demo-app/` 目录)。把它复制成你自己的第一个项目:

**【本地】**:

```bash
cp -r /path/to/deploy_tutorial/demo-app ~/Projects/demo-app
cd ~/Projects/demo-app
rm -rf node_modules        # 如果复制过来时带了依赖缓存
git init -b main
pnpm install               # 首次安装,同时生成 pnpm-lock.yaml
git add -A && git commit -m "demo-app v1: web + worker + migrations"
```

> **`pnpm-lock.yaml` 为什么必须提交**:它锁定了"每个依赖的精确版本"。服务器上 `pnpm install --frozen-lockfile` 会按这份清单装**一模一样**的版本——否则"我电脑上好好的"和"服务器上跑不起来"的经典悲剧就会上演(中级册 C2 场景会专门演练它)。

应用长这样(先混个脸熟,每个文件 50 行以内):

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

### 2.2 本地跑一遍(可选但强烈建议)

需要本地有 Docker(Mac/Windows 装 Docker Desktop,或 Rancher Desktop)。没有?跳过这节,直接去服务器上跑,回头再补也行。

**【本地】**:

```bash
cp .env.example .env
# 编辑 .env:POSTGRES_PASSWORD=随手填一个(仅本地)
docker compose up -d db          # 只起数据库,绑定 127.0.0.1:5432
pnpm run migrate                 # 建表
pnpm run build
DATABASE_URL="postgres://demo_app:你刚才的密码@127.0.0.1:5432/demo_app" \
APP_ENV=dev STORAGE_DIR=$PWD/storage pnpm run dev
```

预期输出:

```
demo-app web listening on 127.0.0.1:3000 (version dev)
```

浏览器开 `http://localhost:3000`,再开个终端:

```bash
curl -s localhost:3000/health/ready
# {"ok":true,"db":true,"lastPingId":1,"notes":0}
```

`"db":true` 说明它真的写了一次数据库。再试一次完整链路(建笔记 → 入队 → worker 消费):

```bash
curl -s -X POST localhost:3000/api/notes -H 'content-type: application/json' -d '{"title":"hello"}'
# {"note":{...},"jobId":1}
pnpm run worker          # 另一个终端启动 worker,几秒后 Ctrl-C
curl -s localhost:3000/api/jobs/1
# {"id":"1",...,"status":"done","result":{"shouted":"HELLO","length":5},...}
```

本地通过了,上服务器就不慌了。

### 2.3 推到你自己的 GitHub 仓库

**【本地】**:

```bash
gh repo create demo-app --private --source=. --push    # 装了 GitHub CLI 的话
# 或者:网页上新建空私有仓库 demo-app,然后:
# git remote add origin git@github.com:你的用户名/demo-app.git && git push -u origin main
```

✅ **检查点**:GitHub 上你的私有仓库里能看到 `pnpm-lock.yaml` 和全部代码;`.env` **不在**仓库里(被 `.gitignore` 挡住了)。

---

## 第 3 章 服务器安家:Docker、Postgres、Node、代码

### 3.1 安装 Docker 和 Postgres

**【服务器】**:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker sam
# 重新登录一次(exit 后再 ssh sam@...),让 docker 组生效
docker version          # 能打印版本就 OK
```

仓库里的 `docker-compose.yml` 会起一个 Postgres。看一眼它的关键行:

```yaml
ports:
  - "127.0.0.1:5432:5432"
```

> **为什么只绑定 127.0.0.1**:容器端口映射写 `"5432:5432"` 会监听**所有网卡**,等于把数据库暴露到公网(哪怕有密码也是不必要的风险面)。写 `127.0.0.1:5432:5432` 后只有服务器本机能连。这是新手最常踩的安全坑之一。

数据库的密码用 `.env` 文件给(和代码里那个 `.env.example` 是两回事,服务器上这个**永远不进 git**):

```bash
cd /srv
sudo mkdir -p demo-app && sudo chown sam:sam demo-app && cd demo-app
# 先把代码弄进来(下一节),docker-compose.yml 就在仓库里
```

### 3.2 安装 Node 22 和 pnpm

**【服务器】**:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
node -v          # v22.x.x
sudo npm install -g pnpm@11
pnpm -v
```

> 仓库里有个 `.node-version` 文件写着 `22.20.0`。中级册的部署脚本会校验"服务器的 Node 主版本 == 仓库声明的主版本"——版本漂移是"本地好好的、服务器报错"的另一大来源(C2 场景)。

### 3.3 创建运行应用的专用用户和拿代码

不用 sam、更不用 root 跑应用,而是建一个专门的 `app` 用户(原则 P7:应用被攻破时,攻击者拿到的只是这个无特权身份):

```bash
sudo useradd --system --create-home --shell /bin/bash app
```

给它配一把 GitHub 的**只读 deploy key**(只能拉代码,不能推,泄露了损失可控):

```bash
sudo -u app mkdir -p /home/app/.ssh
sudo -u app ssh-keygen -t ed25519 -f /home/app/.ssh/id_ed25519 -N "" -C "app@server pull key"
sudo -u app cat /home/app/.ssh/id_ed25519.pub
# 把这串公钥贴到 GitHub:仓库 → Settings → Deploy keys → Add(不勾 write access)
sudo -u app ssh-keyscan -t ed25519 github.com >> /tmp/kh && sudo -u app tee -a /home/app/.ssh/known_hosts < /tmp/kh >/dev/null
```

> `ssh-keyscan` 是把 GitHub 的主机密钥**预先**记下来,这样稍后 `git clone` 不会卡在"要不要信任这个指纹"的交互问题上。

克隆代码(注意 `app` 用户拥有 `/srv/demo-app`):

```bash
sudo chown -R app:app /srv/demo-app
sudo -u app git clone git@github.com:你的用户名/demo-app.git /srv/demo-app
sudo -u app bash -c 'cd /srv/demo-app && pnpm install --frozen-lockfile && pnpm run build'
```

### 3.4 配置文件和数据库

创建两个文件(内容和 2.2 本地的一样,只是路径是服务器版的):

**【服务器】** `# 文件: /srv/demo-app/.env`(compose 用的数据库密码):

```bash
cd /srv/demo-app
sudo -u app bash -c 'umask 077 && echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)" > .env'
sudo -u app grep -c PASSWORD .env    # 输出 1,确认写进去了(别 cat 出来,密码看一眼少一眼)
```

启动数据库:

```bash
sudo docker compose up -d db     # 注意:app 用户不在 docker 组里,直接 sudo
docker ps --format '{{.Names}} {{.Status}}'
# demo-app-db Up 2 minutes (healthy)
docker exec demo-app-db pg_isready -U demo_app
# accepting connections
```

**【服务器】** `# 文件: /srv/demo-app/runtime.env`(应用配置,给 systemd 用):

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

> **为什么又是 root 又是 0640**:这个文件里有数据库密码。`root:app 0640` 意思是"root 能读写,app 组能读,其他人免谈"——应用(app 用户)读得到,而你日常的 sam 用户读不到。中级册会让"连负责部署的 deploy 用户也读不到"成为可验证的事实。

建表:

```bash
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && pnpm run migrate'
# migrate: applying 001_init.sql
# migrate: applying 002_add_status.sql
# migrate: applied 2 file(s), done
```

### 3.5 手动跑一次,然后看着它"死掉"

```bash
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && node dist/server.js'
# demo-app web listening on 127.0.0.1:3000 (version dev)
```

另开一个窗口验证,然后回到第一个窗口按 `Ctrl-C`:

```bash
curl -s localhost:3000/version
# {"gitSha":"dev"}
# Ctrl-C 之后再 curl → curl: (7) Failed to connect
```

**这就是本章的核心问题**:进程跟着你的终端活,你一断开/一按 Ctrl-C 它就没了。`nohup`、`&` 后台、`tmux` 都是创可贴——下一章用 systemd 正面解决。

✅ **检查点**:
- [ ] `docker ps` 里 `demo-app-db` 是 healthy
- [ ] `sudo -u app` 能跑起 `dist/server.js`,curl `/health/ready` 返回 `"db":true`
- [ ] `/srv/demo-app/runtime.env` 权限是 `-rw-r-----  root app`
- [ ] ufw 仍然只开 22/80/443

---

## 第 4 章 systemd:让应用永不缺席

### 4.1 写一个服务单元

**【服务器】** 创建 `# 文件: /etc/systemd/system/demo-app.service`:

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

逐行读懂它(以后你写自己的服务就是改这几行):

| 行 | 意思 |
|---|---|
| `Wants=/After=` | 期望在网络和 Docker 起来之后再启动(数据库在 Docker 里) |
| `User=app` | 用 app 身份跑,而不是 root(P7) |
| `EnvironmentFile=` | 启动前加载这份环境变量(就是上一步那个 0640 文件) |
| `ExecStart=` | 要执行的命令,**必须绝对路径** |
| `Restart=always` | 进程不管怎么挂(崩溃/OOM)都自动拉起 |
| `WantedBy=multi-user.target` | "开机自启"的挂载点 |

启用它:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now demo-app
systemctl status demo-app --no-pager
```

预期看到 `Active: active (running)`。测接口:

```bash
curl -s localhost:3000/health/ready && echo
# {"ok":true,"db":true,...}
```

### 4.2 三件事证明它"永不缺席"

**🧪 实验 1:杀掉它**

```bash
sudo kill -9 $(systemctl show -p MainPID --value demo-app)
sleep 3 && systemctl is-active demo-app    # active —— 自动拉起了
```

**🧪 实验 2:看日志**(systemd 替你收好了 stdout/stderr):

```bash
journalctl -u demo-app -n 20 --no-pager    # 最近 20 行
journalctl -u demo-app -f                  # 实时滚动(Ctrl-C 退出,不影响服务)
```

> 以后排查"应用怎么挂了",第一反应就是 `journalctl -u 服务名 -n 100`。

**🧪 实验 3:重启整台服务器**

```bash
sudo reboot
# 等 1 分钟,本地重新 ssh 进去
curl -s localhost:3000/health/ready && echo
# {"ok":true,...} —— 开机自启成立,Postgres 也回来了
```

✅ **检查点**:三个实验的结果你都亲眼看到了。从此"应用在不在跑"这个问题有了标准答案:`systemctl is-active demo-app`。

---

## 第 5 章 Nginx + HTTPS:给应用一个正式的门牌

### 5.1 域名解析

到你买域名的厂商后台,添加 **A 记录**:

```
主机记录: deploy-demo     (即 deploy-demo.example.com 的前缀)
记录值:   203.0.113.10
```

**【本地】** 验证解析生效(通常几分钟内):

```bash
dig +short deploy-demo.example.com
# 203.0.113.10
```

### 5.2 Nginx 反向代理

**【服务器】**:

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

> **反向代理在干嘛**:应用只听 `127.0.0.1:3000`(公网根本连不进来),Nginx 站在 80/443 端口收下所有请求,转给应用。好处:证书归 Nginx 管、以后换端口不动域名、应用挂了至少能返回个像样的错误页。

浏览器访问 `http://deploy-demo.example.com` —— 应该看到 demo-app 首页。

### 5.3 上 HTTPS(Let's Encrypt)

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d deploy-demo.example.com
# 输入邮箱 → 同意条款 → 是否分享邮箱随意
# 选 Redirect(强制 HTTPS)
```

`certbot` 做了三件事,值得知道:向 Let's Encrypt 证明你控制这个域名(它会让你放一个临时文件并通过 80 端口访问验证)、改写 Nginx 配置挂上证书、设置自动续期的定时器。验证续期:

```bash
sudo certbot renew --dry-run
# Congratulations, all simulated renewals succeeded
sudo systemctl list-timers | grep certbot
```

```bash
curl -sI https://deploy-demo.example.com | head -3
# HTTP/2 200 ...
```

> 没有域名怎么办?见附录 A。但**生产上 HTTPS 不是可选项**:没有它,用户到服务器之间的明文流量(包括登录态 cookie)任何中间人都看得见、改得了。

✅ **检查点**:`https://deploy-demo.example.com` 浏览器打开有小锁;`curl -I http://...` 会 301 到 https。

---

## 第 6 章 备份与恢复演练(P5:没演练过的备份等于没有)

> 本章源起一条血泪原则(P5):GitLab 2017 年丢库事故里,多套备份机制**全都不可用**。所以本章的产出不是"备份脚本",而是"**亲手恢复成功过的备份脚本**"。

### 6.1 写备份脚本

**【服务器】** `# 文件: /home/sam/backup-naive.sh`(内容和仓库 `deploy/naive/backup-naive.sh` 一致):

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

两个要点:
- `pg_dump --format=custom` 生成压缩的二进制备份,恢复时用 `pg_restore`,可以选择性恢复单张表;
- **备份里必须有 `/srv/demo-app/storage`**(文件存储)。只备数据库是 P5 里最典型的盲区:数据库毫发无损,用户上传的文件全没了。

```bash
chmod +x ~/backup-naive.sh && ~/backup-naive.sh
# ==> latest:
# -rw-r--r-- 1 sam sam 12K 2026-10-25 12:00 20261025T040000Z.dump
```

### 6.2 每天自动跑(cron)

```bash
crontab -e
# 在文件末尾加一行(每天服务器时间 03:17 执行;避开整点,减少撞车):
17 3 * * * /home/sam/backup-naive.sh >> /home/sam/backups/backup.log 2>&1
```

> `crontab` 的五列:分 时 日 月 周。明早起来 `ls ~/backups/demo-app/db` 能看到新文件就算数。

### 6.3 恢复演练(本章的灵魂)

🧪 **实验:假装灾难发生了,把数据库恢复到 5 分钟前。**

先制造一点数据:

```bash
curl -s -X POST https://deploy-demo.example.com/api/notes -H 'content-type: application/json' -d '{"title":"before backup"}'
~/backup-naive.sh
curl -s -X POST https://deploy-demo.example.com/api/notes -H 'content-type: application/json' -d '{"title":"after backup (should vanish)"}'
```

起一个**临时的**恢复用数据库(和生产库互不相干):

```bash
docker run -d --name restore-drill -e POSTGRES_PASSWORD=drill \
  -e POSTGRES_USER=drill -e POSTGRES_DB=drill postgres:16-alpine
LATEST=$(ls -1t ~/backups/demo-app/db | head -1)
docker cp ~/backups/demo-app/db/$LATEST restore-drill:/tmp/restore.dump
time docker exec restore-drill pg_restore -U drill -d drill --no-owner /tmp/restore.dump
```

对照数据:

```bash
docker exec restore-drill psql -U drill -d drill -Atc "SELECT title FROM notes ORDER BY id"
# before backup          ← 备份之后写入的 "after backup" 不在,符合预期(RPO = 备份间隔)
docker exec demo-app-db psql -U demo_app -d demo_app -Atc "SELECT title FROM notes ORDER BY id"
# before backup
# after backup (should vanish)
docker rm -f restore-drill
```

**两个从此刻起属于你的概念**(高级册会认认真真测它们):

- **RPO**(Recovery Point Objective):最多丢多久的数据。你现在的方案:每日备份 → 最坏丢 24 小时。
- **RTO**(Recovery Time Objective):多久能恢复。刚才 `time` 的输出就是你的第一手 RTO 数据——把它记下来。

### 6.4 异地副本

备份和数据库在同一台机器同一块盘上 = 火烧连营。最低成本的异地化:

**【本地】** 把备份拉回你自己电脑:

```bash
mkdir -p ~/demo-app-backups
rsync -av sam@203.0.113.10:backups/demo-app/ ~/demo-app-backups/
```

把它也放进本地的 crontab(Mac:`crontab -e`;Windows:任务计划程序跑同样命令)。进阶(对象存储 + rclone)见高级册第 6 章。

✅ **检查点**:
- [ ] 手动跑过备份,`~/backups/demo-app/db` 里有 `.dump` 文件
- [ ] 恢复演练完整做过一次,"after backup" 那条确实没恢复出来(你要的正是这个证据)
- [ ] cron 已配置;本地有一份拷贝
- [ ] 你能回答:我这套方案 RPO 是多少?

---

## 第 7 章 第一条部署流水线:deploy-v0 与它的八宗罪

现在改代码还得手动上服务器敲命令,我们把它脚本化——然后诚实地面对这个脚本的每个问题,它们正是中级教程的目录。

### 7.1 v0 部署脚本

**【服务器】** `# 文件: /home/sam/deploy-naive.sh`(内容同仓库 `deploy/naive/deploy-naive.sh`):

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

```bash
chmod +x ~/deploy-naive.sh
```

### 7.2 全流程体验一次

**【本地】** 改一行代码,走完整流程:

```bash
cd ~/Projects/demo-app
sed -i '' 's/<h1>demo-app<\/h1>/<h1>demo-app v2<\/h1>/' src/server.js   # Mac;Linux 用 sed -i
git commit -am "v2: change title" && git push
```

**【服务器】**:

```bash
~/deploy-naive.sh && curl -s https://deploy-demo.example.com | grep h1
# <h1>demo-app v2</h1>
```

恭喜,你有了一条部署流水线!现在,诚实的时刻到了。

### 7.3 八宗罪审判

**🧪 罪状 #1:停机窗口。** 部署的 `systemctl restart` 期间,请求是失败的。测出来:

**【本地】** 一边狂发请求一边部署:

```bash
while true; do
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://deploy-demo.example.com/health/ready || echo FAIL
  sleep 0.2
done
```

**【服务器】** 另一个终端跑 `~/deploy-naive.sh`,观察本地输出。你会看到若干 `000 ...s` 或 `FAIL` —— 那就是用户视角的"网站挂了"。**记下连续失败的时长**(通常几百毫秒到几秒)。中级册会做原子切换,高级册 D3 实验会用蓝绿把它压到接近零。

**🧪 罪状 #2:构建在生产机上。** `pnpm install` + `build` 跑在为用户服务的机器上:抢 CPU/内存(小机器上能让线上延迟肉眼可见地变差),且**断网就无法部署**。试试(注意 origin 是 SSH 形式走 22 端口,两条都要堵;已有 SSH 会话不受影响——iptables 的 OUTPUT 规则只拦"新建"的出站连接):

```bash
sudo iptables -A OUTPUT -p tcp --dport 22 -j DROP    # git@github.com 走这里
sudo iptables -A OUTPUT -p tcp --dport 443 -j DROP
~/deploy-naive.sh        # 预期:git pull 阶段直接失败
sudo iptables -D OUTPUT -p tcp --dport 22 -j DROP    # 测完记得删掉这两条
sudo iptables -D OUTPUT -p tcp --dport 443 -j DROP
```

**🧪 罪状 #3:半成品状态。** 假设 `build` 失败(本地故意写个语法错误推上去):`set -e` 让脚本停了,但注意——**如果失败发生在 migrate 之后 restart 之前**,数据库已是新 schema,跑的还是旧代码。现在没事,纯属运气。

**🧪 罪状 #4:没有健康检查。** 脚本跑完就宣布成功。新版本起没起来?`/health/ready` 通不通?没人知道。真实世界:重启后 30 秒内崩掉(OOM、缺环境变量)的案例数不胜数。

**🧪 罪状 #5:回滚靠手速。** 新版本挂了怎么办?`git reset` + 重新 build + 再 restart,全程手忙脚乱,而且旧版本很可能已经被清掉了。**回滚应该是和部署一样顺手的命令**(中级册 E7)。

**🧪 罪状 #6:权限过大。** 这个脚本以 sam 运行,sam 有完整 sudo。部署逻辑理论上只需要"重启一个服务、跑一次迁移、做一次备份"——最小权限(P7)要求把权限收窄到这几个动作。

**🧪 罪状 #7:没有记录。** 谁、什么时候、部署了哪个版本、结果如何?现在全靠翻 shell 历史(P10 可审计性)。

**🧪 罪状 #8:代码与迁移的错配窗口。** 顺序是 `migrate → restart`:迁移完成后、新代码启动前,是**旧代码 + 新数据库**的组合。大多数 additive 迁移没事,但破坏性迁移会当场打死旧代码(P2 回滚安全)。正确姿势(expand/contract)在高级册第 6 章。

### 7.4 初级册总结

你已经有了一套**能日常使用**的上线流程,以及一份诚实的问题清单。中级教程把八宗罪逐一变成工程方案:

| 罪状 | 中级册的解法 |
|---|---|
| #1 停机窗口 | `releases/<sha>` 目录 + `current` 软链原子切换(窗口缩小到 restart 一瞬) |
| #2 生产机构建 | (先保留,高级册 D1 对比后决策) |
| #3 半成品 | 先构建到 `.partial`,全部成功才提升为 release |
| #4 无健康检查 | 断言 `/version` == 目标 SHA + DB 读写 + worker 心跳 + soak 窗口 |
| #5 回滚靠手速 | `rollback.sh`:一等公民命令,不依赖外网 |
| #6 权限过大 | deploy 用户 + SSH 强制命令 + sudoers 白名单 |
| #7 无记录 | audit.log:每次部署一行(谁/何时/SHA/结果/耗时) |
| #8 错配窗口 | 迁移失败则代码不切换;破坏性变更按 expand/contract 两阶段 |

✅ **毕业检查点**:
- [ ] 能不查文档说出 `systemctl status / journalctl -u / ufw status` 的用途
- [ ] 完成过一次完整的恢复演练并能说出自己的 RPO
- [ ] 亲手测过 v0 的停机窗口,有数字
- [ ] 八宗罪每条都能用自己的话讲一遍

---

## 附录 A 没有域名怎么办

- **IP 直连 + 仅 HTTP**:`certbot` 那节跳过,`server_name` 写 `_`。缺点:没有锁标、明文、Cookie 裸奔。仅限临时体验。
- **sslip.io / nip.io**:`203.0.113.10.sslip.io` 会自动解析到 `203.0.113.10`,零配置。可以用来练习 DNS 和证书签发,但共享域有 Let's Encrypt 限速风险,**不要用于生产**。
- 建议:$2/年的域名是最划算的学习投资。

## 附录 B 不想花钱:本地 VM 练习

Multipass 三条命令起一台同款 Ubuntu:

```bash
brew install --cask multipass          # 或官方安装包
multipass launch --name lab --memory 2G --disk 10G 24.04
multipass shell lab                    # 效果等同 ssh,后续章节照做
multipass delete lab && multipass purge  # 用完销毁
```

局限:没有真实公网 IP → 第 5 章 HTTPS 只能自签证书练习,中级册的 GitHub Actions 真链路要用"在宿主机上模拟 CI 的 ssh 调用"变体(方法见高级册附录 C)。**结论:学概念用 VM,学真实链路还是要一台真 VPS。**

## 附录 C 迁移到你自己的应用

初级的骨架是通用的,换项目时过一遍这张表:

| 换什么 | 在哪 |
|---|---|
| 应用端口(3000) | `runtime.env` 的 `PORT` + Nginx `proxy_pass` |
| "构建"命令(`pnpm run build`) | 产出可运行产物的任意命令(`go build`、`mvn package`...) |
| 数据库(容器 Postgres) | 换 MySQL/SQLite 只是 compose 文件和连接串的事;没有 DB 就删掉 migrate 相关步骤 |
| systemd 单元 | `ExecStart` 一行;Java 写 `java -jar app.jar`,Python 写 `.venv/bin/gunicorn ...` |
| 备份脚本 | `pg_dump` 换成 `mysqldump`/文件快照;**storage 目录备份保留**(P5) |
| `/health/ready` | 强烈建议你的应用也提供:检查关键依赖 + 真实读写 |

## 附录 D 常见报错速查

| 报错 | 原因 → 解法 |
|---|---|
| `Permission denied (publickey)` | 本地私钥与服务器公钥不配对/没传对用户 → `ssh -v` 看它试了哪把钥匙 |
| `curl: (7) Failed to connect ... port 3000` | 应用没起 → `systemctl status demo-app`、`journalctl -u demo-app -n 50` |
| `502 Bad Gateway`(Nginx 页面) | Nginx 活着但后端死了 → 同上,十有八九是应用崩了 |
| `EADDRINUSE` | 3000 被占 → `sudo ss -ltnp | grep 3000` 找到占位进程 |
| `password authentication failed for user "demo_app"` | `.env` 里的密码和 `runtime.env` 的 `DATABASE_URL` 不一致 → 对齐后 `docker compose up -d db` 重建(数据卷已存在时改密码不会生效,`docker compose down -v` 可重来,**会删数据**) |
| `pnpm install` 报 lockfile 不匹配 | 本地改了 `package.json` 没更新锁 → 本地 `pnpm install` 后提交 `pnpm-lock.yaml` |
| 部署后页面还是旧的 | 构建产物没更新/浏览器缓存 → `curl -s 域名/version`;强刷浏览器 |
| `disk full` | 日志/备份挤爆 → `df -h`、`journalctl --vacuum-size=200M`、清 `~/backups` |

---

*下一册:[中级教程 —— 推送即部署,失败自动回滚](02-intermediate.md)*
