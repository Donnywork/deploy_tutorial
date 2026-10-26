# Intermediate: Push-to-Deploy, Automatic Rollback

> **What you'll learn**: After `git push`, GitHub Actions automatically notifies your server to run a sixteen-step pipeline — "fetch → build → preflight → backup → migrate → atomic switch → health check" — and automatically rolls back to the previous release if any step fails. Even if your deployment credential is stolen, all an attacker can do is trigger a legitimate deployment of `main`; they cannot read a single secret or open a shell.
>
> **Self-check prerequisites** (every box must be a confident "yes" before continuing):
> - [ ] I know what `journalctl -u xxx -n 50` does and have used it myself
> - [ ] My server runs Nginx + HTTPS, a systemd-managed app, Postgres in Docker, and `ufw` allowing only ports 22/80/443
> - [ ] I have completed at least one database restore drill (not just read about it — *actually restored a backup*)
> - [ ] I can name any three of the beginner book's "eight sins"
>
> If any box is unchecked, head back to the relevant chapter in the [beginner book](01-beginner.md) first.
>
> **Core principles in this book**: rollback safety, health checks that assert the real running version, zero tolerance for mixed states, least privilege, rollback as a first-class citizen, and end-to-end auditability.

**Deliverable**: A complete, portable production deployment system. Every script lives in `demo-app/deploy/` in the repository and installs into `/opt/demo-app/bin/` on the server. Porting this pipeline to your own project usually means editing a single file: `app.conf`.

---

## Chapter 1: From v0 to v1 — What We're Fixing

The beginner book closed by putting our naive v0 deployment script on trial for eight sins. This book's table of contents is the remediation plan:

