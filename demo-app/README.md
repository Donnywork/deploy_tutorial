# demo-app

配套部署教程的最小可运行教学应用：源码精简到十分钟即可通读完毕，却完整覆盖了真实生产部署中的每一条关键链路（Web 服务 + 后台 Worker + 数据库迁移 + 启动配置预检 + 本地持久化文件存储）。

| 端点 | 行为说明 | 对应的部署验证点 |
|---|---|---|
| `GET /health/live` | 仅检查进程存活（不访问数据库） | 区分存活探针（Liveness）与就绪探针（Readiness） |
| `GET /health/ready` | 执行一次真实的数据库读写往返，失败返回 `503` | 验证“端口能连上 ≠ 服务真可用” |
| `GET /version` | 返回构建阶段注入的 Git 提交哈希：`{"gitSha":"..."}` | 让健康检查精确断言当前线上运行的代码版本 |
| `GET /` | 人类可读的状态首页 | 浏览器直观验证部署结果与 HTTPS 链路 |
| `GET/POST /api/notes` | 笔记列表与新建接口（新建笔记会自动入队一个 `shout` 异步任务） | 演示 Web 进程与后台 Worker 进程的协同发布 |
| `GET /api/jobs/:id` | 查询异步任务的执行状态与处理结果 | 验证 `SIGTERM` 优雅退出、至少一次投递与任务幂等性 |
| `GET/POST /api/files` | 本地持久化存储目录的文件写入与列举 | 验证备份与恢复演练必须同时覆盖数据库与磁盘文件 |

## 本地开发与启动

```bash
pnpm install                 # 首次安装依赖并生成 pnpm-lock.yaml
cp .env.example .env         # 复制环境变量模板，将 POSTGRES_PASSWORD 设为任意随机字符串
docker compose up -d db      # 启动本地 PostgreSQL 容器（仅绑定 127.0.0.1）
pnpm run migrate             # 执行数据库迁移（src/migrate.js：基于 advisory lock 与 schema_migrations 表）
pnpm run build               # 打包至 dist/ 并生成注入了 GIT_SHA 的 version.json
pnpm run dev                 # 启动 Web 服务：http://127.0.0.1:3000
pnpm run worker              # 在另一个终端启动后台 Worker 进程，消费异步任务队列
```

## 目录结构

```
src/            应用核心源码（构建时复制至 dist/）
migrations/     SQL 数据库迁移脚本，按文件名顺序执行并记录至 schema_migrations 表
deploy/         中级教程：生产级部署流水线的服务器端完整参考实现（含脚本、sudoers 与 systemd 单元）
deploy/naive/   初级教程：v0 朴素部署与基础备份脚本（作为演进对照组）
.github/        GitHub Actions 持续集成与自动部署工作流参考实现
```

> **安全提醒**：`.env.example` 仅保留配置项名称作为模板，包含真实密钥的 `.env` 文件永远不应提交至 Git 仓库。
