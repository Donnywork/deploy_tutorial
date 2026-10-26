# 高级教程：对比、量化与升级决策

> **你会学到**：通过对照实验回答四个真实的架构问题——在哪构建、怎么触发、如何切换流量、凭证怎么管；把备份从“应该能用”变成“有 RPO/RTO 实测数据的演练记录”；亲手在实验环境里制造部署事故（kill -9、断电重启、OOM）并观察系统如何自愈；最后，带走一份“什么时候才值得上 K8s”的诚实决策表。
>
> **前置**：中级册毕业（线上跑着 v1 管线），并且愿意折腾、破坏自己的实验服务器。**强烈建议**：按小时计费再开一台干净的 VPS 作为本册的实验机（做完即销毁，总花费通常 < $1），切勿在承载真实服务的机器上跑第 2/3/7 章的破坏性实验。
>
> **本册原则**：一次构建处处部署、回滚安全、备份要演练、控制爆炸半径、短寿命凭证、期望状态可对账、简单优先（包括知道何时**不**上工具）。

**方法论**：本册的每一节都是一场对照实验，统一采用以下固定格式：

```
假设:  我们相信 X(通常是参考设计或某条业界"常识")
步骤:  怎么做实验(命令)
观察:  应该看什么、怎么记录
结论:  X 成立/不成立;在什么条件下值得换方案(升级触发条件)
```

> 这套实验格式的铁律：**每一个结论都必须有证据支撑（命令、日志、退出码），而不是靠主观断言。** 每做完一个实验，请在自己的笔记里留下一行实测证据。

---

## 第 1 章 测量工具箱

没有数据支撑的架构讨论只是抬杠。在动手改造之前，我们先备好四个趁手的测量工具：

### 1.1 停机窗口测量（毫秒级）

**【本地】** `# 文件: measure-downtime.sh`

```bash
#!/usr/bin/env bash
# 以 50ms 间隔打请求,记录每次结果,最后统计连续失败窗口
URL="${1:-https://deploy-demo.example.com/health/ready}"
: > /tmp/downtime.tsv
while true; do
  t=$(date +%s%3N)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || echo 000)
  printf '%s\t%s\n' "$t" "$code" >> /tmp/downtime.tsv
  [ "$code" = "000" ] && echo "FAIL at $(date +%H:%M:%S.%3N)"
  sleep 0.05
done
# 停止后分析(Ctrl-C):
# awk -F'\t' '$2!="200"{print}' /tmp/downtime.tsv | head
# 首尾时间戳相减 = 停机窗口(毫秒)
```

> macOS 提示：`date +%s%3N` 是 GNU 扩展语法，macOS 自带的 BSD `date` 会直接输出字面字符 `N`。如果在 Mac 本地运行测量脚本，请先执行 `brew install coreutils`，再把脚本里的 `date` 替换为 `gdate`。

### 1.2 延迟与吞吐

```bash
# hey(Go 写的压测工具,brew install hey / apt 装不了就下 release)
hey -z 60s -c 10 https://deploy-demo.example.com/health/ready
# 盯三个数:平均延迟、p99、错误数。对比实验(第 2/3 章)前后各跑一次
```

### 1.3 RPO / RTO

- **RPO**（能容忍丢失多少数据）= 备份间隔 + 复制延迟。当前方案：v1 每日 `daily` 备份 + 每次部署前 `premigrate` 备份 → 最坏情况下丢失 24h 数据。
- **RTO**（能容忍服务中断多久）= 检测时间 + 恢复时间。第 6 章会实测“从备份完整恢复一台新机器”的端到端耗时。

### 1.4 实验记录表模板

每次实验只需记录五行，保存在仓库的 `docs/experiments.md` 中：

```
## E<编号> <名称> (日期)
假设:
步骤:
观察:   (贴关键日志/数字)
结论:
升级触发: (什么条件下该换方案 / 不换)
```

---

## 第 2 章 实验：重启窗口与蓝绿切换

### 2.1 基线：先量出 v1 的停机窗口

**假设**：中级册实现的“原子切换 + restart”仍然存在可观测的停机窗口（几十到几百毫秒）。

**步骤**：
1. **【本地】** 跑起 `measure-downtime.sh`；
2. **【服务器】** 触发一次部署（随便改个无关紧要的字符串并 push）；
3. 部署完成后按 Ctrl-C 停止探测，统计 `/tmp/downtime.tsv`。

**观察**：你会在日志里看到一串 `000`，以及两次 `200` 响应之间的空洞。典型数值在 **200–1500ms** 之间（取决于 systemd 停止旧进程时等待优雅退出的耗时，以及新进程的启动速度）。**请如实记录实测结果，不要声称零停机。** 在途请求的下场也清晰可见：优雅退出机制能让绝大多数已连接的请求顺利完成，但在重启瞬间正在建立的新连接会直接失败。

**结论**：v1 的停机窗口 = 旧进程停止 + 新进程启动 + 健康检查通过的时间。要想彻底消灭这个窗口，就必须让**新旧进程同时存活**——这就是蓝绿部署。

### 2.2 最小蓝绿：双槽位 + Nginx 切换

单机蓝绿部署根本不需要上 K8s，只需要三样东西：两个目录槽位、让 Nginx 记住“现在谁在台上”，以及一个切换脚本。

**布局改造**（在实验机上操作）：

```
/srv/demo-app/
├── releases/<sha>/          # 不变
├── blue  → releases/<shaA>  # 槽位软链
├── green → releases/<shaB>  # 槽位软链
└── current → blue           # 现在"谁在台上"
```

应用配置：蓝绿两个槽位各占一个端口（蓝槽使用 `PORT=3010`，绿槽使用 `3020`，分别由 `runtime.env.blue/green` 提供）。Nginx 配置相应改为：

```nginx
# /etc/nginx/sites-available/demo-app 的 location 换成:
location / {
    proxy_pass http://demo_backend;
    ...
}
# 文件顶部加:
upstream demo_backend {
    server 127.0.0.1:3010;   # 蓝(初始)
}
```

**切换脚本** `# 文件: /opt/demo-app/bin/switch-slot.sh`（核心逻辑 30 行）：