| # | v0's sin | v1's fix | Engineering principle |
|---|---|---|---|
| 1 | Unbounded downtime window | Immutable `releases/<sha>/` directories + an atomic `current` symlink flip; only the brief process restart window remains (which the advanced book's blue-green switching eliminates) | Contained blast radius |
| 2 | Installing & building on the prod box | Retained as the baseline reference design, but failed builds never leave debris behind; the advanced book's build-location experiment measures when to move builds to CI | Build once, deploy everywhere; simplicity first |
| 3 | Half-finished states on failure | Stage every build in `.partial` and promote it to `releases/<sha>` with `mv` only after every build step succeeds | — |
| 4 | No real health check | Assert `/version` == target SHA + a real database read/write + worker heartbeat freshness + a 30-second soak window | Health checks must assert the real thing; no mixed states |
| 5 | Rollback by adrenaline | `rollback.sh`: works offline, never touches the database, completes in ~10 seconds — a first-class command | Rollback as a first-class citizen |
| 6 | The deploy script owns full `sudo` | Dedicated `deploy` user + SSH forced command + a narrow `sudoers` whitelist (only restart fixed units, backup, migrate, healthcheck, and audit) | Least privilege |
| 7 | No audit trail | Append structured lines to both `audit.log` and `logger` (syslog) on every deploy and rollback | Auditability |
| 8 | Code and migration skew | Failed migration aborts before switching code; strict "backup → migrate → switch" ordering; destructive migrations follow expand/contract (covered in the advanced book) | Rollback safety |

**The v1 pipeline at a glance** (keep this mental map handy — every section that follows builds one piece of it):

```
You                  GitHub                       Server
  │  git push          │                            │
  │───────────────────▶│ CI: install/test/build     │
  │                    │ (must pass before deploy)  │
  │                    │ ssh deploy@server          │
  │                    │   "deploy <40-hex-sha>"    │
  │                    │───────────────────────────▶│ deploy-entry (forced command, one format only)
  │                    │                            │   │ setsid (survives disconnects)
  │                    │   CI follows the log       │   ▼
  │                    │◀═══════════════════════════│ deploy.sh (as the deploy user):
  │                    │                            │  freeze check ─▶ flock ─▶ idempotency
  │                    │                            │  ─▶ fetch + ancestry check ─▶ preflight (disk/Node/lockfile)
  │                    │                            │  ─▶ build .partial ─▶ promote release
  │                    │                            │  ─▶ config preflight ─▶ backup ─▶ migrate
  │                    │                            │  ─▶ atomic switch of current ─▶ restart
  │                    │                            │  ─▶ health check + soak ──fail──▶ auto-rollback
  │                    │                            │  ─▶ retention ─▶ audit
```

---

## Chapter 2: Server Layout and the Three Users

### 2.1 Three identities, three job descriptions

| User | Role | Allowed to do | Forbidden from doing |
|---|---|---|---|
| `root` (you, via `sam`'s `sudo`) | System administrator | Everything; owns the deploy scripts, `sudoers`, and `deploy`'s `authorized_keys` | — (which is why you invoke it only for administrative changes) |
| `deploy` | CI's server-side avatar | Log in **only** through the SSH forced command; build releases; invoke 5 whitelisted commands via `sudo` | Read `runtime.env`, modify deploy scripts, open an interactive shell, transfer arbitrary files |
| `app` | The running service | Run the `web` and `worker` processes, read `runtime.env`, write to `storage/`, connect to Postgres | Log in over SSH, modify application code, touch deploy scripts |

> **Why split privileges across three accounts (least privilege)**: Consider the worst-case scenario — your CI's SSH private key leaks. With this separation, all an attacker can do is trigger a deployment of a commit that already exists on `main` and call the five whitelisted helper scripts. They cannot read your database password in `runtime.env`, nor can they alter the deploy scripts on disk. Want to deploy malicious code? The target SHA must be an ancestor of `origin/main`, and `main` is a protected branch. The blast radius of a leaked CI key is shrunk to the absolute minimum. In Chapter 5 of the advanced book, we'll go one step further and compare long-lived static keys against short-lived SSH certificates.

### 2.2 The directory layout

```
/opt/demo-app/              # the "machine" side: root-owned, writable by no one else
├── bin/                     #   deploy scripts (deploy.sh, rollback.sh, backup.sh ...)
├── env/runtime.env          #   root:app 0640 — only the app can read it
├── compose/                 #   docker-compose.yml + .env (Postgres)
└── freeze                   #   existence = refuse deployments (kill switch)

/srv/demo-app/               # the "application" side
├── repo.git/                #   bare mirror cache, owned by deploy (read-only deploy key)
├── releases/<40-hex-sha>/   #   one immutable directory per deployment
├── current → releases/<sha> #   the atomic switch (systemd follows this)
└── storage/                 #   file storage, written by app

/var/log/demo-app/           # deploy logs (keep 20) + audit.log
/var/backups/demo-app/       # db/ + storage/ backups
/run/demo-app/               # deploy lock (tmpfs; recreated by tmpfiles.d on boot)
```

> **Why `releases/<sha>` instead of an in-place `git pull`**: Giving every deployment its own immutable directory buys you three properties at once: instant rollback (just repoint the `current` symlink), built-in auditability (the directory name *is* the exact Git SHA running in production), and immutable build artifacts (never a half-pulled working tree). This has been the core of Capistrano's design for well over a decade — and it is well worth borrowing.

### 2.3 Migrating from the v0 layout

**[server]** First, retire v0's working tree, systemd unit, and Compose stack (**your database data stays safe** inside its Docker volume):

```bash
sudo systemctl disable --now demo-app
sudo rm /etc/systemd/system/demo-app.service
sudo cp /srv/demo-app/.env /tmp/demo-compose.env        # save the DB password
cd /srv/demo-app && sudo docker compose down      # volume preserved (demo-app_pgdata); plain sudo (app isn't in the docker group)
cd /srv && sudo mv demo-app demo-app-v0-backup
```

Next, clone the latest repository onto the server (so we can install the v1 deploy scripts from it) and run the bootstrap installer:

```bash
cd ~ && git clone git@github.com:yourname/demo-app.git demo-app-bootstrap
cd demo-app-bootstrap/deploy
sudo ./install.sh git@github.com:yourname/demo-app.git
```

`install.sh` (located at `deploy/install.sh`, ~100 lines — well worth reading top to bottom) performs nine setup steps: creates the `app` and `deploy` users with locked passwords → builds the directory tree shown above → installs the pipeline scripts into `/opt/demo-app/bin` (owned by `root`) → installs the `sudoers` file after validating it with `visudo -cf` → installs the systemd units (`enable` without `start`) → wires up Compose and `runtime.env` → clones the bare `repo.git` mirror cache → installs the daily backup cron job → prints the remaining manual steps.

Now restore the database password you saved from v0, re-run the idempotent installer to regenerate `runtime.env` with that password, and verify that your data from the beginner book is still intact:

```bash
sudo cp /tmp/demo-compose.env /opt/demo-app/compose/.env && rm /tmp/demo-compose.env
sudo rm -f /opt/demo-app/env/runtime.env    # regenerate it with the saved password
sudo ./install.sh git@github.com:yourname/demo-app.git   # idempotent; just rerun
docker exec demo-app-db psql -U demo_app -d demo_app -Atc "SELECT count(*) FROM notes"
# the count you created in the beginner book — data survived the move
```

Finally, move your uploaded file storage over from the v0 backup directory (file storage is a first-class citizen of our backup and deployment layout):

```bash
sudo rm -rf /srv/demo-app/storage
sudo cp -a /srv/demo-app-v0-backup/storage /srv/demo-app/storage
sudo chown -R app:app /srv/demo-app/storage
```

> `install.sh` is completely idempotent: existing data and state are left untouched. Whenever you update the scripts in `deploy/` in your repository, upgrading the server is simply "pull the repo → rerun `install.sh`". (What if someone edits a script in Git and forgets to rerun `install.sh` on the server? Chapter 7 of the advanced book adds automated drift detection for exactly that.)

✅ **Checkpoint**: `ls -la /opt/demo-app/bin | head -5` shows every script owned by `root`; `sudo ls -la /opt/demo-app/env/` shows `runtime.env` with permissions `-rw-r----- root app`.

---

## Chapter 3: deploy's Key — the SSH Forced Command

### 3.1 Generate the CI's keypair

**[local]**:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/demo_deploy_key -N "" -C "ci-deploy@demo-app"
```

The private key (`demo_deploy_key`) will go into GitHub Secrets in Chapter 8; the **public key** goes onto the server right now.

### 3.2 authorized_keys: a key that opens exactly one door

**[server]**:

```bash
sudo mkdir -p /home/deploy/.ssh
sudo tee /home/deploy/.ssh/authorized_keys >/dev/null <<'EOF'
restrict,command="/opt/demo-app/bin/deploy-entry" ssh-ed25519 AAAA... ci-deploy@demo-app
EOF
# ↑ replace AAAA... with the contents of ~/.ssh/demo_deploy_key.pub (one line)
sudo chown -R root:root /home/deploy/.ssh
sudo chmod 0755 /home/deploy/.ssh && sudo chmod 0644 /home/deploy/.ssh/authorized_keys
```

Three details here are load-bearing, and each one is deliberate:

1. **`restrict`**: Disables every extra capability on this key in one stroke — no pseudo-TTY allocation (`ssh -t` fails), no port forwarding (`-L`, `-R`, and `-D` all fail), and no X11 or agent forwarding.
2. **`command="..."`**: No matter what command the SSH client asks to run, `sshd` ignores it and executes `/opt/demo-app/bin/deploy-entry` instead. The client's original command string is passed via the `SSH_ORIGINAL_COMMAND` environment variable, where `deploy-entry` inspects and judges it.
3. **Both `/home/deploy/.ssh` and `authorized_keys` are owned by `root`**: The `deploy` user (or anyone who compromises a `deploy` process) **cannot modify their own `authorized_keys` file** to strip off the `restrict,command=...` options. The privilege-escalation drill in Chapter 10 of the advanced book puts this to the test.

> This is the hardened form of our reference design's "SSH push notification": port 22 remains reachable from the internet (the advanced book's pull model closes port 22 to CI entirely), but behind that door sits a mail slot just one centimeter wide.

### 3.3 deploy-entry: exactly one accepted input

Let's inspect `/opt/demo-app/bin/deploy-entry` (owned by `root`; full source in `deploy/deploy-entry`):

```sh
#!/bin/sh
set -eu

fail() { echo "deploy-entry: $*" >&2; exit "$1"; }

cmd="${SSH_ORIGINAL_COMMAND:-}"
[ -n "$cmd" ] || fail 64 "no command; only 'deploy <sha>' is allowed"

case "$cmd" in
  "deploy "*) sha="${cmd#deploy }" ;;
  *) fail 64 "refused: only 'deploy <sha>' is allowed (got: $cmd)" ;;
esac

