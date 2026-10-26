# Deploy Tutorial — 从零到一的部署实战教程 / A Hands-On Deployment Course

一套**边做边学**的部署教程:用一个小到能读完全部源码的应用,带你从"第一次 SSH 登录服务器"一路走到"GitHub 推送即部署、失败自动回滚、凭证短寿命、蓝绿切换"。

本教程源自 [deploy-experiment-prompt.md](./deploy-experiment-prompt.md) 中那套"SSH 推送式自动部署"参考设计,把它拆成了**初级 → 中级 → 高级**三级递进的课程,每级解决上一级暴露的真实痛点。

> A hands-on, project-based deployment course: start from your first SSH login, end with push-to-deploy, automatic rollback, and blue-green switching. Derived from the reference design in `deploy-experiment-prompt.md`, split into three progressive levels (beginner → intermediate → advanced), each level fixing the pain points exposed by the previous one.

## 目录结构 / Structure

```
deploy_tutorial/
├── AGENTS.md                      # AI 助教协议(用 AI 工具打开本仓库时自动生效)
├── CLAUDE.md                      # Claude Code 入口(指向 AGENTS.md)
├── site/                          # 可发布到你网站的总览页
│   ├── index.html                 #   自包含落地页(中英切换,无外部依赖)
│   └── llms.txt                   #   给 AI agent 读取的站点入口(含助教协议摘要)
├── deploy-experiment-prompt.md   # 原始设计 prompt(教程的源头,只读)
├── ai/                            # AI 助教的知识底座
│   ├── stage-map.md               #   阶段地图:学到哪了/能讲什么/不剧透什么
│   ├── troubleshooting.md         #   排错库:T-01~T-32,报错原文 → 分步排查
│   └── faq.md                     #   概念 FAQ:"为什么不用 K8s" 类问题
├── demo-app/                     # 贯穿全部教程的最小示例应用(完整可运行)
│   ├── src/                      # web + worker + 迁移器 + 配置预检
│   ├── migrations/               # SQL 迁移(含向后兼容与破坏性示例)
│   ├── deploy/                   # 中级:参考设计的完整服务器侧实现
│   │   └── naive/                # 初级:朴素部署 v0(用来"审判"的对照组)
│   └── .github/workflows/        # CI + 部署 workflow(参考实现)
└── tutorials/
    ├── zh/                       # 中文教程(初级/中级/高级)
    └── en/                       # English tutorials (beginner/intermediate/advanced)
```

## 在线总览页 / Landing Page

想把课程介绍分享给别人?`site/index.html` 是一个**自包含**的总览页(无外部依赖、自带中英切换),把三级路线、16 步部署管线全景、H1–H11 验证状态、demo-app、AI 助教串在一页里。发布方法:

- **放到你的网站**:上传 `site/` 目录,按文件顶部注释把 `REPO_BLOB_BASE` 改成你的 GitHub 仓库地址(一行配置);
- **整套仓库静态托管**(如 GitHub Pages):把 `REPO_BLOB_BASE` 设为空字符串,链接自动变为相对路径。
- 同目录的 `site/llms.txt` 是给 AI agent 读取的站点入口(含助教协议摘要),放到网站根目录的 `/llms.txt` 效果最佳。

## 卡住了?问 AI / Stuck? Ask an AI

这个仓库是 **AI-ready** 的:用任何支持读取仓库上下文的 AI 编程助手(Claude Code、Cursor、Copilot 等)打开**本仓库根目录**,直接用大白话提问即可。AI 会遵循 `AGENTS.md` 里的助教协议:

- **先定位你的进度**(不知道你在哪一册哪一章时,会先问一句,而不是瞎猜);
- **按阶段回答**:只用你当前阶段能理解的概念,不剧透后面章节,一次只带你走一步,每步告诉你预期看到什么;
- **报错有据可查**:先匹配 `ai/troubleshooting.md`(T-01~T-32),按排查顺序一步步带,顺便教会你自己排查;
- **安全底线**:绝不会让你贴出真实密钥;破坏性操作会先确认你在实验机上。

试试这些问题:

- 「ssh 报 Permission denied (publickey) 怎么办?」
- 「我在初级第 5 章,curl 域名返回 502」
- 「为什么教程要在生产机上构建?这样安全吗?」
- 「中级部署失败了,Actions 日志最后是 FAILED step=migrate」

