# 高级教程:对比、量化与升级决策

> **你会学到**:用实验回答四个真实的架构问题——在哪构建、怎么触发、如何切换、凭证怎么管;把备份从"应该行"变成"有 RPO/RTO 数字的演练记录";在自己身上制造部署事故(kill -9、断电、OOM)并看着系统自愈;最后,得到一份"什么时候才值得上 K8s"的诚实决策表。
>
> **前置**:中级册毕业(线上有 v1 管线),愿意破坏自己的实验服务器。**强烈建议**:按小时计费再开一台干净 VPS 做本册的实验机(做完销毁,总花费通常 < $1),别在承载真实服务的机器上跑第 2/3/7 章。
>
> **本册原则**:一次构建处处部署、回滚安全、备份要演练、控制爆炸半径、短寿命凭证、期望状态可对账、简单优先(知道何时**不**上工具)。

**方法论**:本册的每一节都是一个实验,格式固定:

```
假设:  我们相信 X(通常是参考设计或某条业界"常识")
步骤:  怎么做实验(命令)
观察:  应该看什么、怎么记录
结论:  X 成立/不成立;在什么条件下值得换方案(升级触发条件)
```

> 这套实验格式的铁律:**每个结论都要有证据(命令、日志、退出码),而不是断言。** 你做完每个实验,请在自己的笔记里留下一行证据。

---

## 第 1 章 测量工具箱

没有数字的架构讨论是抬杠。四个趁手工具:

### 1.1 停机窗口测量(毫秒级)

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

> macOS 提示:`date +%s%3N` 是 GNU 扩展,BSD date 会输出字面 `N`。在 Mac 本地测量请 `brew install coreutils`,把脚本里的 `date` 换成 `gdate`。

### 1.2 延迟与吞吐

```bash
# hey(Go 写的压测工具,brew install hey / apt 装不了就下 release)
hey -z 60s -c 10 https://deploy-demo.example.com/health/ready
# 盯三个数:平均延迟、p99、错误数。对比实验(第 2/3 章)前后各跑一次
```

### 1.3 RPO / RTO

- **RPO**(能忍丢多少数据)= 备份间隔 + 复制延迟。当前方案:v1 每日 daily + 每次部署 premigrate → 最坏丢 24h。
- **RTO**(能忍多久不可用)= 检测时间 + 恢复时间。第 6 章会实测"从备份完全恢复一台新机"的耗时。

### 1.4 实验记录表模板

每次实验记五行,存进仓库 `docs/experiments.md`:

```
## E<编号> <名称> (日期)
假设:
步骤:
观察:   (贴关键日志/数字)
结论:
升级触发: (什么条件下该换方案 / 不换)
```

---

## 第 2 章 实验:重启窗口与蓝绿切换

### 2.1 基线:先量出 v1 的停机窗口

**假设**:中级册的"原子切换 + restart"仍有可观测的停机窗口(几十到几百毫秒)。

**步骤**:
1. 【本地】跑起 `measure-downtime.sh`;
2. 【服务器】触发一次部署(改个无关紧要的字符串,push);
3. 部署完成后 Ctrl-C,统计 `/tmp/downtime.tsv`。

**观察**:你会看到一串 `000`,以及若干 `200` 之间的空洞。典型数字:**200–1500ms**(取决于 systemd 停止旧进程是否要等优雅退出、新进程启动多快)。**如实记录,不要声称零停机。** 在途请求的下场也看得到:优雅退出让大多数请求完成,但正在建立的连接会失败。

**结论**:v1 窗口 = 旧进程停止 + 新进程启动 + 健康起来的时间。要消灭它,得让**新旧进程同时活着**,这就是蓝绿。

### 2.2 最小蓝绿:双槽位 + Nginx 切换

单机蓝绿不需要 K8x,只需要:两个槽位、Nginx 记住"现在谁是蓝"、一个切换脚本。

**布局改造**(在实验机上做):

```
/srv/demo-app/
├── releases/<sha>/          # 不变
├── blue  → releases/<shaA>  # 槽位软链
├── green → releases/<shaB>  # 槽位软链
└── current → blue           # 现在"谁在台上"
```

应用配置:蓝绿各占一个端口(`PORT=3010` 蓝、`3020` 绿,由 `runtime.env.blue/green` 提供)。Nginx:

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

