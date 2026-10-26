# 🚩 Challenge: 🚢 Zero to Production

A hands-on deployment course in three levels, bilingual ([中文](tutorials/zh/README.md) / [English](tutorials/en/README.md)). You start with your very first SSH login on a $5 VPS and finish with push-to-deploy, automatic rollback, blue-green switching, short-lived credentials, and a disaster-recovery drill with real RPO/RTO numbers.

🌟 **The final deliverable**: your app running 24/7 on a real server, behind your own domain with HTTPS. Updates ship with `git push`; a broken release rolls itself back before you've finished reading the alert; and when someone says "we should move to Kubernetes", you answer with measurements from your own drills — not vibes.

🧑‍🎓 **No ops experience required.** Every concept is explained the first time it appears, every chapter ends with a checkpoint, and the levels are a staircase on purpose: each one exists because the previous level's approach will eventually hurt you.

💬 Stuck at any point? This repo ships with a **built-in AI teaching assistant** — open the repo root in Claude Code, Cursor, or Copilot and ask in plain language. See [🤖 AI-Guided Learning Mode](#-ai-guided-learning-mode).

---

## Checkpoint 0: 📦 Environment

Before you begin, you need:

- [Node.js ≥ 24](https://nodejs.org/) and [pnpm](https://pnpm.io/installation)
- [Docker](https://www.docker.com/products/docker-desktop/) (the demo app runs Postgres via `docker compose`)
- A **lab VPS**: ~$4–6/month (add an hourly-billed box for Advanced experiments — usually <$1 total, destroy it afterwards)
- A **domain**: ~$1–10/year
- 13–21 hours across the three levels

Then download the course and run the demo app locally:

```sh
git clone https://github.com/Donnywork/deploy_tutorial.git
cd deploy_tutorial/demo-app
pnpm install
cp .env.example .env        # fill POSTGRES_PASSWORD with anything random
docker compose up -d db
pnpm run migrate
pnpm run build
pnpm run dev                # http://127.0.0.1:3000
```

📱 Open [http://127.0.0.1:3000/health/ready](http://127.0.0.1:3000/health/ready) — you should see a JSON status `ok`.

> 🤔 **Why a demo app?** Because deployment only bites when there's a real app involved: web + worker processes, a database with migrations, file storage, a build-time version stamp. This one is small enough to read every line — so you can focus on the deployment around it.

⚠️ Everything destructive in this course happens on **your lab server**, always flagged ⚠️ in the text. Never rehearse on a machine serving real users.

---

## Checkpoint 1: 🧱 Beginner — one server, one domain, one HTTPS URL

📖 **Read**: [中文](tutorials/zh/01-beginner.md) · [English](tutorials/en/01-beginner.md) · ⏱ 3–5h

Buy a VPS, lock it down, and put a real app on the internet:

- 🔑 SSH keys instead of passwords, firewall, and a deliberate **lockout drill**
- ♻️ systemd so your app survives crashes and reboots
- 🌐 Nginx + HTTPS on your own domain
- 💾 Daily backups **and a real restore drill** — an untested backup is no backup
- 🐢 A naive `deploy.sh`, kept on purpose as the villain of Chapter 7: watch it commit the **eight deadly sins** of deployment with your own eyes

✅ **Checkpoint**: `https://your-domain` serves your app over HTTPS, and you've restored the database from backup at least once.

---

## Checkpoint 2: ⚙️ Intermediate — push-to-deploy with automatic rollback

📖 **Read**: [中文](tutorials/zh/02-intermediate.md) · [English](tutorials/en/02-intermediate.md) · ⏱ 4–6h

Now fix the eight sins properly. This level is a complete, copyable pipeline:

- 👥 Three users, least privilege, sudoers whitelist
- 🔒 SSH forced commands — the deploy key can run exactly one thing
- 🧊 Atomic switch via `releases/current`
- 🩺 A health check that **asserts the deployed SHA** — "port is open" is not "healthy"
- ⏪ First-class rollback: `rollback.sh`, drilled, not theoretical
- 🤖 GitHub Actions: green CI on `main` → SSH deploy
- 🎭 **Bad-commit theater**: 8 deliberately broken commits (bad migration, missing env, bad config…) to prove every failure mode recovers

✅ **Checkpoint**: push to `main` → CI → deploy → health-gated switch. Sabotage a release on purpose and watch it roll back automatically.

---

## Checkpoint 3: 🧪 Advanced — experiments, measurements, upgrade decisions

📖 **Read**: [中文](tutorials/zh/03-advanced.md) · [English](tutorials/en/03-advanced.md) · ⏱ 6–10h

Every section is one experiment, always in the same format:

```
Hypothesis → Steps → Observe → Verdict (+ upgrade trigger)
```

- 🟦🟩 Blue-green vs restart — measured in seconds of real downtime
- 🏭 Build on server vs CI artifacts · push vs pull · short-lived SSH certificates
- 💥 kill -9 / power loss / OOM labs: break production on purpose, watch it self-heal
- 📊 RPO/RTO numbers for your backups — from "should work" to "proven, with a stopwatch"
- 🐘 The honest decision table: **when is Kubernetes actually worth it?** (often: not yet)

✅ **Checkpoint**: you can answer "should we upgrade X?" with data from your own drills.

---

## 🤖 AI-Guided Learning Mode

This repo is **AI-ready**. Open the repo root in any AI coding tool (Claude Code, Cursor, Copilot…) and just ask in plain language. The teaching-assistant protocol lives in [AGENTS.md](AGENTS.md), backed by a knowledge base in [ai/](ai/):

1. 📍 **It locates you first** — which book, which chapter (it asks one question if unsure, not twenty)
2. 🎚 **Calibrated to your level** — no spoilers from chapters you haven't reached
3. 🐢 **One step at a time** — one command, the expected output, then it waits for you to paste results back
4. 🔎 **Errors route through a troubleshooting library** — T-01…T-32 in [ai/troubleshooting.md](ai/troubleshooting.md); it teaches you to debug instead of just fixing
5. 🛡 **Safety rails** — never asks for real secrets; destructive ops require a "this is my lab machine" confirmation

Try:

- 「ssh 报 Permission denied (publickey) 怎么办?」
- "I'm in beginner chapter 5 and curl returns 502"
- "deploy failed, the Actions log ends with `FAILED step=migrate`"

> ♻️ **Reuse the pattern in your own project**: copy `AGENTS.md` + `ai/`, then swap the stage table in `ai/stage-map.md` for your own roadmap.

---

## 🧪 The demo app

`demo-app/` is deliberately boring — small enough to read fully — but it trips every deployment wire:

| Endpoint | What it does | Why it matters |
|---|---|---|
| `GET /health/live` | process is alive | liveness vs readiness — a health check must assert the real thing |
| `GET /health/ready` | one real DB roundtrip | "port open" ≠ "working" |
| `GET /version` | build-time injected SHA | assert you deployed what you think you did |
| `GET/POST /api/notes` | business API + enqueues a job | why there's a worker |
| `GET /api/jobs/:id` | job status | at-least-once semantics + idempotency |
| `POST/GET /api/files` | writes to the storage dir | backups aren't just databases |

`demo-app/deploy/` is the **complete server-side reference implementation** of the Level 2 pipeline. When porting it to your own project, start at [`deploy/app.conf`](demo-app/deploy/app.conf) — that's the one file you mostly need to change.

---

## ❓ FAQ

<details><summary>💰 What does it cost?</summary>

A minimal VPS is ~$4–6/month (destroy it when done); a domain ~$1–10/year. The Advanced experiments recommend an hourly-billed box — usually under $1 total.
</details>

<details><summary>🟢 My app is Python/Go/Java, not Node. Still useful?</summary>

Yes. The deployment skeleton (users, directories, systemd, atomic switch, health check, rollback) is language-agnostic. Every book ends with a "port it to your own project" checklist, and Advanced Chapter 11 proves it by porting the whole pipeline to a tiny Go app (~15 changed lines, measured).
</details>

<details><summary>💥 Will this break my server?</summary>

Destructive experiments only ever run on your lab server, flagged ⚠️, and the SSH/firewall chapters include a deliberate lockout drill so a real lockout isn't your first. Bottom line: never on a machine with real users.
</details>

---

## ⚔️ Side Quests

- 🚚 **Port it to your real project** — start from `demo-app/deploy/app.conf` plus the checklist at the end of each book. On a lab machine first.
- 🔒 **The lockout drill** — get locked out of your own server on purpose, then get back in (Advanced, Appendix B).
- 🌐 **Publish the landing page** — `site/index.html` is a self-contained course overview (bilingual, zero external deps) and `site/llms.txt` is the entry point for AI agents. Drop both on any static host.

## 🛡 Safety

- All destructive experiments run on **your own lab server**, flagged ⚠️.
- The course only generates one-off throwaway keys — it will never touch your real `.env` or production credentials.
- The Advanced book covers billing, teardown, and key cleanup (local / server / GitHub) up front and at the end.

---

> 🏃 **Start now**: [Level 1 · 中文](tutorials/zh/01-beginner.md) · [Level 1 · English](tutorials/en/01-beginner.md)
>
> 💬 Problems, questions? Open an issue — the AI teaching assistant reads this repo too.