```bash
#!/usr/bin/env bash
# switch-slot.sh <sha> — 把新版本放到"台下槽位",健康通过后切 Nginx,再停旧槽
set -euo pipefail
. /opt/demo-app/bin/app.conf
SHA="${1:?sha}"; NEXT_PORT="${2:?3010|3020}"

# 1. 台下槽位指向新 release
# 注意用 readlink(不带 -f):current 的直接目标就是槽位名 blue/green,
# readlink -f 会一路解析到 releases/<sha>,导致永远选不中"在用槽位"
DEPLOYED=$(basename "$(readlink "$SRV_ROOT/current")")
[ "$DEPLOYED" = "blue" ] && NEXT=green || NEXT=blue
ln -sfn "releases/$SHA" "$SRV_ROOT/.slot.tmp" && mv -T "$SRV_ROOT/.slot.tmp" "$SRV_ROOT/$NEXT"

# 2. 起台下槽位的单元(需要 blue/green 两套 unit,EnvironmentFile 分别指向各自端口)
systemctl start "demo-app-web@$NEXT" "demo-app-worker@$NEXT"

# 3. 新槽位健康(healthcheck.sh 第 2 参数覆盖端口,检查"台下"的新版本)
/opt/demo-app/bin/healthcheck.sh "$SHA" "$NEXT_PORT"

# 4. 原子切 Nginx:改 upstream 文件 + reload(reload 不断连接)
sed -i "s/server 127.0.0.1:30[0-9]*;/server 127.0.0.1:$NEXT_PORT;/" \
  /etc/nginx/sites-available/demo-app
nginx -t && systemctl reload nginx
ln -sfn "$NEXT" "$SRV_ROOT/.cur.tmp" && mv -T "$SRV_ROOT/.cur.tmp" "$SRV_ROOT/current"

# 5. 观察窗口后停旧槽(soak 职责从 healthcheck 移到这里)
sleep 30
OLD=$([ "$NEXT" = blue ] && echo green || echo blue)
systemctl stop "demo-app-web@$OLD" "demo-app-worker@$OLD" || true
echo "switched to $NEXT ($SHA)"
```

（完整的模板化单元 `demo-app-web@.service`、两份 `runtime.env` 配置，以及把 `deploy.sh` 的第 12/13 步替换为本脚本的接线工作，留作本章练习。全部思路都来自中级册，只是从“管理一个 `current`”变成了“交替管理两个槽位”。）

### 2.3 测量与结论

**步骤**：重复 2.1 节的停机测量，但这次走蓝绿路径进行部署。

**观察**：`measure-downtime.sh` 的结果里**连一个 `000` 都没有**。Nginx 在 `reload` 时平滑切换了 upstream，存量旧连接继续由旧 worker 服务完毕。实测停机窗口 ≈ **0ms**（但也要诚实说明边界：数据库迁移仍然发生在切流之前；长连接与 WebSocket 需要额外设计；在 worker 新旧并存的 30 秒观察期内，队列任务可能被两边争抢——而中级册埋下的伏笔 `FOR UPDATE SKIP LOCKED` 恰好能保证任务不会被重复处理）。

**结论与升级触发**：

| 方案 | 停机窗口 | 复杂度代价 | 什么时候值得上 |
|---|---|---|---|
| v1 重启切换 | ~0.2–1.5s | 低 | 内部工具、流量小、用户能容忍“发布时刷新一下” |
| 单机蓝绿 | ≈0ms | +1 套槽位管理、运行内存翻倍 | 对外服务、有明确 SLA、单机内存装得下两份进程 |
| 多机滚动 / K8s | ≈0ms | 全套容器编排 | 机器多到手动管不动（见第 9 章） |

---

## 第 3 章 实验：在哪儿构建

**假设**：在生产服务器上直接构建存在三个问题：（a）消耗资源，拖累线上服务；（b）外网一断就无法部署；（c）两次构建的结果未必可复现。改为在 CI 中构建产物能一举修掉这三个问题，代价是需要维护一套产物分发基建。

### 3.1 基线：服务器构建的影响

**步骤**：
1. **【服务器】** 人为收紧资源：实验机本来就可以选小内存款（1GB）。
2. **【本地】** 跑起 `hey -z 120s -c 10` 持续施压，同时触发一次部署。
3. 记录部署期间 `hey` 的 p99 延迟和错误数；用 `free -m` 观察内存余量；如果触发了 OOM，执行 `journalctl -k | grep -i oom` 提取日志留存证据。

**观察**（1GB 机器上的典型结果）：在执行 `pnpm install` 与编译构建期间，p99 延迟明显上升（翻 2–5 倍）；内存吃紧时，Node 构建进程可能被内核 OOM 直接杀死 → **此时部署失败，但线上既有服务仍在正常跑**（多亏了 `.partial` 目录隔离）——请把这一条也记下来，它是 v1 管线设计的加分项。

### 3.2 CI 构建产物变体

在 GitHub Actions workflow 中新增一个 `package` 任务（核心改动如下）：

```yaml
package:
  needs: check
  if: github.ref == 'refs/heads/main'
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: pnpm/action-setup@v4
      with: { version: 11 }
    - uses: actions/setup-node@v4
      with: { node-version: 24, cache: pnpm }
    - run: pnpm install --frozen-lockfile && pnpm run build
      env: { GIT_SHA: ${{ github.sha }} }
    - run: tar -czf artifact.tar.gz dist migrations
    - run: sha256sum artifact.tar.gz | tee artifact.sha256
    - uses: actions/upload-artifact@v4
      with:
        name: release-${{ github.sha }}
        path: artifact.*
        retention-days: 14
```

服务器侧 `deploy.sh` 的第 6–8 步相应换成“下载产物 + 校验 `sha256` + 解包”（可以用 `gh run download` 或对象存储 URL）。**核心原则：一次构建，处处部署——CI 测过、打包出来的那份产物，和最终在线上跑的那份，是完完全全同一份字节。**

### 3.3 三个对照实验

| # | 实验 | 服务器构建（v1） | CI 产物 |
|---|---|---|---|
| 1 | 部署期间压测（同 3.1） | p99 明显劣化 | **无劣化**（服务器只做 `tar` 解包） |
| 2 | 断外网部署 | `git fetch` 直接失败；**但 `rollback.sh` 依然可用**（回滚不碰外网） | 只要产物已随部署通道传到本机，解包就不依赖外网；但传输通道本身仍需连通。**共同点：回滚永远离线可用** |
| 3 | 可复现性 | 同一 SHA 构建两次，`sha256` **不一致**（因为 `dist/version.json` 里塞了 `buildTime`！） | 同左；修复方法：去掉 `buildTime` 或用 `SOURCE_DATE_EPOCH` 固定构建时间戳，改完后同一 SHA 两次构建的 checksum 完全一致 |

**观察 3 的验证现场**：

```bash
# 服务器上对同一 SHA 构建两次,对比产物哈希
cd /srv/demo-app && sudo -u deploy bash -c \
  'cd /tmp && rm -rf r1 r2 && mkdir r1 r2
   for d in r1 r2; do (cd $d && git --git-dir=/srv/demo-app/repo.git archive <SHA> | tar -x \
     && env GIT_SHA=<SHA> pnpm install --frozen-lockfile >/dev/null 2>&1 && pnpm run build >/dev/null 2>&1); done
   find r1/dist -type f | sort | xargs sha256sum > 1.sums
   find r2/dist -type f | sort | xargs sha256sum > 2.sums
   diff 1.sums 2.sums && echo REPRODUCIBLE || echo NOT-REPRODUCIBLE'
# 预期:version.json 那一行不同 → NOT-REPRODUCIBLE。删掉 buildTime 后 → REPRODUCIBLE
```