case "$sha" in
  ""|*[!0-9a-f]*) fail 65 "sha must be exactly 40 lowercase hex chars (got: $sha)" ;;
esac
[ "${#sha}" -eq 40 ] || fail 65 "sha must be exactly 40 chars (got ${#sha})"

. /opt/demo-app/bin/app.conf
mkdir -p "$LOG_DIR"

# keep the newest 19 logs; this one becomes #20 (minimal log retention)
ls -1t "$LOG_DIR"/deploy-*.log 2>/dev/null | tail -n +20 | xargs -r rm -f
LOG="$LOG_DIR/deploy-$(date -u +%Y%m%dT%H%M%S)_$$.log"
touch "$LOG" && chmod 640 "$LOG"

logger -t deploy-entry "accepted sha=$sha from=${SSH_CONNECTION:-local}"

# the key design: the deploy runs detached from the SSH session
setsid /opt/demo-app/bin/deploy.sh "$sha" >"$LOG" 2>&1 </dev/null &
pid=$!
tail -n +1 -f "$LOG" --pid="$pid" || true
wait "$pid"
```

Two design choices here are worth internalizing:

- **The argument parser *is* the whitelist**: The two `case` blocks accept nothing except the literal prefix `deploy ` followed by exactly 40 lowercase hexadecimal characters. Abbreviated SHAs, uppercase hex, trailing arguments, `rm -rf`, or shell metacharacters (`deploy abc && ...`) are all rejected before anything else runs.
- **Session detachment via `setsid`**: `deploy.sh` runs in its own session, completely detached from the SSH connection. If the SSH connection drops mid-deploy (a CI job times out, or you close your laptop lid during a manual trigger), the deployment on the server keeps running cleanly to completion instead of dying halfway through. While connected, the SSH client simply watches the log file via `tail -f`; when `deploy.sh` finishes, `wait "$pid"` propagates its exact exit code back over SSH so GitHub Actions marks the workflow green or red accurately.

### 3.4 deploy's GitHub key (so repo.git can fetch)

```bash
# Note: /home/deploy/.ssh is root-owned (deploy cannot edit its own keys),
# so root generates the keypair and hands it over:
sudo ssh-keygen -t ed25519 -f /home/deploy/.ssh/id_ed25519 -N "" -C "deploy@server fetch key"
sudo chown deploy:deploy /home/deploy/.ssh/id_ed25519 /home/deploy/.ssh/id_ed25519.pub
sudo cat /home/deploy/.ssh/id_ed25519.pub
# paste into GitHub → repo Settings → Deploy keys (read-only!)
# Pre-seed GitHub's host key (otherwise git clone blocks on the fingerprint prompt):
sudo ssh-keyscan -t ed25519 github.com > /home/deploy/.ssh/known_hosts
sudo chown root:root /home/deploy/.ssh/known_hosts && sudo chmod 0644 /home/deploy/.ssh/known_hosts
```

> Notice the strict separation between the two SSH keys: `deploy@server fetch key` can only **read** the repository from GitHub (used by `git fetch`), whereas CI's `ci-deploy@demo-app` key can only **trigger deployments** on the server. Compromising either key on its own is not enough to mount an attack.

With the GitHub deploy key configured, re-run `install.sh` to complete step 7/9 (cloning the bare `repo.git` mirror cache), which couldn't succeed in Chapter 2 before the key existed:

```bash
cd ~/demo-app-bootstrap/deploy && sudo ./install.sh git@github.com:yourname/demo-app.git
# this time "== 7/9 repo mirror cache" should succeed
sudo ls /srv/demo-app/repo.git/HEAD >/dev/null && echo repo-cache-OK
```

### 3.5 The connection test matrix

**[local]** Run each command below and verify that the server's response matches the comment:

```bash
KEY=~/.ssh/demo_deploy_key; H=deploy@203.0.113.10

ssh -i $KEY $H "uptime"
# deploy-entry: refused: only 'deploy <sha>' is allowed (got: uptime)

ssh -i $KEY $H "deploy abc123"
# deploy-entry: sha must be exactly 40 lowercase hex chars

ssh -i $KEY $H "deploy 0000000000000000000000000000000000000000 extra"
# deploy-entry: sha must be exactly 40 lowercase hex chars (got: 0000...0000 extra)

echo hello | ssh -i $KEY $H "cat > /tmp/x"
# deploy-entry: refused (file transfer? not a thing here)

ssh -t -i $KEY $H
# deploy-entry: no command; only 'deploy <sha>' is allowed (interactive shell refused)

ssh -i $KEY -L 9999:localhost:5432 $H "deploy 0000000000000000000000000000000000000000" -N
# (fails immediately — restrict forbids forwarding; the database stays unreachable)
```

Now test one syntactically valid deployment command using a dummy 40-zero SHA. It passes `deploy-entry` at the door, enters `deploy.sh`, and gets rejected at the ancestry verification step inside the pipeline:

```bash
ssh -i $KEY $H "deploy 0000000000000000000000000000000000000000" 2>&1 | tail -3
# ... FAILED step=verify: SHA is not an ancestor of origin/main — rejected
```

✅ **Checkpoint**: All six malformed or unauthorized requests were stopped cold at the gate with clear error messages, while the syntactically valid fake SHA was caught inside the pipeline by the ancestry check — the doorman and the internal security scanner each did their job.

---

## Chapter 4: sudoers — a Least-Privilege Whitelist

`deploy.sh` runs as the unprivileged `deploy` user, but six specific operations along the pipeline require `root`: restarting the systemd units, running backups (`docker exec`), invoking the migration wrapper, running the config preflight check, running the health check, and writing to the audit log. Our `sudoers` file whitelists those exact scripts and their allowed argument patterns — nothing more:

**[server]** Inspect `cat ~/demo-app-bootstrap/deploy/demo-app.sudoers` (installed by `install.sh` at `/etc/sudoers.d/demo-app`):

```sudoers
deploy ALL=(root) NOPASSWD: /opt/demo-app/bin/backup.sh premigrate, \
    /opt/demo-app/bin/backup.sh daily, \
    /opt/demo-app/bin/backup.sh manual, \
    /opt/demo-app/bin/migrate-wrapper.sh [0-9a-f]*, \
    /opt/demo-app/bin/check-config.sh [0-9a-f]*, \
    /opt/demo-app/bin/healthcheck.sh [0-9a-f]*, \
    /opt/demo-app/bin/audit.sh *, \
    /usr/bin/systemctl restart demo-app-web, \
    /usr/bin/systemctl restart demo-app-worker, \
    /usr/bin/systemctl restart demo-app-web.service, \
    /usr/bin/systemctl restart demo-app-worker.service, \
    /usr/bin/systemctl restart demo-app-web demo-app-worker, \
    /usr/bin/systemctl restart demo-app-web.service demo-app-worker.service
