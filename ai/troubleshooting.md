# 排错知识库(AI 助教按症状匹配用)

用法:学员贴报错时,先按"症状"字段做字面/关键词匹配;命中后**按"排查"的顺序逐步带学员走**,每步一条命令,边走边解释为什么。未命中时再走通用排查(journalctl / df / 分层缩小)。

> 排错教学优先于给答案:每次至少让学员自己执行一条诊断命令并解读输出。

---

## 连接与登录

### T-01 `ssh: Permission denied (publickey)`
- 阶段:B1 / B3(deploy key)
- 排查:1)【本地】`ssh -v sam@IP 2>&1 | grep -i key` 看它到底试了哪几把钥匙;2) 确认用户名没打错(root 已禁,sam 或 app/deploy);3) 确认公钥确实传到了对应账户(`authorized_keys` 属主和权限,700/600)。
- 修复:重新上传公钥;deploy key 场景确认加的是**仓库**的 Deploy keys 且有读权限。
- 预防:钥匙标注清楚用途(`-C` 注释)。
- 关联:初级 1.2/1.4、3.3;中级 3.4。

### T-02 `ssh: connect to host ... port 22: Operation timed out`
- 阶段:B1
- 排查:1) ping IP 通不通(不通=IP 错/机器没开/本地网络);2)【服务器·厂商控制台 VNC】`sudo ufw status`——22 是否被自己关了(T-04);3) 厂商安全组是否放行 22。
- 修复:按原因对应放开。
- 关联:初级 1.5。

### T-03 `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`
- 阶段:任意
- 两种语境,务必区分:
  a) **预期保护生效(A5)**:服务器重装过/换了机器 → 指纹本来就变了。确认不是被攻击后,【本地】`ssh-keygen -R IP` 清掉旧记录再连;若是 CI 里报这个,更新 GitHub Secret `DEPLOY_KNOWN_HOSTS`。
  b) **意外变化**:你没动过机器 → 不要盲目清记录!先在厂商控制台核对,警惕中间人。
- 修复:见上;CI 侧永远更新 Secret 而不是关掉 StrictHostKeyChecking。
- 关联:中级 3.5/8.1、高级附录 A。

### T-04 被锁在门外(改完 ufw/sshd 连不上)
- 阶段:B1(高风险操作)
- 排查:走厂商控制台 VNC(带外通道)。
- 修复(VNC 内):`sudo cp 备份 /etc/ssh/sshd_config && sudo sshd -t && sudo systemctl restart ssh`;ufw:`sudo ufw allow OpenSSH`。
- 预防:P8 五步——改前备份 → `sshd -t`/`visudo -cf` → **reload 不 restart** → 老会话保持 → 新会话验证。高级附录 B 有完整演练。
- 关联:初级 1.4 ⚠️ 框、高级附录 B。

---

## Docker / Postgres

### T-05 `permission denied while trying to connect to the Docker daemon socket`
- 阶段:B3
- 原因:加完 docker 组没重新登录。
- 修复:`exit` 后重新 ssh(组成员资格登录时生效)。
- 关联:初级 3.1。

### T-06 compose 容器状态 `Restarting` / `unhealthy`
- 阶段:B3
- 排查:1) `docker logs demo-app-db --tail 50`;
  2) `.env` 是否存在且 `POSTGRES_PASSWORD` 已设置(compose 文件里 `:?` 会直接报错)。
- 常见:密码变量名拼错;`.env` 不在 compose 文件同目录。
- 关联:初级 3.4。

### T-07 `password authentication failed for user "demo_app"`
- 阶段:B3/B4
- 原因(按概率):`/srv/demo-app/.env`(或中级 `/opt/demo-app/compose/.env`)里的密码 ≠ 应用连接串 `DATABASE_URL` 里的密码。
- 排查:分别 `grep -c` 两处文件确认密码字段存在;比对(不要明文贴出来)。
- 修复:对齐后重建容器(见 T-08 的警告)。
- 关联:初级附录 D。