**结论与升级触发**：

| 维度 | 服务器构建 | CI 构建 |
|---|---|---|
| 线上性能影响 | 有（与机器规格负相关） | 无 |
| 外网依赖 | `git fetch` + 语言包仓库 | 仅依赖产物传输通道 |
| 回滚速度 | `releases/` 里有现成旧版，秒级完成 | 同样秒级完成（`releases/` 目录结构不变） |
| 额外基建 | 零 | 产物存储 + 下载凭证管理 |
| **何时值得切换** | —— | 机器内存 ≤2GB / 多台服务器要部署同一份产物 / 有合规留档要求 / 语言包仓库连接不稳定 |

对于单机部署的 `demo-app` 而言，**维持现状不换同样合理**（简单优先）。但两条路径都亲手跑过之后，这是由你自己的实测数据支撑的决策，而不是人云亦云。

---

## 第 4 章 实验：推送（SSH）还是拉取（Poll）

**假设**：Push-SSH 模式必须开放入站 22 端口，使其长期暴露在全网扫描与暴力破解之下；Pull 模式（由服务器定时向 GitHub 轮询）可以把入站暴露面收敛到零，代价是引入轮询延迟，且需要自行解决失败可见性问题。

### 4.1 先看看 22 端口的世界

```bash
sudo journalctl -u ssh --since today | grep -c "Invalid user"   # 今天的爆破尝试数
# 一个开了几天的实验机,这个数字通常是几百到几万
sudo apt install -y fail2ban && sudo systemctl enable --now fail2ban   # 最低限度缓解
```

### 4.2 Pull 原型（30 行核心代码）

**复用的关键**：Pull 模式并不是一套新部署系统，它只是**换了一个调用者**。核心脚本 `deploy.sh` 连一个字都不用改。

`# 文件: /opt/demo-app/bin/poll.sh`（由 root 持有，通过 systemd timer 每 60s 执行一次）：

```bash
#!/usr/bin/env bash
# poll.sh — 查询 GitHub main 最新 SHA,与线上不同则触发 deploy.sh
set -euo pipefail
. /opt/demo-app/bin/app.conf
REPO="你的用户名/demo-app"
TOKEN_FILE="/opt/demo-app/env/poll.token"     # 只读 token,root:app 0640

CURRENT=$(basename "$(readlink "$SRV_ROOT/current")")
LATEST=$(curl -fsS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  "https://api.github.com/repos/$REPO/commits/main" | jq -r .sha)

if [ "$LATEST" = "$CURRENT" ]; then echo "up to date"; exit 0; fi
echo "drift detected: live=$CURRENT latest=$LATEST — deploying"
sudo -u deploy flock -n "$LOCK_FILE" /opt/demo-app/bin/deploy.sh "$LATEST" \
  || echo "deploy failed or locked (see audit.log)"
```

```ini
# /etc/systemd/system/demo-app-poll.service + .timer(每 60 秒)
[Unit]
Description=demo-app deploy poller
[Service]
Type=oneshot
ExecStart=/opt/demo-app/bin/poll.sh
```

```ini
[Unit]
Description=run demo-app poller every minute
[Timer]
OnCalendar=*:*:00
Persistent=true
[Install]
WantedBy=timers.target
```

启用定时器后，执行 `sudo ufw delete allow OpenSSH`（或者改为只放行你的固定 IP 段）——**入站 SSH 暴露面瞬间归零**，这就是 Pull 模式的全部安全收益。

### 4.3 对照结论

| 维度 | Push-SSH | Pull |
|---|---|---|
| 入站暴露面 | 22 端口（靠强制命令 + fail2ban 兜底） | **零**（仅开放 80/443） |
| 部署延迟 | 推送即触发（秒级） | ≤ 轮询间隔（60s） |
| 失败可见性 | GitHub Actions 页面直接变红 | 需要自己接日志与告警（见第 8 章） |
| 审计链路 | 由 CI 发起，触发链路清晰 | 由服务器自发拉起，`actor=poller` |
| 外部依赖 | GitHub Actions 正常 + 服务器公网可达 | 服务器出网能访问 GitHub |

**升级触发条件**：当机器数量 ≥2（不想由 CI 挨台推送）、安全合规要求“严禁开启任何管理入站端口”，或者公网爆破噪音大到令运维烦躁时 → 切换到 Pull；如果只是单机运行，且希望在 Actions 页面获得即时反馈 → 保持 Push。**两者共存也是一种常见且合理的形态**（平时用 Push 追求实时性，辅以 Pull 定时兜底对账，详见第 8 章）。

---

## 第 5 章 信任与凭证：短期证书、TOCTOU、glob 边界

### 5.1 静态密钥的爆炸半径 → 短期 SSH 证书

**假设**：CI 所持有的 SSH 私钥是长期静态的，一旦泄露，攻击面等于“可以触发任意 `main` 分支合法 SHA 的部署”；改用短期 SSH 证书能把凭证的有效期从“永久”压缩到“几分钟”。

**最小概念验证**（演示原理即可，单机不必急着上生产）：

```bash
# 1. 服务器上建一次 CA(root 保管 CA 私钥,永不离机)
sudo ssh-keygen -t ed25519 -f /etc/ssh/democa
# 2. sshd 信任这个 CA 签发的证书(/etc/ssh/sshd_config.d/ca.conf):
#      TrustedUserCAKeys /etc/ssh/democa.pub
#    并保留原有 authorized_keys 机制作为回退(先加新信任,再收旧信任)
sudo systemctl reload ssh
# 3. CI 每次部署现场签发 5 分钟证书:
#    -O clear -O force-command=... 至关重要:证书认证不读 authorized_keys,
#    没有它,5 分钟窗口内攻击者拿到的是 deploy 的完整 shell,而不是一次受控部署
ssh-keygen -t ed25519 -f key -N "" -C "ci-ephemeral"
ssh-keygen -s /etc/ssh/democa -I ci-deploy -n deploy -V +5m \
  -O clear -O force-command="/opt/demo-app/bin/deploy-entry" key.pub
ssh -i key -o CertificateFile=key-cert.pub deploy@host "deploy <sha>"
```

**观察**：5 分钟过后，同一把临时密钥即被服务器拒绝（`Permission denied`）。凭证泄露的爆炸半径从“永久有效”压缩到了“5 分钟窗口内的合法 SHA”——但前提是签发证书时必须同时带上 `force-command`：**有效期只管“能用多久”，强制命令才管“能干什么”**，两者缺一不可（一张只限制时长却没加 `force-command` 的证书，依然是一张直通完整 shell 的通行证）。