**切换脚本** `# 文件: /opt/demo-app/bin/switch-slot.sh`(核心 30 行):

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

(完整的单元模板化 `demo-app-web@.service`、双 `runtime.env`、与 `deploy.sh` 的接线——把第 12/13 步替换为本脚本——留作本章练习,思路全部来自中级册,只是从"一个 current"变成"两个槽位"。)

### 2.3 测量与结论

**步骤**:重复 2.1 的测量,但部署走蓝绿路径。

**观察**:`measure-downtime.sh` 里**一个 000 都没有**。Nginx `reload` 平滑换 upstream,旧连接继续由旧 worker 服务完。窗口 ≈ **0ms**(诚实说明:数据库迁移仍在切换前发生,长连接/WebSocket 的处理要额外设计;worker 新旧共存的 30 秒里任务可能被两边抢——`FOR UPDATE SKIP LOCKED` 恰好保证不重复处理,这是中级册埋的伏笔)。

**结论与升级触发**:

| 方案 | 停机窗口 | 复杂度代价 | 什么时候值得 |
|---|---|---|---|
| v1 重启切换 | ~0.2–1.5s | 低 | 内部工具、流量小、用户能容忍"发布中刷新一下" |
| 单机蓝绿 | ≈0ms | +1 套槽位管理、内存翻倍 | 对外服务、SLA 明确、单机内存装得下两份进程 |
| 多机滚动/K8s | ≈0ms | 全套编排 | 机器多到手工管不动(见第 9 章) |

---

## 第 3 章 实验:在哪儿构建

**假设**:在生产机构建(a)拖累线上服务;(b)外网一断就不能部署;(c)两次构建不可复现。CI 构建产物能修掉这三个问题,代价是产物分发基建。

### 3.1 基线:服务器构建的影响

**步骤**:
1. 【服务器】人为压低资源:实验机本来就可以买小内存款(1GB)。
2. 【本地】起 `hey -z 120s -c 10`,同时触发一次部署。
3. 记录部署期间 `hey` 的 p99 和错误数;`free -m` 看内存;如果 OOM,`journalctl -k | grep -i oom` 留证据。

**观察**(1GB 机器的典型结果):`pnpm install` + build 期间 p99 明显上升(2–5 倍);内存紧张时 node 构建进程可能被 OOM 杀死 → **部署失败,但线上服务仍在跑**(感谢 `.partial` 隔离)——把这条也记下来,它是 v1 设计的加分项。

### 3.2 CI 构建产物变体

workflow 增加一个 `package` job(核心改动):

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

服务器侧 `deploy.sh` 的第 6–8 步换成"下载产物 + 校验 sha256 + 解包"(可以用 `gh run download` 或对象存储 URL)。**关键点:一次构建,处处部署——CI 测过、打包的那份,和线上跑的那份,是同一份字节。**

### 3.3 三个对照实验

| # | 实验 | 服务器构建(v1) | CI 产物 |
|---|---|---|---|
| 1 | 部署期间压测(同 3.1) | p99 劣化 | **无劣化**(服务器只解 tar) |
| 2 | 断外网部署 | `git fetch` 直接失败;**但 rollback.sh 仍可用**(它不碰网) | 产物已随部署通道到达时,解包不依赖外网;但传输通道本身要通。**共同点:回滚永远离线可用** |
| 3 | 可复现性 | 同一 SHA 两次构建,`sha256` **不同**(里面 `dist/version.json` 的 `buildTime`!) | 同上;修法:去掉 `buildTime` 或用 `SOURCE_DATE_EPOCH` 固定时间,改完后同一 SHA 两次构建 checksum 一致 |

**观察 3 的现场**:

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

**结论与升级触发**:

| 维度 | 服务器构建 | CI 构建 |
|---|---|---|
| 线上影响 | 有(与机器规格负相关) | 无 |
| 外网依赖 | fetch + 包仓库 | 只传输通道 |
| 回滚速度 | releases/ 里现成,秒级 | 同样秒级(releases 结构不变) |
| 基建 | 零 | 产物存储 + 下载凭证 |
| **值得切换当** | —— | 机器 ≤2GB / 多台服务器要部署同一份 / 有合规要求(产物留档)/ 包仓库不稳定 |

单机 demo-app:**不换也合理**。两条腿都跑过之后,这是你自己数据支撑的决定,不是人云亦云。