```

> - **Absolute paths are mandatory**: Every command in `sudoers` must use a full path (`/usr/bin/systemctl`). This prevents the classic `PATH` hijacking trick where an attacker drops a fake `systemctl` binary into a writable directory earlier in `PATH`.
> - **Arguments define the boundary**: To `sudoers`, `systemctl restart demo-app-web` and `systemctl restart demo-app-web demo-app-worker` are two distinct rules — it matches the command *plus* its full argument string as a single unit. If someone tries `sudo systemctl stop ssh`, there is no matching rule, and `sudo` refuses.
> - **Sudoers globs are only the first layer**: In `sudoers` syntax, the `*` wildcard in `[0-9a-f]*` can match across spaces, which means a naive glob alone could be tricked into accepting extra arguments. That is why every wrapper script (`migrate-wrapper.sh`, `check-config.sh`, `healthcheck.sh`) immediately re-validates that it received **one and only one 40-character lowercase hex argument** — true defense in depth (Chapter 5 of the advanced book tests this exact boundary).
> - **`audit.sh *` is a conscious trade-off**: Because `deploy` can pass arbitrary arguments to `audit.sh`, it could theoretically forge an audit line — though `deploy` is already authorized to trigger real deployments anyway. Chapter 8 of the advanced book closes this gap by forwarding syslog events to a remote log host.

🧪 **Verify** (**[server]**, testing as the `deploy` user):

```bash
sudo -u deploy sudo systemctl restart demo-app-web
# (succeeds — whitelisted)
sudo -u deploy sudo ls /root
# Sorry, user deploy is not allowed to execute '/bin/ls /root' as root
sudo -u deploy cat /opt/demo-app/env/runtime.env
# cat: ... Permission denied   ← the DB password; deploy cannot read it
```

Remember the iron rule whenever you touch a `sudoers` file: always validate it with `sudo visudo -cf /etc/sudoers.d/demo-app`. **A syntax error in `/etc/sudoers.d/` can disable `sudo` across the entire machine** — leaving the cloud provider's emergency web console as your only way back in.

---

## Chapter 5: systemd Units — web + worker, Graceful Shutdown

In v1, the application runs as two separate systemd units (`deploy/demo-app-web.service` and `deploy/demo-app-worker.service`, both installed by `install.sh`). Here are the key lines from the web unit:

```ini
[Service]
User=app
Group=app
WorkingDirectory=/srv/demo-app/current        # ← resolve "current" to find the live version
EnvironmentFile=/opt/demo-app/env/runtime.env # ← the root:app 0640 file
ExecStart=/usr/bin/node /srv/demo-app/current/dist/server.js
Restart=on-failure
RestartSec=2
TimeoutStopSec=15                             # ← grace period for graceful shutdown
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
```

Every change from v0's unit file serves a specific purpose:

- **`WorkingDirectory` and `ExecStart` point through `/srv/demo-app/current`**: Deployments simply flip the `current` symlink and run `systemctl restart`; the unit files themselves never need to be edited or reloaded.
- **`TimeoutStopSec=15`**: On `restart`, systemd first sends `SIGTERM`. `server.js` catches `SIGTERM`, stops accepting new connections, drains any in-flight HTTP requests, and exits cleanly; `worker.js` finishes its current job before exiting (preserving at-least-once job semantics). If a process is still alive after 15 seconds, systemd follows up with `SIGKILL` — so your application's shutdown handler must be time-aware.
- **`Restart=on-failure` instead of `always`**: If an operator intentionally stops the service with `systemctl stop`, systemd shouldn't immediately resurrect it. Also note systemd's built-in start rate limiting: if a unit crashes 5 times in quick succession, systemd marks it `failed` **and stops restarting it**. That is a feature, not a bug — crash loops should not be masked forever, and our health check's 30-second soak window in Chapter 7 is designed to catch them.
- **Minimal sandboxing in the last four lines**: The process cannot gain new privileges, gets a private `/tmp`, cannot write to `/usr` or `/etc`, and cannot see `/home`. Four lines give you solid baseline hardening without adding container complexity.

Boot-time ordering is handled by `Wants=docker.service` on both units, while transient "Postgres isn't ready yet" startup races are absorbed by application-level connection retries paired with `Restart=on-failure`.

---

## Chapter 6: Backup v1 — Scope, Retention, Drills

`/opt/demo-app/bin/backup.sh` (owned by `root` and invoked via `sudoers` or `cron`) upgrades v0's backup script in three critical ways:

1. **Complete scope**: It backs up both the Postgres database (`pg_dump -Fc`) **and** the `storage/` directory. Backing up the database while forgetting user-uploaded files on disk is a classic production blind spot; v1 closes it outright.
2. **Combined count + age retention**: Each backup class keeps the newest N archives (`14` for `daily`, `10` for `premigrate`), **and never deletes any backup younger than 7 days**. Pure count-based retention is dangerous: a busy afternoon of fifteen deployments would otherwise purge every pre-migration backup from earlier in the week.
3. **Two distinct backup classes**: Scheduled `daily` backups run via cron, while `premigrate` backups fire automatically right before every deployment's database migration step. If a deployment goes sideways and you need to restore data, you always have a snapshot taken seconds before the migration ran.

🧪 **Verify + run a restore drill** (the same drill from section 6.3 of the beginner book — now down to a 30-second routine):

```bash
sudo /opt/demo-app/bin/backup.sh manual
# backup[manual]: db=24K storage=4.0K
LATEST=$(sudo ls -1t /var/backups/demo-app/db | head -1) && echo "$LATEST"
docker run -d --name restore-drill -e POSTGRES_PASSWORD=drill -e POSTGRES_USER=drill -e POSTGRES_DB=drill postgres:16-alpine
sudo docker cp /var/backups/demo-app/db/$LATEST restore-drill:/tmp/r.dump   # dir is 0700 — docker cp needs sudo too
time docker exec restore-drill pg_restore -U drill -d drill --no-owner /tmp/r.dump
docker exec restore-drill psql -U drill -d drill -Atc "SELECT count(*) FROM notes"
docker rm -f restore-drill
```

> **An untested backup is not a backup — always demand evidence from a real restore drill.** Save the output of `time` from that command: it is your first real RTO (Recovery Time Objective) data point. In Chapter 6 of the advanced book, we will benchmark RPO and RTO across realistic dataset sizes.

---

## Chapter 7: The Pipeline, Line by Line

This chapter is the heart of the book. `deploy.sh` is roughly 150 lines of shell (see the full source in `deploy/deploy.sh`), and we will walk through all 16 steps in order. For every step, ask three questions: **What does it do? Why is it here? And what happens when it fails?**

### 7.1 Steps 0–2: arguments, freeze switch, serialization lock

```bash
SHA="${1:-}"
case "$SHA" in ""|*[!0-9a-f]*) die 65 arg "usage: deploy.sh <40-hex-sha>" ;; esac
[ "${#SHA}" -eq 40 ] || die 65 arg "sha must be 40 hex chars"