**结论**：对于单机小项目，“静态密钥 + 强制命令 + 审计日志”已经把爆炸半径控制得很小（引入并维护 CA 的运维成本大于收益，简单优先）；只有在**多机、多团队或合规审计场景**下，短期证书（或基于 OIDC 的动态凭证）才开始划算。升级触发条件：部署密钥需要分发给 >3 个 CI 仓库，或曾经发生过哪怕一次疑似泄露。

### 5.2 TOCTOU——构建者和运行者不是同一个人

**假设**：版本目录 `releases/<sha>` 由 `deploy` 用户构建，最终却由 `app` 用户执行。在“构建完成”到“服务重启切换”之间的时间窗口里，`deploy` 用户（或窃取了 `deploy` 身份的攻击者）能否篡改即将上线执行的代码？

**步骤**（在实验机上进行）：
1. 触发一次新版本部署，在健康检查通过**之前**手动模拟篡改：`sudo -u deploy sh -c 'echo "process.exit(99)" >> /srv/demo-app/releases/<sha>/dist/server.js'`
2. 观察部署结果：健康检查失败 → 自动回滚。篡改代码**没能**留在生产线上，但请特别注意：**当前这个 `<sha>` 对应的 release 目录已经被永久污染了**，而且 v1 管线没有任何机制能察觉“release 目录的实际内容已与 Git SHA 不符”。
3. 终极加固验证：在构建完成后立即将 release 目录执行 `chown -R root:root` 并设为只读（让 `deploy` 用户在构建结束那一刻交出写权限），同时让迁移包装脚本在执行 `runuser` 前校验目录属主。完成这项加固后再重跑步骤 1–2：篡改操作直接被内核以 `EPERM` 拦截。

**结论**：假设**证实**（v1 确实存在 TOCTOU 窗口），修复方案就是“构建完成后立即移交属主并降权为只读”。顺带一提同类的残余风险：`pnpm install` 过程中的 `postinstall` 钩子脚本是以 `deploy` 身份执行的，恶意第三方包可以借此读走 `repo.git` 所使用的 deploy key——最小缓解措施是确保 deploy key 仅具只读权限且易于随时轮换；彻底根治则是改用 CI 构建产物（见第 3 章，让生产服务器上根本不运行任何包管理器）。

### 5.3 sudoers glob 的边界输入

把中级册编写的 `sudoers` 规则当成靶场，测试极端输入：

```bash
sudo -u deploy sudo /opt/demo-app/bin/migrate-wrapper.sh "abc...40位... extra arg"
# 脚本内部: exactly one sha argument required → 第二层防线生效
sudo -u deploy sudo /opt/demo-app/bin/migrate-wrapper.sh "../../../../etc/passwd"
# 第一层:sudoers 的 [0-9a-f]* 直接拒(首字符 / 不在字符类里,到不了脚本);
# 第二层:假设绕过了 glob(例如带空格的参数),脚本内部的 case 再拒一次
```

**结论**：`sudoers` 的通配符挡住了路径穿越等非法字符，而脚本内部的参数校验又挡住了“通配符跨空格匹配多参数”的绕过手法——纵深防御绝不是一句空口号，而是两道彼此独立、各自生效的关卡。残余风险：`audit.sh` 规则末尾的 `*` 依然允许 `deploy` 用户往审计日志里灌水刷屏，其根治方案见第 8 章。

---

## 第 6 章 数据进阶：expand/contract、大表锁、RPO/RTO 实测

### 6.1 破坏性迁移的正确姿势

**假设**：像“删掉 `notes.body` 列”这类收缩（contract）操作，如果直接一步到位合并部署，一旦触发回滚就会立即炸膛（因为回退后的旧代码依然在 `SELECT` 这个已经被删掉的列）。采用“先扩展、再收缩（expand/contract）”的两阶段发布，才能保证在任何时刻回滚都是安全的。

**错误做法现场演示**（在实验机上操作，先亲眼看过事故现场，再学正确做法）：

```bash
# 直接删列 + 部署 → 然后手动 rollback.sh 回旧代码
# 旧代码 SELECT body → ERROR: column "body" does not exist → 500
# 你刚刚制造了"回滚不安全"的教科书案例
```

**正确姿势——把 003 迁移拆成两次独立发布**：

```
发布 1(expand):新增列/写双写/新代码兼容旧结构
  migrations/003_expand.sql:  ALTER TABLE notes ADD COLUMN content text;
                              UPDATE notes SET content = body;
  server.js 同时读写 body(旧)和 content(新)→ 部署,观察一周
发布 2(contract):确认不再回滚到更旧版本后
  migrations/004_contract.sql: ALTER TABLE notes DROP COLUMN body;
  server.js 只读写 content → 部署
```

**回滚安全矩阵**（请亲手验证一遍，在笔记中填入你的观察）：

| 组合状态 | 旧 schema + 新代码 | 新 schema（expand）+ 旧代码 | 新 schema（contract）+ 旧代码 |
|---|---|---|---|
| 运行结果 | ✅ 兼容（这正是 expand 阶段的意义） | ✅ 兼容（这正是双写过渡期的意义） | ❌ 崩溃（因此在执行 contract 前，必须确认绝不再回滚到旧版） |

### 6.2 大表迁移的锁

**步骤**：
1. 造一张包含 50 万行数据的表：`INSERT INTO notes(title) SELECT 'row'||g FROM generate_series(1,500000) g;`
2. 在实验窗口期内，开启另一个数据库连接持续 `UPDATE` 随机行（模拟线上真实写入流量）。
3. 对比以下两种建索引的方式：

```sql
-- A: 普通索引(锁表)
BEGIN; CREATE INDEX idx_slow ON notes(created_at); -- 观察另一个连接的写入:阻塞
-- B: 并发索引(不锁写)
CREATE INDEX CONCURRENTLY idx_fast ON notes(created_at); -- 写入继续
-- 配套:SET lock_timeout='3s' 让锁等待快速失败而不是排长队
```

**观察**：采用方案 A 建索引期间，线上写入请求全部被阻塞排队（可通过 `SELECT * FROM pg_stat_activity WHERE wait_event_type='Lock'` 实时看到）；采用方案 B 时，线上写入毫不受影响（代价是索引构建耗时更长，且不能包裹在事务块内执行）。

**结论**：面向生产环境的数据库迁移三件套——设置 `lock_timeout`、使用 `CONCURRENTLY` 并发操作、挑业务低峰期执行；而且只要遇到“我不确定这条迁移语句会不会锁表”的时刻，永远先在**恢复出来的副本库上干跑一遍**（见下一节）。

### 6.3 迁移干跑