---

## 第 4 章 实验:推送(SSH)还是拉取(Poll)

**假设**:Push-SSH 必须开放入站 22 端口,长期暴露在扫描与爆破之下;Pull 模式(服务器定时问 GitHub)能把入站面收到零,代价是延迟和失败可见性。

### 4.1 先看看 22 端口的世界

```bash
sudo journalctl -u ssh --since today | grep -c "Invalid user"   # 今天的爆破尝试数
# 一个开了几天的实验机,这个数字通常是几百到几万
sudo apt install -y fail2ban && sudo systemctl enable --now fail2ban   # 最低限度缓解
```

### 4.2 Pull 原型(30 行核心)

**复用关键**:Pull 不是新部署系统,只是**换一个调用者**。`deploy.sh` 一个字不改。

`# 文件: /opt/demo-app/bin/poll.sh`(root 持有,由 systemd timer 每 60s 跑):

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

启用后,`sudo ufw delete allow OpenSSH`(或改成只允许你的 IP 段)——**入站面归零**,这就是 Pull 的全部安全收益。

### 4.3 对照结论

| 维度 | Push-SSH | Pull |
|---|---|---|
| 入站暴露 | 22 端口(有强制命令+fail2ban 兜底) | **零**(只有 80/443) |
| 部署延迟 | 推送即触发(秒级) | ≤ 轮询间隔(60s) |
| 失败可见性 | Actions 页面直接红 | 得自己做(日志/告警,第 8 章) |
| 审计 | CI 发起,链路清楚 | 服务器自发,actor=poller |
| 外部依赖 | GitHub Actions 正常 + 服务器可达 | 服务器出网可达 GitHub |

**升级触发**:机器数量 ≥2(想一次推所有机器)、安全要求"不开任何入站"(合规)、或爆破噪音大到运维烦躁 → Pull;单机 + 想要 Actions 页面的即时反馈 → Push。**两者共存也是合理形态**(Pull 兜底对账,见第 8 章)。

---

## 第 5 章 信任与凭证:短期证书、TOCTOU、glob 边界

### 5.1 静态密钥的爆炸半径 → 短期 SSH 证书

**假设**:CI 私钥是长期静态的,泄露后攻击面 = "触发任意 main SHA 的部署";短期证书能把钥匙的有效期从"永久"压到"分钟"。

**最小演示**(概念验证,不必上生产):

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

**观察**:5 分钟后同一把钥匙被拒绝(`Permission denied`)。爆炸半径从"永久"压缩成"5 分钟内的合法 SHA"——前提是 `force-command` 也在场:**有效期管"能用多久",强制命令管"能干什么"**,两者缺一不可(只压时长的证书仍然是一张完整 shell 的通行证)。

**结论**:单机小项目,静态密钥 + 强制命令 + 审计的爆炸半径已经很小(引入 CA 的运维成本 > 收益,简单优先);**多机/多团队/合规场景**证书(或 OIDC 动态凭证)开始划算。升级触发:钥匙要发给 >3 个 CI 仓库 / 出现过任何一次疑似泄露。

### 5.2 TOCTOU——构建者和运行者不是同一个人

**假设**:release 由 deploy 用户构建,由 app 用户执行。构建完成到服务重启之间,deploy 用户(或窃取了 deploy 身份的攻击者)能否篡改即将执行的代码?

**步骤**(实验机):
1. 部署一个新版本,在健康检查通过**之前**手动模拟"篡改":`sudo -u deploy sh -c 'echo "process.exit(99)" >> /srv/demo-app/releases/<sha>/dist/server.js'`
2. 看部署结果:健康检查失败 → 回滚。篡改**没有**进入线上,但注意:**当前这次 release 已经被污染**,且 v1 没有任何机制发现"release 内容与 SHA 不符"。
3. 终极验证:release 目录应改为构建后 `chown -R root:root` + 只读(deploy 构建完就交出写权限),迁移包装脚本 `runuser` 前校验属主。把这个加固做掉,再重跑 1–2:篡改被 EPERM 挡住。

**结论**:假设**证实**(v1 存在窗口),修正 = "构建完立即降权"。同类残余风险:`pnpm install` 的 postinstall 脚本以 deploy 身份执行,恶意构建能借它读走 repo.git 里的 deploy key——最小缓解:deploy key 只读、轮换方便;彻底缓解 = CI 构建产物(第 3 章,服务器上根本不跑包管理器)。

