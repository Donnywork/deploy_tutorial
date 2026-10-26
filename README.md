# 🚩 Challenge: 🚢 Zero to Production

A hands-on, three-stage course in modern application deployment, available in both [中文](tutorials/zh/README.md) and [English](tutorials/en/README.md). You start with your very first SSH login on a $5 VPS and finish with automated push-to-deploy, self-healing rollbacks, blue-green zero-downtime switching, short-lived SSH certificates, and a live disaster-recovery drill backed by stopwatch-measured RPO/RTO numbers.

🌟 **The final deliverable**: Your application running 24/7 on a real Linux server behind your own domain and automated HTTPS. Every `git push` to `main` ships safely; a broken release rolls itself back before you even finish reading the alert; and when someone suggests "we should move to Kubernetes," you can answer with empirical measurements from your own drills—not guesswork.

🧑‍🎓 **No prior ops experience required.** Every concept is introduced in plain language the moment it first appears, every chapter closes with a verifiable checkpoint, and the three stages form a deliberate staircase: each stage exists because the previous stage's shortcuts eventually break under real-world pressure.

💬 **Stuck at any step?** This repository includes a **built-in AI teaching assistant**. Open the repo root in Claude Code, Cursor, or GitHub Copilot and ask questions in plain language. See [🤖 AI-Guided Learning Mode](#-ai-guided-learning-mode).

---

## Checkpoint 0: 📦 Environment Setup

Before you begin, make sure you have:

- [Node.js ≥ 24](https://nodejs.org/) and [pnpm](https://pnpm.io/installation)
- [Docker](https://www.docker.com/products/docker-desktop/) (the companion app runs PostgreSQL locally via `docker compose`)
- A **lab VPS**: ~$4–6/month (plus an optional hourly-billed box for the Advanced experiments—typically under $1 total before you delete it)
- A **domain name**: ~$1–10/year
- **13–21 hours** total across all three stages

Clone the repository and spin up the companion app locally:

```sh
git clone https://github.com/Donnywork/deploy_tutorial.git
cd deploy_tutorial/demo-app
pnpm install
cp .env.example .env        # set POSTGRES_PASSWORD to any random string
docker compose up -d db
pnpm run migrate
pnpm run build
pnpm run dev                # http://127.0.0.1:3000
```

📱 Open [http://127.0.0.1:3000/health/ready](http://127.0.0.1:3000/health/ready) in your browser—you should see a JSON response with status `"ok"`.

> 🤔 **Why include a demo app?** Because deployment only gets real when the application has real moving parts: separate web and worker processes, database schema migrations, persistent file storage, and a build-time version stamp. `demo-app` is compact enough to read end-to-end in ten minutes, yet complete enough to exercise every failure mode in a production pipeline.

⚠️ Every destructive experiment in this course runs strictly on **your disposable lab server** and is clearly marked with ⚠️. Never rehearse destructive drills on a machine serving real production traffic.

---

## Checkpoint 1: 🧱 Beginner — One Server, One Domain, One HTTPS URL

📖 **Read**: [中文](tutorials/zh/01-beginner.md) · [English](tutorials/en/01-beginner.md) · ⏱ 3–5 hours

Provision a raw VPS, harden it from scratch, and put a real database-backed web app on the public internet:

- 🔑 SSH key authentication, host firewall (`ufw`), and a guided **lockout prevention drill**
- ♻️ `systemd` process supervision so your app survives crashes and server reboots automatically
- 🌐 Nginx reverse proxy + automated Let's Encrypt HTTPS on your own domain
- 💾 Automated daily backups **plus a live restore drill**—because an untested backup is no backup at all
- 🐢 A deliberately naive `deploy.sh` that sets up Chapter 7's finale: watching it commit the **Eight Deadly Sins of Deployment** firsthand

✅ **Stage Goal**: `https://your-domain` serves your application over HTTPS, and you have successfully wiped and restored the database from a real backup archive.

---

## Checkpoint 2: ⚙️ Intermediate — Push-to-Deploy with Automatic Rollback

📖 **Read**: [中文](tutorials/zh/02-intermediate.md) · [English](tutorials/en/02-intermediate.md) · ⏱ 4–6 hours

Eliminate every single flaw in the naive script by building a production-grade, copy-pasteable deployment pipeline:

- 👥 Three-user privilege separation (`sam` / `deploy` / `app`) with a tight `sudoers` whitelist
- 🔒 SSH forced commands (`deploy-entry`)—the CI deploy key can execute one controlled pipeline and nothing else
- 🧊 Atomic release switching via the `releases/current` symlink
- 🩺 Deep health checks that **assert the live Git SHA**—proving the new code is actually serving traffic, not just holding a port open
- ⏪ First-class rollback (`rollback.sh`), tested under fire rather than assumed to work
- 🤖 GitHub Actions integration: green CI on `main` triggers an automated SSH release
- 🎭 **Bad-Commit Theater**: 8 intentionally sabotaged commits (broken migration, missing env var, syntax error, hung worker…) to prove your pipeline catches and rolls back every failure mode automatically

✅ **Stage Goal**: Pushing to `main` runs CI, deploys atomically, verifies health, and automatically reverts to the previous release whenever a bad build slips through.

---

## Checkpoint 3: 🧪 Advanced — Experiments, Measurements, and Upgrade Decisions

📖 **Read**: [中文](tutorials/zh/03-advanced.md) · [English](tutorials/en/03-advanced.md) · ⏱ 6–10 hours

Every chapter is structured as a rigorous engineering experiment:

```
Hypothesis → Steps → Observe → Verdict (+ when to upgrade)
```

- 🟦🟩 **Blue-green switching vs. in-place restart**—measured in milliseconds of real request downtime under load
- 🏭 **Server-side builds vs. CI-built artifacts**, **Push vs. Pull deployment**, and **short-lived SSH certificates** (CA-signed)
- 💥 **`kill -9`, sudden power loss, and OOM labs**—break production processes on purpose and verify self-healing guarantees
- 📊 **Measured RPO & RTO**—turn "we have backups" into stopwatch-verified recovery metrics
- 🐘 **The Architecture Decision Matrix**—concrete thresholds for when you actually need Kubernetes, containers, or multi-node setups (and why you probably don't yet)

✅ **Stage Goal**: You can evaluate any proposed infrastructure upgrade using quantitative data from your own benchmarks.

---

## 🤖 AI-Guided Learning Mode

This repository is **AI-ready** out of the box. Open the project root in any repo-aware AI coding assistant (Claude Code, Cursor, GitHub Copilot, etc.) and ask questions in plain Chinese or English. Driven by the teaching protocol in [AGENTS.md](AGENTS.md) and the structured knowledge base in [ai/](ai/), the assistant will:

1. 📍 **Pinpoint your stage first** — Determines which book and chapter you are on (asking at most one quick clarifying question if needed)
2. 🎚 **Match your current level** — Explains concepts using only what you have learned so far, without spoiling future chapters
3. 🐢 **Guide you one step at a time** — Gives a single command tagged with `[local]` or `[server]`, tells you what output to expect, and waits for your result before moving on
4. 🔎 **Diagnose errors systematically** — Routes symptoms through the 32-case troubleshooting catalog in [ai/troubleshooting.md](ai/troubleshooting.md), teaching you *how* to debug rather than dumping unverified fixes
5. 🛡 **Enforce strict safety guardrails** — Never asks for real private keys or `.env` secrets, and requires explicit lab-machine confirmation before any destructive command

Try asking:

- 「ssh 报 Permission denied (publickey) 怎么办？」
- `"I'm in Beginner Chapter 5 and curl returns 502 Bad Gateway"`
- `"My deploy failed and the GitHub Actions log ends with FAILED step=migrate"`

> ♻️ **Steal this pattern for your own team**: Copy `AGENTS.md` and `ai/` into your own repository, and swap the stage table in `ai/stage-map.md` for your internal onboarding roadmap.

---

## 🧪 Inside `demo-app`

`demo-app/` is intentionally minimal—every source file is under 50 lines—yet it exercises every critical boundary of a real production deployment:

| Endpoint | Behavior | Deployment Lesson |
|---|---|---|
| `GET /health/live` | Returns `200` if the HTTP process is up | Liveness ≠ readiness; shallow checks miss broken dependencies |
| `GET /health/ready` | Executes a real database round-trip | "Port is listening" does not mean "application can serve users" |
| `GET /version` | Returns the build-time injected `gitSha` | Health checks must prove the *expected* version is actually live |
| `GET/POST /api/notes` | CRUD API that enqueues background jobs | Coordinating web + worker processes across deployments |
| `GET /api/jobs/:id` | Inspects background job state | Graceful `SIGTERM` shutdown, at-least-once delivery, and idempotency |
| `POST/GET /api/files` | Reads/writes persistent disk storage | Why stateful backups must cover more than just PostgreSQL |

`demo-app/deploy/` contains the **complete server-side reference implementation** for the Intermediate pipeline. When adapting this architecture to your own project, start with [`deploy/app.conf`](demo-app/deploy/app.conf)—almost every project-specific setting lives in that single file.

---

## ❓ Frequently Asked Questions

<details><summary>💰 How much will the cloud resources cost?</summary>

An entry-level VPS costs roughly $4–6/month (and is billed hourly by most providers, so you can delete it as soon as you finish the course). A practice domain costs $1–10/year. The temporary secondary server used in the Advanced book's labs typically costs less than $1 before teardown.
</details>

<details><summary>🟢 My stack is Python / Go / Java, not Node.js. Is this course still useful?</summary>

Absolutely. The entire deployment architecture—user isolation, immutable release directories, systemd units, atomic symlink switching, deep health checks, and one-command rollback—is completely language-agnostic. Every book ends with a "Porting to Your Own Project" checklist, and Advanced Chapter 11 demonstrates a complete migration to a compiled Go service by changing roughly 15 lines of configuration.
</details>

<details><summary>💥 Could I accidentally break my own computer or production server?</summary>

Every destructive experiment takes place strictly on your disposable lab VPS and is clearly marked with ⚠️. Better still, the SSH and firewall chapters walk you through a controlled lockout drill early on, ensuring you know how to recover via out-of-band console access long before you touch a real production machine.
</details>

---

## ⚔️ Side Quests

- 🚚 **Port the pipeline to your own project** — Follow the migration checklist at the end of each book and customize `demo-app/deploy/app.conf` on a test server.
- 🔒 **Run the Lockout Drill** — Intentionally lock yourself out of SSH and practice recovering safely via VNC/serial console (Advanced Book, Appendix B).
- 🌐 **Host the course landing page** — `site/index.html` is a zero-dependency, bilingual course overview page, paired with `site/llms.txt` for AI agents. Drop both files onto any static hosting provider.

## 🛡 Safety Principles

- All destructive drills target **your isolated lab VPS** and are flagged with ⚠️.
- The course uses dedicated, disposable keys and never touches your personal `.env` files or production credentials.
- Complete teardown and credential-cleanup checklists (covering local machine, VPS, and GitHub Secrets) are provided at the end of the course.

---

> 🏃 **Start building**: [Level 1 · 中文](tutorials/zh/01-beginner.md) · [Level 1 · English](tutorials/en/01-beginner.md)
>
> 💬 Spotted a bug or got stuck? Open an issue—or ask your AI coding assistant right inside this repo.