### T-08 改了 Postgres 密码但没生效
- 原因:数据卷首次初始化时密码就固化了,改 `.env` 对已有卷无效。
- 修复(实验机):`docker compose down -v` 后 `up -d` 重建。⚠️ **`-v` 会删掉数据卷里的全部数据**——真有数据先备份(pg_dump)再操作。
- 预防:密码在第一次 `up` 前就用 `openssl rand -hex 16` 生成好。
- 关联:初级附录 D。

### T-09 应用报 `ECONNREFUSED 127.0.0.1:5432`
- 阶段:B3/B4
- 排查:1) `docker ps` 看 db 在不在、healthy 吗;2) `docker exec demo-app-db pg_isready -U demo_app`。
- 常见:开机后 Docker 没起完应用就启动了 → 应用侧要有重试;`Restart=on-failure` 会兜底。
- 关联:初级 3.4、中级第 5 章。

---

## Node / pnpm / 构建

### T-10 Node 版本与 `.node-version` 不一致
- 阶段:B3(手动)/ I7(部署预检拒绝,退出码 14)
- 修复:重装对应主版本(NodeSource),或改仓库 `.node-version`(提交)。
- 关联:初级 3.2、中级 7.3(C2)、剧本 3。

### T-11 `pnpm install --frozen-lockfile` 失败(LOCKFILE mismatch / up to date check)
- 阶段:B2/I7
- 原因:`package.json` 改了依赖但没重新生成锁文件。
- 修复:【本地】`pnpm install` 重新生成并**提交 `pnpm-lock.yaml`**。
- 关联:初级 2.1、剧本 2。

### T-12 `Error: listen EADDRINUSE :::3000`
- 阶段:B3/B5
- 排查:`sudo ss -ltnp | grep 3000` 找占用者(通常是手动跑的 node 没退干净)。
- 修复:kill 掉旧进程;养成习惯——手动试跑的进程 Ctrl-C 掉再交给 systemd。
- 关联:初级附录 D。

### T-13 pnpm 警告 `Unsupported engine: wanted node >=22 <23`
- 阶段:任意(常见于本地 Node 24 跑 demo-app)
- 说明:本地开发多数情况无碍;**服务器**上版本必须匹配(部署预检会拦)。
- 修复(想消除警告):本地装 Node 22(nvm/fnm),或改 `engines`(需同时改 `.node-version` 并想清楚服务器侧)。
- 关联:初级 3.2。

---

## systemd

### T-14 `status=203/EXEC` 或 unit 起不来
- 阶段:B4/I5
- 原因(按概率):`ExecStart` 路径不对;`dist/` 不存在(没 build);文件无可执行内容。
- 排查:`journalctl -u xxx -n 30`;逐字核对 ExecStart 的绝对路径;`ls /srv/demo-app/dist/server.js`(或中级的 `current/dist/server.js`)。
- 关联:初级第 4 章。

### T-15 服务崩溃循环后变 `failed`,不再自动重启
- 阶段:B4/I5
- 说明:这是 systemd 的 start-limit(默认 5 次)——**特性不是 bug**:崩溃循环不该被无限掩盖(P3 的 soak 窗口就是为抓它)。
- 排查:`journalctl -u xxx -n 50` 看第一次崩溃的原因(重点看最早那几条,不是最后)。
- 修复:修根因后 `sudo systemctl reset-failed xxx && sudo systemctl restart xxx`。
- 关联:中级第 5 章、剧本 6。

### T-16 "怎么知道服务到底怎么了?"
- 通用排查顺序(教给学员的标准动作):
  1) `systemctl status xxx --no-pager`(Active? Main PID? 最近几行日志)
  2) `journalctl -u xxx -n 100 --no-pager`(全量上下文;`-f` 跟随)
  3) `journalctl -u xxx --since "10 min ago" -p err`
- 关联:初级 4.2。

---

## Nginx / HTTPS

