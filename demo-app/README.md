# demo-app

部署教程的配套最小应用:小到能读完全部源码,却覆盖部署流程的每一条路径(web + worker + 迁移 + 配置预检 + 文件存储)。

| 端点 | 说明 |
|---|---|
| `GET /health/live` | 进程活着(不碰数据库) |
| `GET /health/ready` | 真实读写一次数据库,失败返回 503 |
| `GET /version` | 返回构建时注入的 SHA:`{"gitSha":"..."}` |
| `GET /` | 人类可读的首页 |
| `GET/POST /api/notes` | 笔记列表 / 新建笔记(新建会入队一个 `shout` 任务) |
| `GET /api/jobs/:id` | 查看任务状态与结果 |
| `GET/POST /api/files` | 文件存储目录的写入/列表(验证备份范围) |

## 本地开发

```bash
pnpm install                 # 生成 pnpm-lock.yaml(首次)
cp .env.example .env         # 填入 POSTGRES_PASSWORD(本地随机生成一个)
docker compose up -d db
pnpm run migrate             # src/migrate.js:advisory lock + schema_migrations
pnpm run build               # dist/ + version.json(GIT_SHA 注入)
pnpm run dev                 # http://127.0.0.1:3000
pnpm run worker              # 另一个终端:消费任务队列
```

## 目录

```
src/            应用源码(构建时复制进 dist/)
migrations/     SQL 迁移,按文件名序执行,记录进 schema_migrations
deploy/         中级教程:参考设计的服务器侧实现(scripts/sudoers/systemd 单元)
deploy/naive/   初级教程:朴素部署 v0 与备份脚本(对照组)
.github/        CI + 部署 workflow(参考实现)
```

`.env.example` 里只有变量名,真实 `.env` 永远不进 git。
