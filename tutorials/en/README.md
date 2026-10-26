# English Tutorials — Index

A fully hands-on deployment course. No ops experience required — but every command comes with the "why".

## Learning Path

```
Beginner: one server, one domain, one HTTPS URL
      │  "I have a working Node app — how do I put it on the internet?"
      ▼
Intermediate: push-to-deploy, automatic rollback
      │  "My manual deploy.sh is slow and error-prone — how do I automate it safely?"
      ▼
Advanced: experiments, measurements, and upgrade decisions
         "Now that we're scaling: zero downtime? Builds off the prod box? Stolen credentials?"
```

## The Three Books

| Book | File | You will build | You will understand |
|---|---|---|---|
| Beginner | [01-beginner.md](01-beginner.md) | A hardened VPS: systemd service, Nginx reverse proxy, HTTPS, daily backups + a restore drill, a naive deploy script | SSH & keys, firewalls, systemd, reverse proxies, DNS/TLS, "an untested backup is no backup" |
| Intermediate | [02-intermediate.md](02-intermediate.md) | A full deploy pipeline: GitHub Actions → SSH forced command → atomic switch → health checks → auto-rollback | Least privilege, atomicity, release/rollback as first-class citizens, health checks that assert versions |
| Advanced | [03-advanced.md](03-advanced.md) | Blue-green switching, CI-built artifacts, a pull-based prototype, short-lived SSH certs, measured RPO/RTO | When reliability investments are worth it — and when they are not (P13) |

## Conventions

- **[local]** / **[server]**: every command is tagged with where it runs. Server commands assume you are SSH'd in as your day-to-day user (called `sam` in the course); `sudo` is written explicitly where root is needed.
- If a code block starts with `# file: path`, it is the full content of a file to create/edit.
- ✅ **Checkpoint**: end-of-chapter self-tests. Pass them all before moving on.
- 🧪 **Try it**: hands-on experiments — the tutorial shows you exactly what you should observe.
- ⚠️ **Warning**: operations that can lock you out of your own server (yes, really).
- Each book opens with a "prerequisites" list (money, time, accounts).

## Stuck? Just Ask an AI

This repository is **AI-ready**: open its root in any repo-aware AI assistant (Claude Code, Cursor, Copilot...), and ask questions in plain language. The assistant protocol (in `AGENTS.md`) guarantees it will:

1. **Locate you first** (which book, which chapter — one question, never an interrogation);
2. **Guide one step at a time** — every command tagged with where it runs and its expected output; it waits for your result before continuing;
3. **Never spoil** future stages — for out-of-scope questions it gives the one-sentence version plus where it will be taught properly;
4. **Route errors through the troubleshooting DB** (`ai/troubleshooting.md`, T-01~T-32), following its diagnostic order while teaching you the method;
5. Never ask for real secrets, and confirm you're on a lab machine before anything destructive.

## Where Should I Start?

- Never deployed anything → **Beginner, from the top. Don't skip.**
- Already comfortable with systemd + Nginx + HTTPS, but deploy by hand → take the **prerequisite self-check at the top of Book 02**; if you pass, jump into **Intermediate**.
- Already have CI/CD, want zero-downtime/credentials/DR improvements → pass that same self-check with ease, then start at **Advanced**.

## FAQ

- **How much does it cost?** A minimal VPS is ~$4–6/month (destroyable when done); a domain ~$1–10/year. The advanced book's experiments suggest an hourly-billed box you delete afterwards.
- **The demo app is Node. I use Python/Go/Java — will this help?** The deployment skeleton (users/directories/systemd/switching/health checks/rollback) is language-agnostic. Every book ends with a "port it to your own project" checklist; Advanced Book, Chapter 11 demonstrates a full port to a tiny Go app.
- **Will this break my own server?** Destructive experiments only ever run on your lab server, with risks flagged. SSH/firewall chapters include a deliberate "lockout drill" (principle P8).
- **How does this relate to `deploy-experiment-prompt.md`?** That document is the design source (an unverified deployment reference design + 13 industry principles). The course splits it into three levels; every hypothesis (H1–H11) and principle (P1–P13) is confirmed or fixed along the way — index in Advanced Book, Chapter 10.