### 5.3 sudoers glob 的边界输入

把中级册的 sudoers 当靶场:

```bash
sudo -u deploy sudo /opt/demo-app/bin/migrate-wrapper.sh "abc...40位... extra arg"
# 脚本内部: exactly one sha argument required → 第二层防线生效
sudo -u deploy sudo /opt/demo-app/bin/migrate-wrapper.sh "../../../../etc/passwd"
# 第一层:sudoers 的 [0-9a-f]* 直接拒(首字符 / 不在字符类里,到不了脚本);
# 第二层:假设绕过了 glob(例如带空格的参数),脚本内部的 case 再拒一次
```

**结论**:glob 挡住了野路径,脚本内校验挡住了"glob 跨空格"的绕过——纵深防御不是口号,是两次独立生效的验证。残余:audit.sh 的 `*` 仍可被 deploy 注水,见第 8 章。

---

## 第 6 章 数据进阶:expand/contract、大表锁、RPO/RTO 实测

### 6.1 破坏性迁移的正确姿势

**假设**:"删掉 `notes.body` 列"这种 contract 操作,直接一次性部署会在回滚时炸(旧代码还在 SELECT 这个列)。两阶段部署能保证任何时刻回滚都安全。

**错误做法现场**(实验机,先看事故再学正确):

```bash
# 直接删列 + 部署 → 然后手动 rollback.sh 回旧代码
# 旧代码 SELECT body → ERROR: column "body" does not exist → 500
# 你刚刚制造了"回滚不安全"的教科书案例
```

**正确姿势——把 003 拆成两次发布**:

```
发布 1(expand):新增列/写双写/新代码兼容旧结构
  migrations/003_expand.sql:  ALTER TABLE notes ADD COLUMN content text;
                              UPDATE notes SET content = body;
  server.js 同时读写 body(旧)和 content(新)→ 部署,观察一周
发布 2(contract):确认不再回滚到更旧版本后
  migrations/004_contract.sql: ALTER TABLE notes DROP COLUMN body;
  server.js 只读写 content → 部署
```

**回滚安全矩阵**(自己做一遍,填你的观察):

| 组合 | 旧 schema + 新代码 | 新 schema(expand)+ 旧代码 | 新 schema(contract)+ 旧代码 |
|---|---|---|---|
| 结果 | ✅ 兼容(expand 的意义) | ✅ 兼容(双写期的意义) | ❌ 崩(所以 contract 前必须确认不再回滚) |

### 6.2 大表迁移的锁

**步骤**:
1. 造一张 50 万行的表:`INSERT INTO notes(title) SELECT 'row'||g FROM generate_series(1,500000) g;`
2. 实验窗口期,另一个连接持续 UPDATE 随机行(模拟线上写入)。
3. 对比两种加索引:

```sql
-- A: 普通索引(锁表)
BEGIN; CREATE INDEX idx_slow ON notes(created_at); -- 观察另一个连接的写入:阻塞
-- B: 并发索引(不锁写)
CREATE INDEX CONCURRENTLY idx_fast ON notes(created_at); -- 写入继续
-- 配套:SET lock_timeout='3s' 让锁等待快速失败而不是排长队
```

**观察**:A 方案期间写入侧排队(`SELECT * FROM pg_stat_activity WHERE wait_event_type='Lock'` 能看到);B 方案写入不受影响(代价:构建更慢、不能在事务里)。

**结论**:面向生产的迁移三件套——`lock_timeout`、`CONCURRENTLY`、低峰执行;任何"我不知道这个迁移锁不锁"的时刻,先在**副本库上干跑**(下一条)。

### 6.3 迁移干跑

```bash
# 1. 从最新备份恢复一个副本库(中级册第 6 章的流程)
# 2. 对副本库跑 --dry-run(列出将应用什么),再真跑一遍
DATABASE_URL=postgres://drill:drill@127.0.0.1:55432/drill node dist/migrate.js --dry-run
DATABASE_URL=postgres://drill:drill@127.0.0.1:55432/drill node dist/migrate.js
# 失败?→ 迁移有问题,正式库一根毛都没碰
```