[ ! -e "$FREEZE_FILE" ] || die 70 freeze "deploys frozen: $FREEZE_FILE exists"

exec 9>"$LOCK_FILE"
flock -n 9 || die 75 lock "another deploy is running"
```

- **The emergency freeze switch**: Once an operator runs `sudo touch /opt/demo-app/freeze`, every incoming deployment is immediately rejected and logged. During an active incident, stopping the bleeding comes before shipping fixes.
- **`flock` serialization**: If two deployments reach the server at the same time, the second one **fails immediately** instead of queueing or interleaving with the first. The GitHub Actions `concurrency` group (Chapter 8) is our first line of defense; `flock` on the server is our second — it doesn't rely on GitHub and catches manual triggers, cron jobs, and wedged CI runners alike. Because the lock file lives on `/run` (`tmpfs`, backed by RAM), a machine reboot clears it automatically, preventing stale lock deadlocks.

### 7.2 Steps 3–5: idempotency, provenance, skip-if-older

```bash
CURRENT=$(basename "$(readlink "$SRV_ROOT/current")")
if [ "$CURRENT" = "$SHA" ] && healthcheck ok; then exit 0; fi          # idempotent

git --git-dir="$REPO_CACHE" fetch --prune -q origin || die 11 ...
git --git-dir="$REPO_CACHE" merge-base --is-ancestor "$SHA" refs/heads/main \
  || die 12 verify "SHA is not an ancestor of origin/main"             # ancestry check

git merge-base --is-ancestor "$SHA" "$CURRENT" && { log "skip: older"; exit 0; }   # skip-if-older
```

- **The ancestry check (provenance)**: Only commits that genuinely sit on `origin/main`'s history are allowed to deploy. Commits orphaned by a force-push, unmerged feature-branch commits, and unpushed local commits are all rejected. What runs in production is guaranteed to be a commit that passed CI on `main`.
- **Skip-if-older**: If a queued deployment job arrives with a target SHA that is *older* than the commit currently live in production (`CURRENT`), the script logs a skip message and exits cleanly without touching the live site. Notice the important corollary: **you cannot roll back by re-running an old CI deployment job** — which is why `rollback.sh` exists as a dedicated tool.

### 7.3 Steps 6–8: preflight, build, promote

```bash
df check: >1GiB free, else refuse                    # disk preflight
read .node-version from the target commit; compare majors with the server   # version drift
verify the commit contains pnpm-lock.yaml            # reproducibility

PARTIAL="$SRV_ROOT/.partial"
git archive "$SHA" | tar -x -C "$PARTIAL"            # export the exact commit
( cd "$PARTIAL" && env GIT_SHA="$SHA" bash -c "$BUILD_CMD" ) \
  || { rm -rf "$PARTIAL"; die 20 build "build failed — live site untouched"; }   # no debris

mv "$PARTIAL" "$SRV_ROOT/releases/$SHA"              # atomic promote
```

- **`GIT_SHA` build injection**: Passing `GIT_SHA="$SHA"` into the build embeds the commit hash into the `/version` endpoint. Later, the health check uses `/version` to assert that the *new* release is actually serving traffic — not merely that *some* process is listening on port 3000.
- **The `.partial` staging directory**: If any part of dependency installation or compilation fails, the script wipes `.partial` clean before exiting. As a result, `releases/` only ever contains complete, successfully built releases.
- **`git archive` instead of `git pull`**: Exporting a tarball directly from the bare `repo.git` cache gives us a clean snapshot of that exact commit, free of `.git` metadata or leftover working-tree files.

> Building on the production server still carries a real cost: this step consumes network bandwidth and CPU cycles on the box serving live traffic. Our reference design accepts that trade-off for simplicity; Chapter 3 of the advanced book benchmarks when you should move the build step into CI instead.

### 7.4 Steps 9–11: config preflight, backup, migration

```bash
sudo -n /opt/demo-app/bin/check-config.sh "$SHA" \
  || die 22 check-config "new release would crash on missing env"    # config preflight

sudo -n /opt/demo-app/bin/backup.sh premigrate \
  || die 24 backup "pre-migration backup failed — refusing to migrate" # no unprotected migrations

sudo -n /opt/demo-app/bin/migrate-wrapper.sh "$SHA" \
  || die 26 migrate "migration failed — code NOT switched"