```bash
# 1. 从最新备份恢复一个副本库(中级册第 6 章的流程)
# 2. 对副本库跑 --dry-run(列出将应用什么),再真跑一遍
DATABASE_URL=postgres://drill:drill@127.0.0.1:55432/drill node dist/migrate.js --dry-run
DATABASE_URL=postgres://drill:drill@127.0.0.1:55432/drill node dist/migrate.js
# 失败?→ 迁移有问题,正式库一根毛都没碰
```

把“正式迁移前先在临时副本库上演练一遍”做成 `deploy.sh` 的可选项（例如当 `MIGRATE_DRYRUN=true` 时启用），是许多成熟工程团队的标准操作。

### 6.4 备份 RPO/RTO 实测表

请在实验机上亲手测出以下各项并填满这张表（具体数字属于你的机器，但表格框架放之四海而皆准）：

| 测量项目 | 实测值 | 测量方法 |
|---|---|---|
| 备份文件大小（DB / storage） | ___ KB | `du -h` |
| 单次备份耗时 | ___ s | `time backup.sh manual` |
| 数据恢复耗时（导入空库） | ___ s | `time pg_restore`（见中级册第 6 章） |
| 全机重建 RTO（从零开机器到恢复线上服务） | ___ min | 结合附录 A/B 的灾难重建流程全程掐表计时 |
| RPO（`daily` 备份模式） | 最坏 24h | 由备份周期定义决定 |
| RPO（若升级为每小时归档 / WAL） | 最坏 1h | 见第 9 章的升级触发条件 |
| 异地副本同步延迟 | ___ | 取决于 `rsync` 定时任务的执行间隔 |

**GitLab 2017 年删库事故的最大教训**并不是“没配备份”，而是**从来没有验证过备份能不能恢复出来**。只有当你把上面这张表里的空格全部填上实测数字的那一刻，你的备份才算真正存在。

---

## 第 7 章 崩溃一致性实验室

在本章中，你将扮演一名专门搞破坏的 QA 工程师。所有实验的验收标准只有同一句话：**系统要么自动恢复，要么停在明确可恢复的干净状态；绝不留下半成品残骸，绝不破坏线上正在运行的服务。**

### 7.1 部署中途 kill -9

分别在部署流程的五个关键时点各执行一次强杀：构建中 / 备份后 / 迁移中 / 迁移后切换前 / 健康检查中。

```bash
# 【服务器】部署进行时,找到 deploy.sh 的 PID
ps aux | grep '[d]eploy.sh'
sudo kill -9 <pid>
```

**预期结果对照表**（请逐格动手验证）：

| 强杀时点 | 现场残留物 | 再次触发部署的结果 |
|---|---|---|
| 构建中 | `.partial/` 临时目录 | ✅ 自动清理残骸并重新构建 |
| 备份后 | 多出一份备份文件（完全无害） | ✅ 正常继续 |
| 迁移中 | 未完成的迁移因事务保护而整体回滚 | ✅ 重新执行迁移并继续 |
| 迁移后、切换前 | 数据库已是新结构，线上代码仍是旧版（在 expand 期完全安全） | ✅ 幂等跳过已跑完的迁移，完成后续切换 |
| 健康检查中 | `current` 软链已切向新版，但尚未走完确认流程 | ✅ 经幂等检查与健康检查后收敛至正常状态 |

### 7.2 整机重启

在部署跑到一半时直接执行 `sudo reboot`（挑“数据库迁移进行中”那个时点重启最刺激）。等机器重新开机后检查现场：Postgres 容器自动拉起、systemd 服务单元处于 `active` 状态、存放在 `/run`（`tmpfs` 内存文件系统）里的 `flock` 锁文件已随重启自动蒸发、`/srv/demo-app/current` 依然指向一致的可用版本。如果磁盘上留有 `.partial` 半成品目录，只需手动触发一次部署，观察管线如何自动清理并收敛。

### 7.3 磁盘将满

```bash
sudo fallocate -l $(( ($(df --output=avail -BM / | tail -1 | tr -dc 0-9) - 300))M /tmp/bigfile
# 用 -BM(MB)做算术:-BG 的整数 GB 相减常见机器上会得负数
# 留 ~300MB,触发部署 → 预检拒绝(不足 1GiB);rollback.sh 仍可用(不需要空间)
sudo rm /tmp/bigfile
```

### 7.4 部署冻结

```bash
sudo touch /opt/demo-app/freeze
# push 一个提交 → deploy job 日志: FAILED step=freeze
sudo rm /opt/demo-app/freeze
# audit.log 里两次"拒绝"都有据可查
```

### 7.5 脚本漂移检测

**假设**：有人修改了 Git 仓库里的 `deploy.sh`，却忘了在服务器上重新运行 `install.sh`；结果线上一直跑着旧版部署脚本，而且**没有任何机制能主动发现这种不一致**。

```bash
# 验证假设:仓库加一行注释,push,不重装 → 部署行为没变(旧脚本继续跑)→ 假设证实
# 修正:对账一条命令 —— 左边在 /opt 哈希"已安装的",右边在仓库目录校验"仓库里的"
# (注意:清单必须用文件名在目标目录校验,直接对 /opt 自查永远 OK)
cd ~/demo-app-bootstrap/deploy && \
sudo sh -c 'cd /opt/demo-app/bin && sha256sum app.conf deploy-entry deploy.sh healthcheck.sh \
  check-config.sh migrate-wrapper.sh backup.sh rollback.sh audit.sh' \
  | sha256sum -c - || echo "DRIFT: installed scripts differ from repo — run install.sh"
```

**结论**：漂移检测的本质就是“期望状态可对账”——“仓库里应该安装的脚本”与“服务器上实际运行的脚本”必须能够随时比对校验。顺便提醒：每次升级 `install.sh` 时，记得把指纹校验清单也一并更新（因为它自己也是被对账的对象之一）。

---

## 第 8 章 可观测与对账

### 8.1 期望状态对账（reconcile）

`# 文件: /opt/demo-app/bin/reconcile.sh`（可放入定时任务 cron，或由 `poll.sh` 顺带执行）：

```bash
#!/usr/bin/env bash
# 三方对账:GitHub main 期望 vs 线上实际 vs 安装脚本指纹
set -euo pipefail
. /opt/demo-app/bin/app.conf
REPO="你的用户名/demo-app"
LIVE=$(basename "$(readlink "$SRV_ROOT/current")")
LATEST=$(curl -fsS "https://api.github.com/repos/$REPO/commits/main" | jq -r .sha)
DRIFT_SCRIPTS=$( cd "${REPO_DEPLOY_DIR:-$HOME/demo-app-bootstrap}/deploy" 2>/dev/null && \
  sudo sh -c 'cd /opt/demo-app/bin && sha256sum app.conf deploy-entry deploy.sh healthcheck.sh \
    check-config.sh migrate-wrapper.sh backup.sh rollback.sh audit.sh' 2>/dev/null \
  | sha256sum -c - 2>/dev/null | grep -cv OK || echo unknown )
# 注:从 root 的 cron 跑时,先 export REPO_DEPLOY_DIR 指向仓库位置
printf 'live=%s\nlatest=%s\nscripts_drift=%s\n' "${LIVE:0:12}" "${LATEST:0:12}" "$DRIFT_SCRIPTS"
[ "$LIVE" = "$LATEST" ] || echo "⚠️  live is behind main"
[ "$DRIFT_SCRIPTS" = "0" ] || echo "⚠️  installed deploy scripts differ from repo"
```