把"迁移前先在副本库演练"加进 deploy.sh 的可选项(`MIGRATE_DRYRUN=true` 时启用),是很多大团队的标准动作。

### 6.4 备份 RPO/RTO 实测表

在实验机上完成这张表(数字是你的,格式是通用的):

| 项目 | 值 | 怎么测 |
|---|---|---|
| 备份大小(DB/storage) | ___ KB | `du -h` |
| 备份耗时 | ___ s | `time backup.sh manual` |
| 恢复耗时(空库) | ___ s | `time pg_restore`(中级册第 6 章) |
| 全机重建 RTO(从零到线上恢复) | ___ min | 附录 B 的灾难演练计时 |
| RPO(daily 模式) | 最坏 24h | 定义 |
| RPO(若加 hourly 归档/WAL) | 最坏 1h | 第 9 章的升级触发 |
| 异地副本延迟 | ___ | `rsync` cron 的间隔 |

**GitLab 2017 的教训**不是"没备份",而是**没验证过恢复**。这张表填满的那一刻,你的备份才算存在。

---

## 第 7 章 崩溃一致性实验室

在本章,你是一名故意找茬的 QA。每个实验的验收标准都是同一句话:**要么自动恢复,要么进入明确可恢复的状态;绝不留半成品,绝不损坏线上。**

### 7.1 部署中途 kill -9

对五个时点各做一次:构建中 / 备份后 / 迁移中 / 迁移后切换前 / 健康检查中。

```bash
# 【服务器】部署进行时,找到 deploy.sh 的 PID
ps aux | grep '[d]eploy.sh'
sudo kill -9 <pid>
```

**预期结果表**(逐格验证):

| 时点 | 现场残留 | 重跑结果 |
|---|---|---|
| 构建中 | `.partial/` | ✅ 自动清理重建 |
| 备份后 | 多一份备份(无害) | ✅ 继续 |
| 迁移中 | 失败迁移整体回滚(事务) | ✅ |
| 迁移后切换前 | DB 已新,代码还旧(expand 期安全) | ✅ |
| 健康检查中 | current 已新但未确认 | ✅ 幂等检查/健康检查收敛 |

### 7.2 整机重启

部署跑到一半 `sudo reboot`(挑"迁移中"那个时点最刺激)。开机后:Postgres 回来、单元 active、flock 锁(在 /run,tmpfs)自动消失、`/srv/demo-app/current` 指向一致的状态。有半成品?手动触发一次部署,看它收敛。

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

**假设**:改了仓库里的 deploy.sh 但忘了重装,线上仍用旧脚本,而且**没有任何机制发现**。

```bash
# 验证假设:仓库加一行注释,push,不重装 → 部署行为没变(旧脚本继续跑)→ 假设证实
# 修正:对账一条命令 —— 左边在 /opt 哈希"已安装的",右边在仓库目录校验"仓库里的"
# (注意:清单必须用文件名在目标目录校验,直接对 /opt 自查永远 OK)
cd ~/demo-app-bootstrap/deploy && \
sudo sh -c 'cd /opt/demo-app/bin && sha256sum app.conf deploy-entry deploy.sh healthcheck.sh \
  check-config.sh migrate-wrapper.sh backup.sh rollback.sh audit.sh' \
  | sha256sum -c - || echo "DRIFT: installed scripts differ from repo — run install.sh"
```

**结论**:漂移检测的本质是"期望状态可对账":"应该装的脚本"与"实际装的脚本"必须可比对。升级 install.sh 时,记得指纹文件一起更新(它自己也是被对账对象)。

---

## 第 8 章 可观测与对账

### 8.1 期望状态对账(reconcile)

`# 文件: /opt/demo-app/bin/reconcile.sh`(cron 或 poll 顺带跑):

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

最低成本:一个本地 webhook(写文件 + 你顺手能看到的渠道):

```bash
# deploy.sh 的 die() 里已经写 audit.log;再加一步:
curl -fsS -m 3 "$NOTIFY_WEBHOOK" -d "deploy failed: sha=$SHA step=$step" >/dev/null 2>&1 || true
# NOTIFY_WEBHOOK 指向 Slack/飞书/Telegram 的 incoming webhook,或本机的一个文件收集服务
```

> 注意 `|| true`:通知失败不能让部署流程本身失败(通知是旁路,不是链路)。

### 8.3 部署系统自身的变更管控