```

- **`check-config` preflight**: Before touching the live symlink, the pipeline runs `node dist/config.js --check-config` inside the new release directory **as the `app` user, with the real `/opt/demo-app/env/runtime.env` loaded**. That turns the classic "new code requires `NEW_API_KEY` and nobody added it to `.env`" mistake from a *post-switch crash-and-rollback* into a *pre-switch rejection with zero production impact*. Running as `app` ensures we test with the exact permissions and environment the service will see at runtime.
- **Backup failure aborts the migration**: If the pre-migration backup fails for any reason, the pipeline refuses to run database migrations.
- **Migration failure aborts the code switch**: If a migration script fails, `current` is never flipped; the old code continues serving traffic against the unchanged schema. What about a migration file that fails partway through? `migrate.js` wraps each `.sql` file in its own database transaction, so a failing migration rolls back cleanly and is never recorded in `schema_migrations`.
- **Two-layer migration concurrency protection**: `migrate-wrapper.sh` acquires a host-level `flock` (failing fast if another migration is running locally), while `migrate.js` acquires a PostgreSQL session-level `pg_advisory_lock` (serializing migrations across multiple hosts if you ever scale out).

🧪 **Watch migration concurrency protection live** (**[server]**):

```bash
# run two migrations at once; the second queues on the advisory lock
sudo -u app bash -c 'cd /srv/demo-app/current && set -a && . /opt/demo-app/env/runtime.env && node dist/migrate.js' &
sudo -u app bash -c 'cd /srv/demo-app/current && set -a && . /opt/demo-app/env/runtime.env && node dist/migrate.js'
# first:  migrate: up to date ...
# second: migrate: acquiring advisory lock 918273645 ... (waits for the first to finish)
```

### 7.5 Steps 12–14: atomic switch, restart, health check

```bash
ln -sfn "releases/$SHA" "$SRV_ROOT/.current.tmp"
mv -T "$SRV_ROOT/.current.tmp" "$SRV_ROOT/current"      # atomic switch (two steps, deliberately)

sudo -n systemctl restart $UNITS || die 28 restart ...

if ! sudo -n /opt/demo-app/bin/healthcheck.sh "$SHA"; then
  # flip back to $CURRENT, restart, health-check the old version
  #   old healthy   → die 30 ("rolled back successfully")
  #   old unhealthy → die 31 ("human help needed" — never report success falsely)
fi
```

> **Why the two-step `ln -sfn` + `mv -T`**: On most Unix systems, running `ln -sfn new current` directly is **not** atomic — under the hood it unlinks `current` and then creates the new symlink, leaving a brief microsecond window where `/srv/demo-app/current` does not exist at all. The textbook pattern is to create a temporary symlink (`.current.tmp`) and then atomically overwrite `current` using `mv -T`, which invokes the kernel's atomic `rename(2)` syscall. If you copy only one idiom from this book into your own scripts, make it this one.

**`healthcheck.sh` asserts five properties** (full script in `deploy/healthcheck.sh`; here is the core logic):

```bash
version=$(curl ... "$VERSION_URL")   # ① /version gitSha == target SHA (not "port is open")
ready=$(curl ... "$READY_URL")       # ② /health/ready 200 = a real DB read/write
hb=psql "SELECT now()-last_beat ..." # ③ worker heartbeat < 15s (covers the worker unit)
for u in $UNITS; do is-active ...    # ④ every unit active (no mixed states)
sleep "$SOAK_SECONDS"; re-check all  # ⑤ 30s soak (catches "starts then dies" loops)
```

Assertions ①, ③, and ⑤ each close a classic false-positive blind spot: **the old process still answering requests** because the restart didn't take effect, **the background worker crash-looping while the web server looks healthy**, and **a process that boots long enough to pass an instant check before crashing 10 seconds later**. Naive health checks that merely `curl` port 3000 once right after `systemctl restart` miss all three — and in Chapter 9, you will trigger these exact failure modes and watch v1 catch them.

### 7.6 Steps 15–16: retention, audit

```bash
# retention: keep the newest 5 releases; never delete: current, previous
sudo -n /opt/demo-app/bin/audit.sh "$SHA" deploy ok "$(( $(date +%s) - START_TS ))"
```

Each run appends a structured entry to `/var/log/demo-app/audit.log`:

```
2026-10-25T12:00:07Z actor=deploy action=deploy sha=1f2e... result=ok duration=94s
2026-10-25T12:40:11Z actor=sam action=rollback sha=0d9c... result=ok duration=9s
```

**Exit-code quick reference** (referenced by the runbook in Chapter 10, and identical to the table at the bottom of `deploy.sh`):

| Exit code | Step | Meaning & production state |
|---|---|---|
| 11 / 12 | `fetch` / `verify` | `git fetch` failed / target SHA is not an ancestor of `origin/main` (force-push?) |
| 13 / 14 / 15 | `preflight` | Low disk space / server Node major version mismatch / commit is missing `pnpm-lock.yaml` |
| 20 | `build` | Build failed (`.partial` cleaned up; live site completely untouched) |
| 22 | `check-config` | New release is missing a required environment variable (caught before switching) |
| 24 | `backup` | Pre-migration backup failed (refusing to run database migrations) |
| 26 | `migrate` | Database migration failed (code symlink NOT switched; old release still serving) |
| 28 | `restart` | `systemctl restart` failed |
| 30 / 31 / 32 | `health` | Rolled back automatically and old release is healthy / rollback target is also unhealthy (human intervention needed) / very first deploy failed with no previous release to fall back to |
| 64 / 65 | `arg` | Invalid command-line arguments |
| 70 / 75 | `freeze` / `lock` | Deployments frozen via `freeze` file / another deployment is already in progress |

---

## Chapter 8: GitHub Actions — Deploy When CI Passes

### 8.1 The workflow (`.github/workflows/ci.yml` in the repo)

The workflow defines two jobs: `check` (install → test → build → config-preflight smoke test) and `deploy` (`needs: check`, gated by an `if` condition so it runs **only on pushes to `main` or manual workflow dispatches on `main`**). Here is the core of the `deploy` job:

```yaml
concurrency:
  group: deploy-production
  cancel-in-progress: false      # never cancel a running deploy; queuing behavior — see the advanced book
steps:
  - name: Deploy over SSH (forced command)
    env:
      HOST: ${{ secrets.DEPLOY_HOST }}
      KEY: ${{ secrets.DEPLOY_SSH_KEY }}
      KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
      SHA: ${{ github.sha }}
    run: |
      set -euo pipefail
      mkdir -p ~/.ssh
      printf '%s\n' "$KNOWN_HOSTS" > ~/.ssh/known_hosts
      install -m 600 /dev/stdin ~/.ssh/id_ed25519 <<<"$KEY"
      ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/known_hosts \
          -i ~/.ssh/id_ed25519 "deploy@$HOST" "deploy $SHA"