> 把本仓库模式搬到你自己的项目:复制 `AGENTS.md` + `ai/` 目录过去,在 `ai/stage-map.md` 里把阶段表换成你项目的路线图即可。


## 学习路线 / Learning Path

| 级别 | 主题 | 解决什么问题 | 前置 | 预计用时 |
|---|---|---|---|---|
| **初级** [zh](tutorials/zh/01-beginner.md) / [en](tutorials/en/01-beginner.md) | 把应用可靠地跑在一台服务器上(systemd + Nginx + HTTPS + 备份演练 + 朴素部署脚本) | 个人开发者/小公司最常碰到的:代码怎么上服务器、怎么常驻、怎么绑域名加 HTTPS、怎么不丢数据 | 会用终端,有一台 ~$5/月 的 VPS | 3–5 小时 |
| **中级** [zh](tutorials/zh/02-intermediate.md) / [en](tutorials/en/02-intermediate.md) | 参考设计完整实现:推送即部署、原子切换、健康检查断言版本、自动回滚、最小权限 | 朴素脚本的"八宗罪":停机窗口、无回滚、生产机构建、无健康检查、权限过大、无审计 | 完成初级(或已有同等环境) | 4–6 小时 |
| **高级** [zh](tutorials/zh/03-advanced.md) / [en](tutorials/en/03-advanced.md) | 对比实验与升级决策:蓝绿、CI 构建产物、Pull 模式、短寿命凭证、RPO/RTO 演练、何时上 K8s | 规模化诉求:零停机、构建不影响线上、凭证被盗的爆炸半径、灾备真的能恢复吗 | 完成中级 | 6–10 小时 |

## 与原始 prompt 的映射 / Coverage Map

教程完整覆盖了 `deploy-experiment-prompt.md` 的全部内容,具体位置:

| prompt 内容 | 教程位置 |
|---|---|
| §3 参考设计(强制命令、releases/current、原子切换、健康检查、回滚) | 中级 第 2–7 章 |
| §4 D1 构建位置(服务器 vs CI 产物) | 高级 第 3 章 |
| §4 D2 触发通道(Push-SSH vs Pull) | 高级 第 4 章 |
| §4 D3 切换方式(重启 vs 蓝绿) | 高级 第 2 章 |
| §4 D4 凭证(静态密钥 vs 短期证书) | 高级 第 5 章 |
| §5 最小被测应用(web+worker、迁移、fixture) | `demo-app/`(全程使用) |
| §7 场景矩阵 A/B/C/D/E/F | 中级 第 9 章(P0 剧场)+ 高级 第 10 章(练习册全表) |
| 假设 H1–H11 | 每条都有"证实/证伪 + 修正",索引见高级 第 10 章 |
| 原则 P1–P13 | 初中高每章开头有"本章原则"框,索引见高级 第 10 章 |
| §8 度量 | 高级 第 1 章(测量工具箱)+ 各实验记录表 |
| §9 交付物(模板/第二技术栈/报告/runbook) | `demo-app/deploy/`(参数化模板)、高级 第 11 章(Go 迁移实战)、各册 runbook |
| §10 分阶段工作方式 | 教程本身按 痛点→方案→实验→结论 组织;高级册 1.4 的实验记录模板要求"假设/步骤/观察/结论/升级触发"五要素 |

## demo-app 一览 / The Demo App

| 端点 | 用途 | 教学点 |
|---|---|---|
| `GET /health/live` | 进程活着 | 健康检查分层 |
| `GET /health/ready` | 真实读写一次数据库 | "端口通了 ≠ 正常"(P3) |
| `GET /version` | 返回构建时注入的 SHA | 部署后断言"真的是新版本"(P3/P4) |
| `GET/POST /api/notes` | 业务接口 + 入队任务 | worker 队列演示 |
| `GET /api/jobs/:id` | 查看任务状态 | 至少一次语义、幂等 |
| `POST/GET /api/files` | 写入文件存储目录 | 备份范围不只数据库(P5) |

## 安全提示 / Safety

- 教程中所有破坏性实验(坏迁移、断电演练、恶意构建)都在**你自己的实验服务器**上进行,并明确标注 ⚠️。
- 教程只生成一次性的实验密钥,不会接触任何真实项目的 `.env` 或密钥。
- 高级册的前置与收尾章节说明了实验机的计费、销毁与密钥清理(本地/服务器/GitHub 三处)。