部署脚本、sudoers、workflow 是"能改变生产行为"的高危文件:

1. **CODEOWNERS**(仓库 `.github/CODEOWNERS`):

```
/deploy/          @你的团队/ops
.github/workflows/ @你的团队/ops
```

2. **部署自检 CI**(在 `ci.yml` 的 check job 里加):

```yaml
- run: sudo apt-get install -y shellcheck && shellcheck deploy/*.sh
- run: bash -n deploy/deploy-entry
- run: sudo visudo -cf deploy/demo-app.sudoers
```

3. audit 防注水(5.3 的残余):把 audit 同时写给 syslog(`logger` 已经在写)并在**另一台**机器收 syslog——deploy 用户改不了那台机器的日志。

---

## 第 9 章 升级决策记录(ADR)

每条一句话结论 + 量化触发条件。**不满足触发条件就别上**(简单优先的实践)。

| 决策 | 触发条件(满足任意一条再考虑) | 不满足时的替代 |
|---|---|---|
| **CI 构建产物** | 机器 ≤2GB / ≥2 台服务器 / 合规要求留档 | 服务器构建(v1 现状) |
| **Pull 部署** | ≥2 台机器 / 禁止入站 SSH 的合规 / 爆破噪音失控 | Push-SSH + fail2ban + 强制命令 |
| **蓝绿** | 对外 SLA / 停机窗口被用户抱怨过 | 原子切换 + 低峰部署 |
| **短期证书/OIDC** | 钥匙 >3 把 / 出现过疑似泄露 / 多团队共用 CI | 静态密钥 + 审计 + 快速轮换预案 |
| **每日→每小时备份 / WAL 归档** | RPO 24h 不可接受(有交易/用户数据) | 每日 + 每次部署前 |
| **对象存储异地备份**(rclone cron 到 S3/R2) | **立即**(成本 ≈ 免费,收益 = 火灾场景) | rsync 到笔记本(最低限度) |
| **Ansible** | 手工操作同样的机器 >5 次开始复制粘贴 | 本教程的 install.sh |
| **Terraform** | 云资源种类 >3 且经常变 | 手工建 + 记录 |
| **Docker 镜像 + registry** | CI 产物变体 + 多机分发的自然演进 | tarball 产物 |
| **Kubernetes** | 机器 >10 台 / 服务 >15 个 / 团队有专职平台人力 / 需要频繁弹性伸缩 | 单机 systemd + 本教程管线 |

> K8s 那一行的潜台词:它解决的问题(多机编排、自愈、弹性)在你 3 台机器 2 个服务时**并不存在**,而它引入的问题(集群自身运维、凭证、网络模型)从第一天就在。先让痛点出现,再让工具进场。

---

## 第 10 章 场景矩阵练习册

场景矩阵全表。✅=初中级已做过;🧪=本章练习(附提示);⭐=需要真实公网/真实 Actions 的"层 2"验证(标注未验证方法)。

### 权限与信任

| 场景 | 状态/提示 |
|---|---|
| 强制命令滥用矩阵 | ✅ 中级 3.5 |
| deploy 越权(改钥匙/脚本/读 env/sudo 非白名单) | ✅ 中级 3.5/4;补:试 `sudo -u deploy vi /opt/demo-app/bin/deploy.sh` |
| 恶意构建(postinstall 提权/读密钥) | 🧪 在 package.json 加 `"postinstall": "cat /home/deploy/.ssh/id_ed25519"` → push → 看构建日志里钥匙是否泄露(会!→ 残余风险,修法=CI 构建或 npm --ignore-scripts) |
| TOCTOU + glob 边界 | ✅ 高级 5.2/5.3 |
| 主机密钥不匹配部署必须失败 | 🧪 改 GitHub Secret 里的 host key 一个字符 → 部署立刻 `REMOTE HOST IDENTIFICATION HAS CHANGED` 失败 |
| 日志不得泄密 | 🧪 `grep -r PASSWORD /var/log/demo-app/` 应无果(含构建失败时) |
| sshd 锁死演练 | 附录 B |

### 来源、并发与崩溃一致性