### 8.2 失败通知

成本最低的起步方案：接一个 Webhook（或者哪怕只是写进本机汇总文件，只要是你每天真正会看的地方就行）：

```bash
# deploy.sh 的 die() 里已经写 audit.log;再加一步:
curl -fsS -m 3 "$NOTIFY_WEBHOOK" -d "deploy failed: sha=$SHA step=$step" >/dev/null 2>&1 || true
# NOTIFY_WEBHOOK 指向 Slack/飞书/Telegram 的 incoming webhook,或本机的一个文件收集服务
```

> 请注意末尾的 `|| true`：告警通知发送失败，绝不能反过来把部署流程本身弄挂（通知只是旁路信号，不是主链路）。

### 8.3 部署系统自身的变更管控

部署脚本、`sudoers` 配置以及 CI workflow，都是“一旦改错就会直接改变生产环境行为”的高危文件，必须纳入严格管控：

1. **配置 CODEOWNERS**（在仓库中创建 `.github/CODEOWNERS`）：

```
/deploy/          @你的团队/ops
.github/workflows/ @你的团队/ops
```

2. **为部署脚本加上 CI 自检**（加在 `ci.yml` 的 `check` 任务中）：

```yaml
- run: sudo apt-get install -y shellcheck && shellcheck deploy/*.sh
- run: bash -n deploy/deploy-entry
- run: sudo visudo -cf deploy/demo-app.sudoers
```

3. **审计日志防注水**（对应 5.3 节留下的残余风险）：`audit.sh` 已经在通过 `logger` 同步写入系统日志 `syslog`，只需配置 rsyslog/journald 将日志实时转发到**另一台独立机器**上集中收集——`deploy` 用户权限再大，也改不了另一台机器上的历史日志。

---

## 第 9 章 升级决策记录（ADR）

下面每一项演进方案都浓缩为“一句话结论 + 量化触发条件”。**只要还没触及触发条件，就不要提前引入**——这正是“简单优先”原则在日常工程中的落脚点。

| 架构决策 | 升级触发条件（满足任意一条再考虑引入） | 未满足条件时的替代方案 |
|---|---|---|
| **CI 构建产物** | 服务器内存 ≤2GB / 机器数量 ≥2 台 / 有合规留档要求 | 在服务器上直接构建（v1 现状） |
| **Pull 模式部署** | 机器数量 ≥2 台 / 合规要求严禁入站 SSH / 公网爆破噪音失控 | Push-SSH + fail2ban + 强制命令 |
| **蓝绿切换** | 对外承诺了严格 SLA / 停机窗口曾被真实用户抱怨过 | 软链原子切换 + 业务低峰期部署 |
| **短期证书 / OIDC** | 密钥需分发给 >3 处使用方 / 发生过疑似泄露 / 多团队共用 CI | 静态密钥 + 审计日志 + 快速轮换预案 |
| **每日 → 每小时备份 / WAL 归档** | 业务无法承受 24h RPO（如有真实交易或高频用户数据） | 每日定时备份 + 每次部署前备份 |
| **对象存储异地备份**（`rclone` 定时同步至 S3/R2） | **立即启用**（存储成本几乎为零，却能兜底机房级火灾/删机事故） | 定时 `rsync` 拉取到个人笔记本（最低限度兜底） |
| **Ansible** | 同样的手动配机命令已经在 >5 台机器上反复复制粘贴过 | 本教程提供的 `install.sh` 引导脚本 |
| **Terraform** | 云资源种类 >3 种且架构频繁变动 | 手动在控制台创建 + 文档记录 |
| **Docker 镜像 + Registry** | 已采用 CI 构建产物，且需要向多台机器高效分发时的自然演进 | `tar.gz` 压缩包产物 |
| **Kubernetes** | 机器规模 >10 台 / 微服务 >15 个 / 团队有专职平台工程人力 / 业务确实需要频繁弹性伸缩 | 单机 systemd + 本教程的部署管线 |

> 请细品 Kubernetes 那一行的潜台词：它擅长解决的那些问题（大规模多机编排、跨节点自愈、自动弹性伸缩），在你只有 3 台机器、2 个服务的时候**根本就不存在**；而它附带引入的复杂度（集群自身升级运维、证书与权限体系、容器网络模型），却会从你接入的第一天起就实打实地压在肩上。永远先让真实的业务痛点出现，再请对应的工具进场。

---

## 第 10 章 场景矩阵练习册

本章汇总了全课程的故障与攻防场景矩阵。图例说明：✅ = 初、中级册已经亲手做过；🧪 = 本章留给你的动手练习（附有操作提示）；⭐ = 需要依赖真实公网环境或真实 GitHub Actions 才能复现的“层 2”验证项（表中已注明验证方法）。

### 权限与信任

| 场景 | 状态 / 练习提示 |
|---|---|
| 强制命令滥用矩阵 | ✅ 中级 3.5 |
| `deploy` 用户越权尝试（改密钥 / 改脚本 / 读环境变量 / 执行非白名单 `sudo`） | ✅ 中级 3.5/4；补充练习：尝试执行 `sudo -u deploy vi /opt/demo-app/bin/deploy.sh` |
| 恶意构建（利用 `postinstall` 提权或窃取密钥） | 🧪 在 `package.json` 中加入 `"postinstall": "cat /home/deploy/.ssh/id_ed25519"` → 推送触发构建 → 检查构建日志里是否印出了私钥全文（真的会印出来！→ 这就是残余风险；修复方法 = 改用 CI 构建产物，或加上 `pnpm install --ignore-scripts`） |
| TOCTOU 窗口与 `sudoers` 通配符边界 | ✅ 高级 5.2/5.3 |
| 主机指纹不匹配时部署必须立即失败 | 🧪 把 GitHub Secret `DEPLOY_KNOWN_HOSTS` 里的公钥故意改错一个字符 → 触发部署应立即报错 `REMOTE HOST IDENTIFICATION HAS CHANGED` 并终止 |
| 日志中严禁泄露敏感凭证 | 🧪 执行 `grep -r PASSWORD /var/log/demo-app/` 应当没有任何输出（包括故意制造构建失败时的错误日志） |
| `sshd` 锁死恢复演练 | 见附录 B |

### 来源、并发与崩溃一致性