### T-17 `502 Bad Gateway`
- 阶段:B5
- 含义:Nginx 活着,后端(127.0.0.1:3000)死了或拒绝连接。
- 排查:T-16 走一遍 demo-app;`curl -s localhost:3000/health/ready`(服务器本机直接测后端,绕过 Nginx);`sudo ss -ltnp | grep 3000`。
- 常见:应用崩了/没起;后端端口改了没同步 nginx 配置。
- 关联:初级 5.2/附录 D。

### T-18 certbot 报 DNS 验证失败 / challenge 失败
- 阶段:B5
- 排查:1) `dig +short 你的域名` 是否已指向服务器 IP(DNS 没生效最常见);2) 80 端口公网可达(`ufw`、厂商安全组);3) `server_name` 拼写。
- 关联:初级 5.1/5.3。

### T-19 访问域名还是 Nginx 默认欢迎页
- 原因:`sites-enabled/default` 没删,或 `server_name` 不匹配。
- 修复:`sudo rm -f /etc/nginx/sites-enabled/default && sudo nginx -t && sudo systemctl reload nginx`。
- 关联:初级 5.2。

### T-20 http 不自动跳 https
- 检查:certbot 时是否选了 Redirect;`curl -I http://域名` 是否 301。
- 修复:`sudo certbot --nginx -d 域名` 重跑选 Redirect,或检查 server 块的 return 301。
- 关联:初级 5.3。

---

## 部署管线(中级)

### T-21 `deploy-entry: refused: only 'deploy <sha>' is allowed`
- 阶段:I3/I8
- 说明:强制命令在正常工作(A1)。发给服务器的命令不是 `deploy <40位sha>` 这个精确格式。
- 排查:看 Actions 的 ssh 命令拼装;手动测试用:`ssh -i key deploy@host "deploy <完整40位sha>"`。
- 关联:中级 3.3/3.5。

### T-22 `FAILED step=verify: SHA is not an ancestor of origin/main`(退出码 12)
- 阶段:I7/I8
- 原因:SHA 不在服务器 fetch 到的 main 历史上——force-push 顶掉的提交、其他分支、没推上去的提交(B1 防线)。
- 排查(一次一步):【服务器】`sudo -u deploy git --git-dir=/srv/demo-app/repo.git log --oneline -3 refs/heads/main` 对照。
- 关联:中级 7.2、场景 B1。

### T-23 Actions 报 `REMOTE HOST IDENTIFICATION HAS CHANGED`(A5)
- 阶段:I8
- 原因:GitHub Secret `DEPLOY_KNOWN_HOSTS` 与服务器当前指纹不一致(换过机器/重装/中间人)。
- 修复:【本地】重新 `ssh-keyscan -t ed25519 IP`,更新 Secret。**绝不要**在 ssh 命令里关 StrictHostKeyChecking。
- 关联:中级 8.1/8.2。

### T-24 "Actions 红了但服务器其实部署成功" / "Actions 绿了但线上没变"
- 阶段:I8+
- 原因:前者 = CI 超时/被取消,但 setsid 让服务器侧部署继续跑完(H5/B5,**设计使然**);后者 = 幂等跳过(同 SHA 已在线,B2)或 skip-older(B2)。
- 钦定验证:【服务器】`curl -s localhost:3000/version` 与 `sudo tail -3 /var/log/demo-app/audit.log`——**以服务器侧为准**。
- 关联:中级 7.1/7.2、剧本 8。

### T-25 `FAILED step=lock: another deploy is running`(退出码 75)
- 阶段:I7
- 排查:1) `ps aux | grep '[d]eploy.sh'`——真有部署在跑就等它;2) 没有进程但锁还在(机器重启后残留)→ `/run` 是 tmpfs,重启自动清;没重启就 `sudo fuser -v /run/demo-app/deploy.lock` 看持有者。
- 修复:确认无人持有后可删锁文件。
- 关联:中级 7.1、runbook。