| 场景 | 状态 |
|---|---|
| force-push 的 SHA 被拒 | ✅ 中级 3.5(全 0 SHA) |
| 旧跳过/幂等 | ✅ 中级 9.8 |
| flock + concurrency 分工 | ✅ 中级 7.1/9.8 |
| 连推 3 个 commit 的排队行为 | ⭐ 真实 Actions 观察:等待中的旧运行被替换;runner 超时但服务器继续(✅ 9.8 已验) |
| 断线部署完成 | ✅ 中级 9.8 |
| 五时点 kill -9 | ✅ 高级 7.1 |
| 部署中整机重启 | ✅ 高级 7.2 |

### 构建与工具链

构建失败、lockfile/Node 版本不匹配 ✅(中级 9);断网部署与回滚 ✅(高级 3.3);构建压测/OOM ✅(高级 3.1);磁盘将满 ✅(高级 7.3);恶意 postinstall 🧪(同上面"恶意构建"一条)。

### 数据与迁移

备份+恢复演练 ✅;备份范围+保留 ✅(中级 6);迁移失败不切换 ✅(中级 9.4);回滚矩阵 ✅(高级 6.1);大表锁 ✅(高级 6.2);并发迁移 ✅(中级 7.4);干跑 ✅(高级 6.3)。

### 切换、健康与回退

停机窗口量化 ✅(高级 2.1);健康检查假阳性 ✅(中级 9.6);部分单元失败 → 🧪 `systemctl stop demo-app-worker` 后跑 healthcheck.sh,应报 `unit:demo-app-worker=inactive`;迁移成功但起不来 → 自动回切 ✅(中级 9.5);回切后也不健康 → 🧪 同时弄坏两个版本(旧 release 的 runtime.env 依赖?),确认系统报"需要人工"而非成功;缺配置切换前拦截 ✅(中级 9.7);回滚计时 ✅ runbook 里的数字;部署冻结 ✅(高级 7.4)。

### 自举、运维与可迁移性

空服务器首次部署计时 ✅(中级 2.3,记录你的分钟数);脚本漂移 ✅(高级 7.5);重启恢复 ✅(高级 7.2);审计/通知/对账 ✅(高级 8);保留策略 🧪 部署 7 次,`ls releases` 应剩 5 个且不含上一版被删;CODEOWNERS+自检 CI ✅(高级 8.3)。

### 假设终审表

| 假设 | 判定 | 证据位置 | 修正 |
|---|---|---|---|
| TOCTOU(构建者/运行者分离) | **证实** | 高级 5.2 | 构建后降权 root 只读 / CI 构建 |
| 备份范围与保留 | **证实** | 中级 6 | DB+storage、按次数+按时间组合 |
| 健康检查假阳性 | **证实** | 中级 9.6 | 断言 SHA+心跳+soak |
| 重启窗口 | **证实** | 高级 2.1 | 蓝绿(2.2) |
| CI 并发/超时行为 | **部分证实** | ⭐连推 3 commit 的排队观察/中级 9.8 | setsid 脱离 + 状态差异如实告知 |
| 缺配置事后发现 | **证实→已修** | 中级 9.7 | check-config 预检 |
| 生产机构建的代价 | **证实** | 高级 3.1/3.3 | 构建位置决策表(第 9 章) |
| 无法重部署旧 SHA 来回滚 | **证实→已修** | 中级 7.2 | rollback.sh(回滚计时) |
| 日志/审计/开关缺失 | **证实→已修** | 中级 7.6/10 | audit.log、日志轮换、freeze |
| SSH 暴露面 | **证实** | 高级 4.1 | fail2ban/证书/Pull 部署 |
| 脚本漂移无检测 | **证实→已修** | 高级 7.5 | 指纹对账 |

---

## 第 11 章 迁移证明:第二个技术栈(Go)

> 目标:证明这套模板**真的**可迁移,而不是声称可迁移(本课程的成功标准之一)。30 分钟。

**【本地】** `# 文件: ~/Projects/demo-go/main.go`(40 行,零依赖):

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

适配改动清单(全部改动就这些):

| 文件 | 改动 | 行数 |
|---|---|---|
| `deploy/app.conf` | `BUILD_CMD="go build -ldflags \"-X main.version=$GIT_SHA\" -o dist/app ."`;`MIGRATE_CMD="true"`;UNITS/健康 URL | ~5 |
| `deploy/demo-go-web.service` | `ExecStart=/srv/demo-app/current/dist/app`(去掉 worker 单元,worker 是 demo-app 特有的) | 1 |
| `deploy/demo-app.sudoers` | systemctl 单元名 | ~6 |
| `deploy/check-config.sh` | `node ... --check-config` → `./dist/app --check-config` | 1 |
| `deploy/migrate-wrapper.sh` | 同上(或直接 `exit 0`) | 1 |
| systemd 单元 | 从 2 个减到 1 个 | — |