```

- **Why we don't use a third-party SSH GitHub Action** (such as `appleboy/ssh-action`): Every third-party action in your deploy job is another supply-chain dependency with access to your production credentials. Five lines of plain `ssh` have zero external dependencies and let you see *every single byte* crossing the wire. Once you understand those five lines, you can always wrap them later if you choose.
- **Pinning the server's fingerprint with `KNOWN_HOSTS`**: If your server IP is ever hijacked or subjected to a man-in-the-middle attack, `StrictHostKeyChecking=yes` causes `ssh` to abort immediately instead of blindly trusting a new host key. Your deployment channel should have zero tolerance for host-identity ambiguity.

### 8.2 Three secrets + the host key

**[local]** Fetch your server's Ed25519 host public key (run this once over a network you trust; from this point on, CI will verify every connection against this exact fingerprint):

```bash
ssh-keyscan -t ed25519 203.0.113.10
# output like: 203.0.113.10 ssh-ed25519 AAAAC3Nza...
```

In GitHub, open **your repo → Settings → Secrets and variables → Actions → New repository secret** and add these three secrets:

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | `203.0.113.10` (replace with your server's public IP) |
| `DEPLOY_SSH_KEY` | The entire contents of `~/.ssh/demo_deploy_key` (`cat` the private key and paste it in full, including the `BEGIN`/`END` lines) |
| `DEPLOY_KNOWN_HOSTS` | The full output line from `ssh-keyscan` above |

### 8.3 First deployment

**[local]**:

```bash
cd ~/Projects/demo-app
git commit --allow-empty -m "deploy: v1 pipeline ready" && git push
```

Open **GitHub → Actions** and watch the `ci` workflow run: `check` turns green, and then `deploy` starts, streaming the live step-by-step output from `deploy.sh` on your server.

**[server]** Double-check the result on the server:

```bash
curl -s localhost:3000/version
# {"gitSha":"1f2e3d..."}   ← matches this workflow run's commit SHA
sudo tail -1 /var/log/demo-app/audit.log
# ... action=deploy sha=1f2e3d... result=ok duration=XXs
readlink /srv/demo-app/current
# releases/1f2e3d...
```

🎉 **From `git push` to a verified live release with zero manual steps.** Now that the happy path works, let's spend Chapter 9 breaking it on purpose.

---

## Chapter 9: Story Time — Eight Bad Commits (the Scenario Theater)

> Every scenario in this chapter follows the same rhythm: **how to break it** → **push** → **what you should observe** → **which engineering principle it proves**. Remember to `git revert` after each drill so `main` returns to a clean state. Run all of these against **your lab repository and lab server**.

### Script 1: bad-build (build fails)

**[local]** **Break it**: Introduce a syntax error in `src/db.js` (for example, an unclosed `const broken = {`), commit, and push (to see the server-side build guard in action, you can temporarily bypass or disable the CI build check).

**What you should see** in the deploy job logs:

```
build: SYNTAX ERROR in src/db.js:
FAILED step=build: build failed — no release created, live site untouched
```

**[server]** **Verify**: `ls /srv/demo-app/releases | wc -l` is unchanged, and `curl localhost:3000/version` still returns the previous SHA. **Principle proven: contained blast radius — build failures are caught in staging (`.partial`), and production never notices.**

### Script 2: lockfile-mismatch (reproducibility breaks)

**Break it**: Hand-edit `pg`'s version in `package.json` to `9.0.0` *without* running `pnpm install` to update `pnpm-lock.yaml`, then commit and push.

**What you should see**: On the server, `pnpm install --frozen-lockfile` aborts immediately because `pnpm-lock.yaml` does not match `package.json`, failing at `step=build`. **Principle proven: build reproducibility — the server refuses to resolve untested dependency versions on the fly.**

### Script 3: wrong-node-version

**Break it**: Change `.node-version` to `20.11.1`, commit, and push.

**What you should see**: `FAILED step=preflight: server Node major=24, .node-version wants=20`. The live site remains untouched. **Principle proven: environment drift is caught in preflight, long before runtime.**

### Script 4: bad-migration (migration fails, code doesn't switch)

**Break it**: Create `migrations/003_bad.sql` containing `ALTER TABLE notes ADD COLUMN boom; ALTER TABLE notes ADD COLUMN boom;` (adding the same column twice guarantees a SQL error), then commit and push.

**What you should see**:

```
migrate: applying 003_bad.sql
migrate: FAILED at 003_bad.sql: column "boom" of relation "notes" already exists
FAILED step=migrate: migration failed — code NOT switched, live still on ...
```

**[server]** **Verify**: `curl localhost:3000/version` still reports the old SHA; `/srv/demo-app/current` hasn't moved; the `notes` table does not have a `boom` column (because the per-file transaction rolled back); **and a fresh pre-migration backup sits in `/var/backups/demo-app/db/`** (`ls /var/backups/demo-app/db/ | tail -2`). **Principles proven: rollback safety and contained blast radius — a broken migration is just a rejected change, not an outage.** Clean up with `git rm migrations/003_bad.sql && git commit && git push`.

### Script 5: bad-startup (migrates fine, won't boot → auto-rollback)

**Break it**: Insert a production-only crash right after the config check in `src/server.js`:

```js
if (process.env.APP_ENV === 'production') { throw new Error('boom: bad-startup fixture') }
```

(In local dev `APP_ENV` is `dev`, and in CI it is `ci` — so every test passes, and the bomb detonates *only* on the production server. That is the sneakiest class of bug in real life.)

**What you should see**: The pipeline runs through the symlink switch and restarts the units, then fails repeatedly on `version-mismatch` during the health check and triggers an automatic rollback:

```
health check FAILED — rolling back to <old-sha>
FAILED step=health: new release unhealthy; rolled back to <old-sha> (healthy). DB stays migrated — see expand/contract
```

**[server]** **Verify**: `curl localhost:3000/version` is back to the old SHA, `/health/ready` returns `200`, and `journalctl -u demo-app-web -n 20` shows the `boom: bad-startup fixture` stack trace from the aborted release. **Principles proven: automatic rollback shrinks the outage window to seconds, plus rollback safety (notice that the database stays migrated — which is completely safe when migrations are additive; if a migration were destructive, rolling the code back would crash the old release, which is why Chapter 6 of the advanced book teaches the expand/contract pattern).** Clean up: `git revert`, push, and watch the pipeline go green again.

### Script 6: bad-worker (web fine, worker crash-loops → health check catches it)

**Break it**: Add a recurring crash at the top of `main()` in `src/worker.js`:

```js
setInterval(() => { throw new Error('crash loop fixture') }, 3000)
```

**What you should see**: The health check stalls waiting for a fresh worker heartbeat (`worker-heartbeat=XXs`) and automatically rolls the release back. A naive health check that only polled the web port would have marked this deployment **green** — leaving every background job dead in the water at midnight. **Principle proven: health checks must cover every unit; mixed states are unacceptable.** Clean up with `git revert`.

### Script 7: needs-new-env (missing config, caught before the switch)

**Break it**: Add `'NEW_SECRET_TOKEN'` to the `REQUIRED_ENV` array in `src/config.js` (without adding it to the server's `runtime.env`), commit, and push.

**What you should see**:

```
check-config: FAIL — missing required env: NEW_SECRET_TOKEN
FAILED step=check-config: new release would crash on missing env — kept current release
```

Compare Script 7 with Script 5: both commits would crash the server on startup, but Script 7 is caught **before** the symlink flip (zero restarts, zero user impact), whereas Script 5 is caught **after** the flip and rescued by auto-rollback. **Principle proven: shift failure detection left whenever possible.** Clean up with `git revert`.

### Script 8: duplicate deploys & concurrency

- **Idempotency**: Manually re-run the workflow for the exact same SHA that is already live (**Actions → ci → Run workflow**). You should see `sha already live and healthy — nothing to do` and a new audit log entry with `result=ok duration=1s`.
- **Concurrency queuing**: Push two empty commits back-to-back. In GitHub Actions, the two `deploy` jobs queue up behind each other (`concurrency: deploy-production`) and execute sequentially; production ends up on the second commit (and if an older commit ever reaches the server after a newer one, step 5's skip-if-older check skips it cleanly). On the server, `flock` provides the hardware-level backstop.
- **Disconnect survival (`setsid`)**: While a `deploy` job is running in GitHub Actions, click **Cancel workflow** in the UI (so GitHub immediately marks the run as cancelled/failed). Then check `/var/log/demo-app/deploy-*.log` on the server with `tail /var/log/demo-app/deploy-*.log | grep -E '===|FAILED'` — the deployment finished cleanly on its own. That brief window where CI's status disagrees with the server's reality is **by design** (`setsid`), not a bug.

---

## Chapter 10: The One-Page Runbook

Print this page and keep it next to your monitor. When production is on fire at 2 a.m., you want checklists, not chapters.

```text
═══ A deployment failed (Actions red) ══════════════════════
1. Read the last lines of the Actions log: FAILED step=??? is the answer
2. Server view: ls -1t /var/log/demo-app/ | head -3 → tail -50 the newest
3. Audit:      sudo tail -10 /var/log/demo-app/audit.log
4. Map the step to the exit-code table in Chapter 7
═══ Production is down — stop the bleeding first ═══════════
Rollback (offline-capable, ~10s):
  sudo /opt/demo-app/bin/rollback.sh          # back to the previous release
  sudo /opt/demo-app/bin/rollback.sh <SHA>    # back to any kept release
Note: migrations are never rolled back. Suspect data? → next item.
═══ Data incident ══════════════════════════════════════════
1. Freeze deploys: sudo touch /opt/demo-app/freeze
2. Find backups: sudo ls -lt /var/backups/demo-app/db/ | head
3. Restore-drill procedure: Intermediate Ch.6 (validate in a scratch container
   BEFORE touching the real database)
═══ Deploy seems stuck ═════════════════════════════════════
1. Lock: sudo fuser -v /run/demo-app/deploy.lock   (who holds it?)
2. Confirm nobody is running: ps aux | grep deploy.sh
3. Cleanup: fuser -k /run/demo-app/deploy.lock (careful); lock file is deletable
═══ Changed the deploy scripts (repo deploy/) ═════════════
sudo ~/demo-app-bootstrap/deploy/install.sh <repo-url>   # reinstall (idempotent)
Note: the server never auto-updates deploy scripts (drift risk;
detection added in the advanced book)
```

---

## Chapter 11: Porting to Your Own Project

Nothing in this deployment skeleton is tied to Node.js. When you adapt it to your own application, here is what changes:

**Usually just one file**: `deploy/app.conf` (which centralizes the app name, system users, systemd unit names, health-check URLs, build command, migration command, and backup paths).

**Most often just two lines inside it**: `BUILD_CMD` and `MIGRATE_CMD` (for example, `go build -o dist/app ./cmd/server` for Go, or `python -m alembic upgrade head` for Python).

**The application adaptation checklist**:

| Requirement | What your application needs to provide |
|---|---|
| A `/version` equivalent | An endpoint returning the build-injected Git SHA (don't have one? Add it — 10 lines of code buys you deterministic version assertions) |
| A `/health/ready` equivalent | A readiness endpoint that checks critical dependencies and performs a real database read/write |
| A `--check-config` equivalent | A fast CLI flag or entrypoint that validates required environment variables before binding a port (see Script 7 in Chapter 9) |
| A worker heartbeat equivalent | Background workers periodically update a heartbeat row or file so `healthcheck.sh` can verify they are alive |
| A migration mechanism | Any versioned, replayable migration runner that records applied migrations; **even an app with no database migrations should keep this hook as an explicit no-op** |
| Graceful shutdown | A `SIGTERM` handler that drains in-flight HTTP requests or finishes the current background job before exiting |

Remember to update the **unit names in `demo-app.sudoers`** and the **paths in your systemd unit files** to match. In Chapter 11 of the advanced book, we port this entire pipeline to a tiny Go service and count the exact number of changed lines to prove how portable it really is.

---

## What's Still Unsolved (the advanced book's table of contents)

At this point, you have a production deployment pipeline that will comfortably serve most small-to-medium engineering teams. Push on its assumptions a little harder, though, and seven open questions remain — which form the table of contents for the advanced book:

1. `systemctl restart` still leaves a brief restart window (tens to hundreds of milliseconds) → **Blue-green switching**
2. Dependency installation and builds still run on the production server → **The CI-artifact build experiment**
3. Port 22 must stay open to the internet so GitHub Actions can connect → **Pull-based deployments**
4. The CI SSH private key is long-lived and static → **Short-lived SSH certificates**
5. How do we ship destructive schema changes (dropping or renaming columns) without breaking rollback? → **The full expand/contract walkthrough**
6. If someone updates `deploy/` in Git and forgets to re-run `install.sh` on the server, who notices? → **Automated drift detection**
7. What are our true RPO and RTO numbers as the database grows? → **Measured backup and restore benchmarks**

---

*Next book: [Advanced — experiments, measurements, and upgrade decisions](03-advanced.md)*
