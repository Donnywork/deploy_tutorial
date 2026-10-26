# English Tutorials — Index

A fully hands-on course in modern application deployment. No prior operations experience is required—and every single command comes with the "why" behind it.

## Learning Path

```
Beginner: one server, one domain, one HTTPS URL
      │  "I have a working Node app—how do I put it safely on the public internet?"
      ▼
Intermediate: push-to-deploy, automatic rollback
      │  "My manual deploy.sh is slow and error-prone—how do I automate releases safely?"
      ▼
Advanced: experiments, measurements, and architecture trade-offs
         "Now that we're scaling: zero downtime? Builds off the prod box? Short-lived credentials?"
```

## The Three Books

| Book | File | What you will build | What you will master |
|---|---|---|---|
| Beginner | [01-beginner.md](01-beginner.md) | A hardened VPS: systemd service management, Nginx reverse proxy, automated HTTPS, daily backups with a live restore drill, and a baseline deploy script | SSH keys & hardening, host firewalls, systemd unit lifecycle, reverse proxies, DNS/TLS fundamentals, and why "an untested backup is no backup" |
| Intermediate | [02-intermediate.md](02-intermediate.md) | A production-grade deployment pipeline: GitHub Actions → SSH forced command → atomic symlink switch → deep health checks → automatic rollback | Least-privilege user separation, atomic releases, treating rollback as a first-class citizen, and version-asserting health checks |
| Advanced | [03-advanced.md](03-advanced.md) | Blue-green zero-downtime switching, CI-built artifacts, a pull-based deployment prototype, short-lived SSH certificates, and measured RPO/RTO disaster recovery | How to quantify reliability investments with real measurements—knowing when an architectural upgrade is worth the complexity, and when it is not |

## Course Conventions

- **[local]** / **[server]**: Every command is explicitly tagged with where it runs. Unless noted otherwise, server commands assume you are logged in over SSH as your day-to-day admin user (`sam` throughout the course), using `sudo` explicitly whenever root privileges are required.
- When a code block opens with `# file: path`, it represents the complete contents of the file to create or update at that path.
- ✅ **Checkpoint**: End-of-chapter verification checklists. Make sure every item passes before moving on to the next chapter.
- 🧪 **Try it**: Hands-on experiments and failure drills. The text tells you exactly what behavior and output you should observe.
- ⚠️ **Warning**: High-risk operations capable of locking you out of your own server if run carelessly. Follow the safety steps closely.
- Every book opens with a clear **prerequisites checklist** covering budget, time commitment, and required accounts.

## Stuck? Ask an AI Teaching Assistant

This repository is **AI-ready** out of the box. Open the repository root in any context-aware AI coding assistant (Claude Code, Cursor, GitHub Copilot, etc.) and ask questions in plain English. The teaching assistant protocol defined in `AGENTS.md` ensures the AI will:

1. **Locate your stage first**: Identify which book and chapter you are working on (asking at most one brief clarifying question if it cannot infer your position);
2. **Move one step at a time**: Give you a single command per turn—complete with its execution target (`[local]` or `[server]`) and expected output—and wait for your result before continuing;
3. **Never spoil future chapters**: Answer out-of-scope questions with a concise one-sentence summary and a pointer to the exact chapter where the topic is formally covered;
4. **Diagnose errors systematically**: Route errors through the built-in troubleshooting knowledge base (`ai/troubleshooting.md`, covering cases T-01 through T-32), walking you through the diagnostic method step by step;
5. **Respect strict safety guardrails**: Never ask for real private keys or production secrets, and always verify you are on a disposable lab machine before suggesting destructive commands.

## Where Should I Start?

- **Never deployed an application to a server before** → Start at **Beginner, Chapter 0**, and work through every chapter in order. Do not skip ahead.
- **Comfortable with systemd, Nginx, and HTTPS, but still deploying manually** → Run through the **Prerequisite Self-Check at the top of the Intermediate book**. If you can check off every item, jump straight into **Intermediate**.
- **Already running automated CI/CD, looking to tackle zero-downtime releases, credential hygiene, or disaster recovery** → Verify you pass that same Intermediate self-check effortlessly, then dive straight into **Advanced**.

## Frequently Asked Questions

- **How much will this cost?** An entry-level VPS costs roughly $4–6/month (billed hourly with most cloud providers, so you can destroy it as soon as you finish), and a domain name costs $1–10/year. For the load-testing and comparison labs in the Advanced book, you can spin up a temporary hourly server and delete it right after the lab.
- **The demo app is written in Node.js, but my stack is Python / Go / Java. Is this course still relevant?** Completely. The deployment architecture you build here—privilege separation, release directory layout, systemd supervision, atomic symlink switching, deep health checks, and instant rollback—is completely language-agnostic. Every book concludes with a "Porting to Your Own Project" checklist, and Advanced Book, Chapter 11 walks through a complete migration using a tiny Go service.
- **Could I accidentally break my own machine or lock myself out?** Destructive experiments are strictly confined to your disposable lab VPS, with blast radius and recovery steps clearly marked in advance. The SSH and firewall chapters even include a deliberate, guided "lockout drill" so you can practice recovering safely before a real incident ever happens.
- **Do I need to memorize custom terminology or code numbers?** Not at all. Every architectural trade-off is framed in plain engineering terms ("build once, deploy everywhere", "an untested backup is no backup") alongside the exact chapter where it is proven in practice. Each book also states its architectural assumptions up front—such as "our current backups have blind spots" or "shallow health checks can lie"—and systematically tests and resolves every single one, culminating in a full audit in Advanced Book, Chapter 10.