**合计 ~15 行改动、6 个文件。** `install.sh`、`deploy-entry`、`deploy.sh`、`healthcheck.sh`(心跳检查因无 worker 需注释一行)、`rollback.sh`、`backup.sh`、workflow 全部原样。把这张表抄进你的 `docs/experiments.md`,这就是"可迁移"的证据。

---

## 附录 A 一页 runbook(终版)

在中级册 runbook 基础上追加:

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

**在你的实验机上**,故意把 sshd 配置写坏,练习恢复(做过一次,真出事时不慌):

```bash
sudo cp /etc/ssh/sshd_config /tmp/sshd_config.bak
echo "Port 2222" | sudo tee -a /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart ssh     # 语法是"对"的,但 2222 没在 ufw 放行
# 新开终端 ssh → timeout(锁死了!)
# 恢复:厂商控制台 VNC 登录:
#   sudo cp /tmp/sshd_config.bak /etc/ssh/sshd_config && sudo sshd -t && sudo systemctl restart ssh
```

**规范沉淀**:任何 sshd/sudoers/ufw 变更,遵循"改前备份 → `sshd -t`/`visudo -cf` → reload(不 restart)→ 保持现有会话开着 → 新会话验证"五步。这五步是"不要把自己锁在门外"的全部。

## 附录 C "层 2 未验证"清单

本教程在真实 VPS + 真实 Actions 上完成了绝大部分验证。以下项目依赖特定条件,标注验证方法:

| 项目 | 未验证原因 | 验证方法 |
|---|---|---|
| 排队运行被替换的精确行为 | 需连续真实 Actions 运行 | 连 push 3 个提交,观察 Actions 列表 |
| 多机蓝绿/滚动 | 单机 | 第二台机器重复槽位实验 |
| 短期证书的 CI 全自动签发 | 需 CA 私钥托管方案 | Actions secret 存 CA 或用 OIDC |
| WAL 归档 RPO=1h | 需归档存储 | postgres `archive_command` + 对象存储 |

### 本地 VM 模拟 CI → SSH 部署(补初级册附录 B 的引子)

在宿主机上扮演 GitHub Actions(与真实 Actions 的差异:没有 CI 结论门 `needs: check`,排队/取消行为不可复现):

```bash
# 固定 host key(对应真实链路里的 DEPLOY_KNOWN_HOSTS)
ssh-keyscan -t ed25519 <VM_IP> > ~/.ssh/demo_vm_known_hosts
# 用 CI 的 deploy 私钥触发一次部署(与 workflow 里的 ssh 行完全同构)
ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/demo_vm_known_hosts \
    -i ~/.ssh/demo_deploy_key "deploy@<VM_IP>" "deploy <40位SHA>"
```

---

## 收尾:清理与费用清单

实验做完,把战场打扫干净(也顺便算清这门课的真实成本):

```bash
# 服务器侧:停冻结开关与定时任务都随机器一起消失,无需单独清理
# 本地侧:删掉不再需要的 CI 私钥
rm ~/.ssh/demo_deploy_key ~/.ssh/demo_deploy_key.pub
# GitHub 侧:仓库 Settings → Deploy keys 删除两把实验钥匙;
#            Settings → Secrets 删除 DEPLOY_HOST / DEPLOY_SSH_KEY / DEPLOY_KNOWN_HOSTS
# 机器:实验机按小时计费的现在就销毁;教学 VPS 快照留档(可选)后销毁
```

费用参考:实验机(1C1G,按小时)全程通常 **<$1**;教学 VPS(按月)+ 域名约 **$5–10**。拉一份 `audit.log` 和 `docs/experiments.md` 存进仓库——它们是你这门课的"毕业证"。

---

*恭喜毕业。下一步的阅读清单:Amazon Builders' Library(deployment & rollback 章节)、12-factor App、Google SRE Book 第8章 Release Engineering。它们会反复印证你在这三册里亲手摸到的东西。*