| 场景 | 状态 |
|---|---|
| 拒绝已被 `force-push` 覆盖的幽灵 SHA | ✅ 中级 3.5（全 0 SHA 测试） |
| 跳过旧版本 / 重复部署幂等性 | ✅ 中级 9.8 |
| `flock` 锁与 Actions `concurrency` 的职责分工 | ✅ 中级 7.1/9.8 |
| 连续快速推送 3 个 commit 时的排队行为 | ⭐ 真实 Actions 环境观察：队列中等待的中间旧任务会被最新任务直接替换；以及 runner 超时断开但服务器端继续执行完毕（✅ 中级 9.8 已验证） |
| SSH 中途断线但部署依然平稳完成 | ✅ 中级 9.8 |
| 五个关键时点的 `kill -9` 强杀测试 | ✅ 高级 7.1 |
| 部署进行中整机断电重启 | ✅ 高级 7.2 |

### 构建与工具链

代码构建失败、`lockfile` 或 Node 版本不匹配 ✅（中级第 9 章）；断网环境下部署与离线回滚 ✅（高级 3.3）；构建期间并发压测与 OOM 表现 ✅（高级 3.1）；磁盘空间将满时的预检拦截 ✅（高级 7.3）；恶意 `postinstall` 脚本攻击 🧪（同上方“权限与信任”表中的“恶意构建”练习）。

### 数据与迁移

备份与恢复全流程演练 ✅；备份覆盖范围与保留策略 ✅（中级第 6 章）；数据库迁移失败时严禁切换流量 ✅（中级 9.4）；破坏性迁移的回滚安全矩阵 ✅（高级 6.1）；大表加索引的锁阻塞对比 ✅（高级 6.2）；并发迁移锁保护 ✅（中级 7.4）；副本库迁移干跑 ✅（高级 6.3）。

### 切换、健康与回退

停机窗口毫秒级量化 ✅（高级 2.1）；健康检查假阳性拦截 ✅（中级 9.6）；部分 systemd 单元异常停止 → 🧪 手动执行 `systemctl stop demo-app-worker` 后运行 `healthcheck.sh`，应明确报错 `unit:demo-app-worker=inactive`；数据库迁移成功但新进程启动崩溃 → 自动回切旧版 ✅（中级 9.5）；回切后旧版本同样不健康 → 🧪 故意同时弄坏新旧两个版本（例如删掉旧版 `release` 也依赖的某个 `runtime.env` 必填变量），验证系统会如实报告“需要人工介入”而非谎报成功；缺失配置项在切流前被精准拦截 ✅（中级 9.7）；一等公民回滚耗时测量 ✅（记录在 runbook 中的秒数）；部署冻结开关 ✅（高级 7.4）。

### 自举、运维与可迁移性

空服务器首次引导与部署计时 ✅（中级 2.3，请记下你的实测分钟数）；部署脚本漂移检测 ✅（高级 7.5）；整机重启后服务自愈恢复 ✅（高级 7.2）；审计日志、失败通知与三方对账 ✅（高级第 8 章）；历史版本保留策略验证 🧪 连续成功部署 7 次后执行 `ls releases`，应只保留最新的 5 个版本，且当前正在运行的上一版绝不会被误删；`CODEOWNERS` 与部署脚本 CI 自检 ✅（高级 8.3）。

### 假设终审表

| 初始假设 | 最终判定 | 证据所在章节 | 修正与加固方案 |
|---|---|---|---|
| TOCTOU（构建者与运行者身份分离带来的篡改窗口） | **证实** | 高级 5.2 | 构建后立即将属主改为 `root` 只读 / 改用 CI 构建产物 |
| 朴素备份的范围遗漏与保留失控 | **证实** | 中级第 6 章 | 同时备份 DB + storage，采用“按次数 + 按天数”组合保留策略 |
| 朴素健康检查存在假阳性 | **证实** | 中级 9.6 | 断言返回 SHA + worker 心跳新鲜度 + soak 观察窗口 |
| `restart` 切换存在停机窗口 | **证实** | 高级 2.1 | 双槽位蓝绿切换（高级 2.2） |
| CI 并发排队与超时断连行为 | **部分证实** | ⭐ 连推 3 个 commit 的排队观察 / 中级 9.8 | 使用 `setsid` 脱离会话 + 如实记录 CI 状态与线上实际状态的偏差 |
| 缺少环境变量要到切流后才暴露 | **证实 → 已修** | 中级 9.7 | 切流前执行 `check-config` 预检 |
| 生产服务器原地构建的性能代价 | **证实** | 高级 3.1/3.3 | 依据构建位置决策表按需升级（第 9 章） |
| 无法靠“重跑旧 SHA 部署”来实现快速回滚 | **证实 → 已修** | 中级 7.2 | 独立的 `rollback.sh` 秒级回滚脚本 |
| 缺乏日志管理、操作审计与紧急制动开关 | **证实 → 已修** | 中级 7.6/第 10 章 | 引入 `audit.log`、日志轮转与 `freeze` 冻结文件 |
| 公网 SSH 端口长期暴露面过大 | **证实** | 高级 4.1 | 启用 fail2ban / 短期证书 / 切换为 Pull 模式部署 |
| 服务器已安装脚本与仓库发生漂移却无人知晓 | **证实 → 已修** | 高级 7.5 | 定期执行 `sha256sum` 指纹对账 |

---

## 第 11 章 迁移证明：第二个技术栈（Go）

> **本章目标**：用行动证明这套部署模板**真的**具备跨语言可迁移性，而不是嘴上说说而已（这也是本课程的核心验收标准之一）。全程约需 30 分钟。

**【本地】** `# 文件: ~/Projects/demo-go/main.go`（一共 40 行，零第三方依赖）：

```go
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"
)

var version = "dev" // 构建时 -ldflags "-X main.version=$GIT_SHA" 注入

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--check-config" {
		missing := []string{}
		for _, k := range []string{"APP_ENV", "PORT"} {
			if os.Getenv(k) == "" {
				missing = append(missing, k)
			}
		}
		if len(missing) > 0 {
			fmt.Println("missing:", missing)
			os.Exit(3)
		}
		fmt.Println("check-config: OK")
		return
	}
	http.HandleFunc("/version", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"gitSha": version})
	})
	http.HandleFunc("/health/ready", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "at": time.Now().Unix()})
	})
	fmt.Println("demo-go listening")
	http.ListenAndServe("127.0.0.1:"+os.Getenv("PORT"), nil)
}
```

迁移适配改动清单（所有需要改动的地方都在这张表里了）：