### T-26 `FAILED step=fetch: git fetch failed`(退出码 11)
- 阶段:I7
- 原因:网络 / deploy key 失效或没配 / 仓库搬家。
- 排查:【服务器】`sudo -u deploy ssh -T git@github.com`(应返回 "successfully authenticated" 只读身份);`sudo -u deploy git --git-dir=/srv/demo-app/repo.git remote -v`。
- 关联:中级 3.4、C3。

### T-27 健康检查 `worker-heartbeat=XXs` 超龄
- 阶段:I7/I9
- 含义:web 正常但 worker 心跳停了(E2 的经典假阳性,健康检查正在保护你)。
- 排查:`systemctl status demo-app-worker` + `journalctl -u demo-app-worker -n 50`;常见:worker 崩溃循环(T-15)或迁移后代码 bug。
- 关联:中级 7.5、剧本 6。

### T-28 健康检查 `version!=sha`
- 阶段:I7
- 含义:`/version` 返回的不是刚部署的 SHA——旧进程还在应答/切换没生效/新进程没起来。
- 排查:1) `readlink /srv/demo-app/current` 是否指向新 release;2) `curl -s localhost:3000/version`;3) `journalctl -u demo-app-web -n 50`。
- 关联:中级 7.5、E2/E3。

---

## 备份与恢复

### T-29 `pg_restore` 报角色/权限错误(如 `role "demo_app" does not exist`)
- 阶段:B6/I6
- 原因:备份里带着生产角色名,恢复目标库里没有。
- 修复:恢复命令加 `--no-owner`(教程命令一直带着,手敲容易漏);若仍报 GRANT/权限类错误,再补 `--no-privileges`。
- 关联:初级 6.3、中级第 6 章。

### T-30 恢复出来的数据比线上"少"
- 阶段:B6
- 说明:多数情况这是**正确**的证据——备份之后的写入不在备份里(RPO 的定义)。学员应该看到 "after backup" 那条缺失。
- 若缺失的是备份之前的数据:检查是不是选错了备份文件(`ls -1t` 挑最新)。
- 关联:初级 6.3。

---

## 磁盘与资源

### T-31 磁盘满(`No space left on device`)
- 阶段:任意
- 排查顺序:`df -h` → 找大头的:`sudo du -sh /var/log/* /var/backups/* 2>/dev/null | sort -h | tail`。
- 常见清理:`journalctl --vacuum-size=200M`;旧备份按保留策略清;Docker:`docker system df`。
- 预防:部署预检已有 1GiB 下限(C5);备份的保留策略就是为此设计。
- 关联:初级附录 D、中级 7.3、高级 7.3。

### T-32 部署时进程被 OOM 杀掉(构建失败,线上无恙)
- 阶段:I7(成)/ A3(专门实验)
- 说明:`.partial` 隔离让构建 OOM 不影响线上(C1+C4 的加分项)。`journalctl -k | grep -i oom` 留证据。
- 高级册 3.1 会专门量化;解法方向:换 CI 构建(D1)或加内存/加 swap。
- 关联:高级 3.1/3.3。

---

## 通用排查框架(未命中以上条目时)

按层缩小,每层给一条命令,让学员贴回输出再进下一层:

1. **进程层**:`systemctl status <unit>` / `ps aux | grep <进程>`
2. **日志层**:`journalctl -u <unit> -n 100 --no-pager`(看**最早**的报错,不是最后的重复)
3. **网络层**:`curl -sv localhost:<端口>`(本机)→ 外部域名;`sudo ss -ltnp`
4. **资源层**:`df -h`、`free -m`、`uptime`
5. **最近变更**:"出问题前最后一次改了什么?"——回滚它(中级以上:有 rollback.sh 就先回滚止血再查)

> 提醒 AI:超出本库覆盖范围的问题,可以给通用 Linux/运维知识,但要明确标注"这超出了教程内容",并尽量映射回最接近的章节/原则编号。