| 文件 | 具体改动内容 | 改动行数 |
|---|---|---|
| `deploy/app.conf` | `BUILD_CMD="go build -ldflags \"-X main.version=$GIT_SHA\" -o dist/app ."`；`MIGRATE_CMD="true"`；更新单元名与健康检查 URL | ~5 |
| `deploy/demo-go-web.service` | `ExecStart=/srv/demo-app/current/dist/app`（去掉 worker 单元，因为后台 worker 是 `demo-app` 特有的） | 1 |
| `deploy/demo-app.sudoers` | 替换白名单中的 `systemctl` 单元名称 | ~6 |
| `deploy/check-config.sh` | 把 `node ... --check-config` 改为 `./dist/app --check-config` | 1 |
| `deploy/migrate-wrapper.sh` | 同上（或者无数据库时直接 `exit 0`） | 1 |
| systemd 单元数量 | 从 2 个缩减为 1 个 | — |

**总计只需修改 6 个文件、约 15 行代码。** 其余的 `install.sh`、`deploy-entry`、`deploy.sh`、`healthcheck.sh`（因没有 worker，只需注释掉一行心跳文件检查）、`rollback.sh`、`backup.sh` 以及 GitHub Actions workflow 全部原封不动直接复用。请把这张改动清单抄进你的 `docs/experiments.md`——这就是“架构与语言解耦、真正可迁移”的铁证。

---

## 附录 A 一页纸 Runbook（终版）

在中级册 Runbook 的基础上，追加以下高级运维操作卡片：

```text
═══ 零停机切换(蓝绿)══════════════════════════════════════
/opt/demo-app/bin/switch-slot.sh <sha>   # 切完 soak 30s 自动停旧槽
紧急切回: 手动把 nginx upstream 改回旧端口 + reload + systemctl start 旧槽
═══ 对账(每天看一眼)══════════════════════════════════════
/opt/demo-app/bin/reconcile.sh          # live vs main vs 脚本指纹
═══ 灾难:整机没了 ═════════════════════════════════════════
1. 新开一台同规格机器,记时(RTO 实测)
2. 跑初级册 1–3 章(加固+docker+node)+ install.sh
3. 恢复数据:恢复演练流程,选最近的 premigrate/daily 备份
4. 拉起服务,触发部署对齐 main;更新 GitHub 的 DEPLOY_KNOWN_HOSTS(新指纹!)
5. 停计时,把 RTO 记进表(高级 6.4)
═══ 锁死恢复(附录 B 演练过)═══════════════════════════════
厂商控制台 VNC → 挂载修复 → 改回 sshd_config → sshd -t → 重载
```

## 附录 B 锁死演练

**请在你的实验机上**故意把 `sshd` 配置改坏一次，亲手演练如何救回机器（平时练过一次，真出事时才不会手忙脚乱）：

```bash
sudo cp /etc/ssh/sshd_config /tmp/sshd_config.bak
echo "Port 2222" | sudo tee -a /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart ssh     # 语法是"对"的,但 2222 没在 ufw 放行
# 新开终端 ssh → timeout(锁死了!)
# 恢复:厂商控制台 VNC 登录:
#   sudo cp /tmp/sshd_config.bak /etc/ssh/sshd_config && sudo sshd -t && sudo systemctl restart ssh
```

**安全操作规范沉淀**：今后凡是修改 `sshd`、`sudoers` 或 `ufw` 防火墙配置，务必严格遵循防锁死五步法——**改前先备份 → 用 `sshd -t` / `visudo -cf` 检查语法 → 执行 `reload`（绝不用 `restart`）→ 保持当前老会话不断开 → 新开一个终端窗口验证登录**。这五步就是“永远不要把自己锁在服务器门外”的全部秘诀。

## 附录 C “层 2 未验证”清单

本教程的绝大多数实验均已在真实 VPS 与真实 GitHub Actions 环境中完成端到端验证。以下四个扩展项目依赖特定的外部条件，特此列出对应的验证方法供你在自有环境中补齐：

| 验证项目 | 未在标准实验中默认跑通的原因 | 验证方法 |
|---|---|---|
| 并发部署时队列任务被替换的精确行为 | 需要连续触发真实的 GitHub Actions 运行 | 连续快速 `push` 3 个提交，在 Actions 页面观察排队与取消状态 |
| 多机蓝绿 / 滚动发布 | 标准实验环境为单机 | 开启第二台实验机，在多节点上重复双槽位切流实验 |
| 短期 SSH 证书在 CI 中的全自动签发 | 需要设计 CA 私钥的安全托管方案 | 将 CA 私钥存入 Actions Secret，或接入云厂商 OIDC 动态签发 |
| 基于 WAL 归档实现 RPO = 1h | 需要配置独立的归档存储桶 | 配置 Postgres `archive_command` 并对接对象存储服务 |

### 本地 VM 模拟 CI → SSH 部署（呼应初级册附录 B 的引子）

如果你在本地虚拟机（VM）中演练，可以直接在宿主机上扮演 GitHub Actions Runner（与真实 Actions 环境的唯一差异在于：本地模拟没有 `needs: check` 前置门禁，也无法复现云端并发排队与自动取消行为）：

```bash
# 固定 host key(对应真实链路里的 DEPLOY_KNOWN_HOSTS)
ssh-keyscan -t ed25519 <VM_IP> > ~/.ssh/demo_vm_known_hosts
# 用 CI 的 deploy 私钥触发一次部署(与 workflow 里的 ssh 行完全同构)
ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/demo_vm_known_hosts \
    -i ~/.ssh/demo_deploy_key "deploy@<VM_IP>" "deploy <40位SHA>"
```

---

## 收尾：清理与费用清单

全部实验做完后，别忘了把演练战场打扫干净（顺便算一算学完这门课的真实花费）：

```bash
# 服务器侧:停冻结开关与定时任务都随机器一起消失,无需单独清理
# 本地侧:删掉不再需要的 CI 私钥
rm ~/.ssh/demo_deploy_key ~/.ssh/demo_deploy_key.pub
# GitHub 侧:仓库 Settings → Deploy keys 删除两把实验钥匙;
#            Settings → Secrets 删除 DEPLOY_HOST / DEPLOY_SSH_KEY / DEPLOY_KNOWN_HOSTS
# 机器:实验机按小时计费的现在就销毁;教学 VPS 快照留档(可选)后销毁
```

费用参考：按小时计费的实验机（1C1G）跑完本册全程通常 **< $1**；按月计费的教学 VPS 加上域名折算下来约 **$5–10**。销毁机器之前，记得把服务器上的 `audit.log` 和你整理好的 `docs/experiments.md` 拉回本地并存进代码仓库——这两份文件，就是你从这门部署实战课拿到的“毕业证”。

---

*恭喜毕业！如果你意犹未尽，推荐接下来阅读这份进阶书单：Amazon Builders' Library（特别是 Deployment 与 Rollback 相关篇章）、The Twelve-Factor App，以及《Google SRE》第 8 章 Release Engineering。读到它们时你会会心一笑——因为书里总结的每一条工业界法则，都已经在这三册教程里经过了你的亲手验证。*
