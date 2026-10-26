# Intermediate: Push-to-Deploy, Automatic Rollback

> **What you'll learn**: after `git push`, GitHub Actions automatically notifies the server to "fetch → build → preflight → backup → migrate → atomic switch → health check", rolling back to the previous version automatically on any failure; if the deploy credential is stolen, all the attacker can do is trigger a legitimate deployment — they cannot read a single secret of yours.
>
> **Self-check prerequisites** (all "yes" before continuing):
> - [ ] I know what `journalctl -u xxx -n 50` does, and have used it myself
> - [ ] My server has: Nginx + HTTPS, a systemd-managed app, Postgres in Docker, ufw allowing only 22/80/443
> - [ ] I have completed at least one database restore drill (not "know how" — *done it*)
> - [ ] I can name any three of the beginner book's "eight sins"
>
> If any box is unchecked: the relevant chapter is in the [beginner book](01-beginner.md).
>
> **Principles in this book**: P2 rollback safety, P3 health checks assert versions, P4 no mixed states, P7 least privilege, P9 rollback as a first-class citizen, P10 auditability.

**Deliverable**: a complete, portable deployment system. All scripts live in `demo-app/deploy/` in the repo and land in `/opt/demo-app/bin/` on the server. Porting to another project usually means editing one `app.conf`.

---

## Chapter 1: From v0 to v1 — What We're Fixing

The beginner book ended by judging v0's eight sins. This book's table of contents is the verdict:

| # | v0's sin | v1's fix | Principle |
|---|---|---|---|
| 1 | unbounded downtime window | `releases/<sha>/` + `current` symlink, switched atomically; the restart window is all that remains (the advanced book's D3 eliminates it) | P6 |
| 2 | installing/building in prod | kept (reference design), but a failed build never leaves debris; the advanced book's D1 decides with an experiment | P1/P13 |
| 3 | half-done states | staging in `.partial`; promoted to a release only when everything succeeds | — |
| 4 | no health check | assert `/version` == target SHA + a real DB read/write + worker heartbeat freshness + a 30s soak window | P3/P4 |
| 5 | rollback by adrenaline | `rollback.sh`: offline-capable, never touches the DB, timed — a first-class command | P9 |
| 6 | the script owns full sudo | a dedicated `deploy` user + SSH forced command + a sudoers whitelist (restart fixed units / backup / migrate / healthcheck / audit — nothing else) | P7 |
| 7 | no records | `audit.log` + `logger` (syslog), one line per operation | P10 |
| 8 | code/migration skew | failed migration → no code switch; order: backup → migrate → switch; destructive migrations go expand/contract (advanced book) | P2 |

**The v1 pipeline at a glance** (keep this picture; every section is one piece of it):

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

| User | Who | Can do | Cannot do |
|---|---|---|---|
| `root` (you, via sam's sudo) | admin | everything; owns the deploy scripts, sudoers, and deploy's authorized_keys | — (hence: use it only for admin actions) |
| `deploy` | the CI's avatar | log in **only** via the SSH forced command; build releases; run 5 whitelisted actions via sudo | read `runtime.env`, edit scripts, open a shell, transfer files |
| `app` | the service itself | run web/worker, read `runtime.env`, write storage, reach the DB | log in, touch code or deploy scripts |

> **Why split** (P7 least privilege): consider the worst case — the CI's SSH private key leaks. The attacker can trigger a deployment of some SHA on main and hammer the whitelist. They cannot read the DB password or alter the deploy scripts (deploy a malicious SHA? It must be an ancestor of main, and main is protected). The blast radius is minimal. The advanced book's D4 quantifies static keys vs short-lived certs.

### 2.2 The directory layout

```
/opt/demo-app/              # the "machine" side: root-owned, writable by no one else
├── bin/                     #   deploy scripts (deploy.sh, rollback.sh, backup.sh ...)
├── env/runtime.env          #   root:app 0640 — only the app can read it
├── compose/                 #   docker-compose.yml + .env (Postgres)
└── freeze                   #   existence = refuse deployments (kill switch, E8)

/srv/demo-app/               # the "application" side
├── repo.git/                #   bare mirror cache, owned by deploy (read-only deploy key)
├── releases/<40-hex-sha>/   #   one immutable directory per deployment
├── current → releases/<sha> #   the atomic switch (systemd follows this)
└── storage/                 #   file storage, written by app

/var/log/demo-app/           # deploy logs (keep 20) + audit.log
/var/backups/demo-app/       # db/ + storage/ backups
/run/demo-app/               # deploy lock (tmpfs; recreated by tmpfiles.d on boot)
```

> **Why `releases/<sha>` instead of in-place `git pull`**: one full directory per version = natural rollback (flip a symlink), natural audit (the directory name *is* the version), immutable artifacts (no half-pulled working copies). It's the core of Capistrano's design for over a decade — worth copying.

### 2.3 Migrating from the v0 layout

**[server]** tidy up v0's checkout, unit, and compose (**database data stays** — it lives in a Docker volume):

```bash
sudo systemctl disable --now demo-app
sudo rm /etc/systemd/system/demo-app.service
sudo cp /srv/demo-app/.env /tmp/demo-compose.env        # save the DB password
cd /srv/demo-app && sudo docker compose down      # volume preserved (demo-app_pgdata); plain sudo (app isn't in the docker group)
cd /srv && sudo mv demo-app demo-app-v0-backup
```

Get the latest repo onto the server (the deploy scripts install from it), then run the bootstrap:

```bash
cd ~ && git clone git@github.com:yourname/demo-app.git demo-app-bootstrap
cd demo-app-bootstrap/deploy
sudo ./install.sh git@github.com:yourname/demo-app.git
```

`install.sh` (in `deploy/install.sh`, ~100 lines — worth reading fully) does 9 things: create `app`/`deploy` users with locked passwords → build the directory tree above → install scripts to `/opt/demo-app/bin` (root-owned) → install sudoers with `visudo -cf` validation → install the systemd units (enable, don't start) → wire compose and `runtime.env` (filling in the password you saved) → clone `repo.git` → install the daily backup cron → print next steps.

Re-attach the v0 database password and confirm the data survived:

```bash
sudo cp /tmp/demo-compose.env /opt/demo-app/compose/.env && rm /tmp/demo-compose.env
sudo rm -f /opt/demo-app/env/runtime.env    # regenerate it with the saved password
sudo ./install.sh git@github.com:yourname/demo-app.git   # idempotent; just rerun
docker exec demo-app-db psql -U demo_app -d demo_app -Atc "SELECT count(*) FROM notes"
# the count you created in the beginner book — data survived the move
```

The file storage must move over too (it's a first-class backup citizen, P5; v0's storage lives in the old directory):

```bash
sudo rm -rf /srv/demo-app/storage
sudo cp -a /srv/demo-app-v0-backup/storage /srv/demo-app/storage
sudo chown -R app:app /srv/demo-app/storage
```

> `install.sh` is idempotent: existing things are left alone. Upgrading the deploy scripts themselves is "edit the repo → rerun install.sh" (the F2 script-drift problem gets automatic detection in the advanced book, Chapter 7).

✅ **Checkpoint**: `ls -la /opt/demo-app/bin | head -5` shows every file owned by root; `sudo ls -la /opt/demo-app/env/` shows `runtime.env` as `-rw-r----- root app`.

---

## Chapter 3: deploy's Key — the SSH Forced Command

### 3.1 Generate the CI's keypair

**[local]**:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/demo_deploy_key -N "" -C "ci-deploy@demo-app"
```

The private key (`demo_deploy_key`) goes into GitHub Secrets later; the **public key** goes to the server now.

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

Three details, each deliberate:

1. **`restrict`**: turns off every "extra feature" of this key — no terminal (`-t` fails), no port forwarding (`-L/-R/-D` fail), no X11/agent forwarding, nothing beyond what the forced command allows.
2. **`command="..."`**: whatever the client sends, sshd runs this instead. The client's intended command arrives in the `SSH_ORIGINAL_COMMAND` environment variable, which `deploy-entry` adjudicates.
3. **The directory and file are root-owned**: the deploy user (or anyone who steals the deploy password) **cannot edit their own key**. Scenario A2 verifies this.

> This is the secure shape of the reference design's "SSH notify": port 22 must be open to the public (the advanced book's D2 pull model closes this door entirely), but behind the door there is a one-centimeter slot.

### 3.3 deploy-entry: exactly one accepted input

`/opt/demo-app/bin/deploy-entry` (root-owned; full content in `deploy/deploy-entry`):

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

# keep the newest 19 logs; this one becomes #20 (H9 minimal fix)
ls -1t "$LOG_DIR"/deploy-*.log 2>/dev/null | tail -n +20 | xargs -r rm -f
LOG="$LOG_DIR/deploy-$(date -u +%Y%m%dT%H%M%S)_$$.log"
touch "$LOG" && chmod 640 "$LOG"

logger -t deploy-entry "accepted sha=$sha from=${SSH_CONNECTION:-local}"

# the key design (B5): the deploy runs detached from the SSH session
setsid /opt/demo-app/bin/deploy.sh "$sha" >"$LOG" 2>&1 </dev/null &
pid=$!
tail -n +1 -f "$LOG" --pid="$pid" || true
wait "$pid"
```

Two designs to internalize:

- **The whitelist is the argument parser**: the `case` patterns accept only `deploy ` + 40 lowercase hex chars. Short SHAs, uppercase, spaces, `rm -rf`, environment-variable injection (`deploy abc && ...`) — all refused.
- **`setsid` detachment (B5)**: the deploy runs in a new session; if the SSH connection dies (CI timeout, laptop lid), it continues unaffected. The client merely *watches* via `tail -f`. `wait "$pid"` hands the deploy's real exit code back to SSH, so CI marks the run correctly.

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

> Two keys, two jobs: `deploy@server fetch key` can only **read** the repo (for git fetch); the CI's `ci-deploy@demo-app` can only **trigger deploys**. Either one alone is not enough to cause an incident.

With the key in place, finish the step Chapter 2 couldn't complete (install.sh is idempotent — just rerun):

```bash
cd ~/demo-app-bootstrap/deploy && sudo ./install.sh git@github.com:yourname/demo-app.git
# this time "== 7/9 repo mirror cache" should succeed
sudo ls /srv/demo-app/repo.git/HEAD >/dev/null && echo repo-cache-OK
```

### 3.5 The connection test matrix (scenario A1)

**[local]** try each line; expected output on the right:

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

And one "real" deploy (40 zeros is not on main, so the pipeline itself rejects it — but that's *inside* the pipeline, which is the point):

```bash
ssh -i $KEY $H "deploy 0000000000000000000000000000000000000000" 2>&1 | tail -3
# ... FAILED step=verify: SHA is not an ancestor of origin/main — rejected
```

✅ **Checkpoint**: all six illegal inputs were refused with clear reasons; the last one got rejected *inside the pipeline* — the doorman and the security scanner each did their job.

---

## Chapter 4: sudoers — a Least-Privilege Whitelist

deploy.sh runs as the deploy user, but six actions need root: restarting units, backup (docker exec), the migration wrapper, config preflight, health checks, and audit. The sudoers whitelist is precise to "which script + which arguments":

**[server]** `cat ~/demo-app-bootstrap/deploy/demo-app.sudoers` (installed by install.sh to `/etc/sudoers.d/demo-app`):

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

> - **Absolute paths**: sudoers demands them (`/usr/bin/systemctl`) — the classic defense against "I placed a fake systemctl earlier in PATH".
> - **Arguments are the boundary**: `systemctl restart demo-app-web` and `systemctl restart demo-app-web demo-app-worker` are two different rules — sudoers matches "command + exact arguments" as one string. Want `systemctl stop ssh`? No such rule; denied.
> - **The glob is only layer one**: `[0-9a-f]*` could theoretically match an argument containing spaces (sudoers' `*` spans spaces), so every wrapper script re-validates "exactly one 40-hex argument" internally (defense in depth for scenario A4).
> - **`audit.sh *` is a known concession**: deploy can forge audit lines (it can trigger deploys anyway). The advanced book Chapter 8 fixes it with forwarding to a remote syslog.

🧪 **Verify** ([server], as deploy):

```bash
sudo -u deploy sudo systemctl restart demo-app-web
# (succeeds — whitelisted)
sudo -u deploy sudo ls /root
# Sorry, user deploy is not allowed to execute '/bin/ls /root' as root
sudo -u deploy cat /opt/demo-app/env/runtime.env
# cat: ... Permission denied   ← the DB password; deploy cannot read it
```

The iron rule for editing sudoers: always run `sudo visudo -cf /etc/sudoers.d/demo-app` afterwards. **A malformed sudoers file can break sudo entirely** — then your only rescue is the provider console (P8).

---

## Chapter 5: systemd Units — web + worker, Graceful Shutdown

v1 has two units (`deploy/demo-app-web.service`, `deploy/demo-app-worker.service`, both installed by install.sh). The web unit's key lines:

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

Every difference from v0 has a reason:

- **`WorkingDirectory`/`ExecStart` via `current`**: deploys flip the symlink and `systemctl restart`; the unit file never changes.
- **`TimeoutStopSec=15`**: on restart, systemd sends SIGTERM first. server.js drains in-flight requests before exiting; the worker finishes its current job (at-least-once semantics). No exit after 15s → SIGKILL — so your graceful-shutdown code must be time-aware.
- **`Restart=on-failure` rather than `always`**: a deliberate `stop` shouldn't bounce back. Note systemd's built-in rate limit: 5 crashes in a row lands the unit in `failed` state **and stays down**. That's a feature — crash loops shouldn't be infinitely masked, and the health check's soak window exists to catch exactly this (P3).
- The last four lines are minimal hardening: no new privileges, a private /tmp, most of the filesystem read-only. Enough without being exotic (P13).

Inter-unit ordering (both units `Wants=docker.service`) covers boot; "what if the DB isn't ready yet" is absorbed by app-level retries plus `Restart=on-failure`.

---

## Chapter 6: Backup v1 — Scope, Retention, Drills

`/opt/demo-app/bin/backup.sh` (root-owned; invoked via sudoers/cron) upgrades v0 in three ways:

1. **Scope**: the database (`pg_dump -Fc`) **plus** the `storage/` directory. The H2 hypothesis (file storage missing from backups) is a real defect in the reference design; v1 fixes it outright.
2. **Retention = by-count + by-time combined**: keep the newest N per class (daily 14 / premigrate 10), **and never delete anything under 7 days old**. Count-only retention wipes history when deploys are frequent (the other half of H2).
3. **Two classes**: scheduled `daily` + pre-migration `premigrate` (triggered automatically by deploys). For rollbacks, prefer the latest `premigrate`.

🧪 **Verify + drill** (same moves as beginner 6.3, 30 seconds this time):

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

> **P5 demands evidence of a real restore drill.** Keep that output — it's your first-hand RTO datapoint. The advanced book Chapter 6 produces the full table (sizes/durations/RPO).

---

## Chapter 7: The Pipeline, Line by Line

The heart of this book. `deploy.sh` is ~150 lines (full text in `deploy/deploy.sh`); we walk it in 16 steps. For each step: **what? why? what happens on failure?**

### 7.1 Steps 0–2: arguments, freeze switch, serialization lock

```bash
SHA="${1:-}"
case "$SHA" in ""|*[!0-9a-f]*) die 65 arg "usage: deploy.sh <40-hex-sha>" ;; esac
[ "${#SHA}" -eq 40 ] || die 65 arg "sha must be 40 hex chars"

[ ! -e "$FREEZE_FILE" ] || die 70 freeze "deploys frozen: $FREEZE_FILE exists"

exec 9>"$LOCK_FILE"
flock -n 9 || die 75 lock "another deploy is running"
```

- **The freeze switch (E8)**: after `touch /opt/demo-app/freeze`, every deployment is explicitly refused and logged. During an incident, "stop the bleeding" beats "fix it fast".
- **flock (B3)**: two deploys arriving at once — the second **fails immediately** rather than queueing or interleaving. The workflow's `concurrency` is the first line of defense (Chapter 8); flock is the second — it doesn't depend on GitHub and also covers manual runs, timers, and stuck runners. The lock file lives in `/run` (tmpfs): a reboot clears it, so no deadlocks.

### 7.2 Steps 3–5: idempotency, provenance, skip-if-older

```bash
CURRENT=$(basename "$(readlink "$SRV_ROOT/current")")
if [ "$CURRENT" = "$SHA" ] && healthcheck ok; then exit 0; fi          # B2 idempotent

git --git-dir="$REPO_CACHE" fetch --prune -q origin || die 11 ...
git --git-dir="$REPO_CACHE" merge-base --is-ancestor "$SHA" refs/heads/main \
  || die 12 verify "SHA is not an ancestor of origin/main"             # B1

git merge-base --is-ancestor "$SHA" "$CURRENT" && { log "skip: older"; exit 0; }   # B2
```

- **B1 (ancestry check)**: only SHAs genuinely on main's history deploy. SHAs knocked off by force-push, feature-branch SHAs, unpushed local SHAs — all rejected. What deploys is what CI tested (the provenance half of P1).
- **Skip-if-older**: a queued deploy that's *older* than what's live is skipped (live stays put). Corollary: **you cannot roll back by "redeploying an old SHA"** — which is exactly why `rollback.sh` must exist (H8 fixed by E7).

### 7.3 Steps 6–8: preflight, build, promote

```bash
df check: >1GiB free, else refuse                    # C5
read .node-version from the target commit; compare majors with the server   # C2
verify the commit contains pnpm-lock.yaml            # C2

PARTIAL="$SRV_ROOT/.partial"
git archive "$SHA" | tar -x -C "$PARTIAL"            # export the exact commit
( cd "$PARTIAL" && env GIT_SHA="$SHA" bash -c "$BUILD_CMD" ) \
  || { rm -rf "$PARTIAL"; die 20 build "build failed — live site untouched"; }   # C1

mv "$PARTIAL" "$SRV_ROOT/releases/$SHA"              # atomic promote
```

- **`GIT_SHA` injection**: it's what `/version` returns. The health check asserts "the *new* version is live" — not "some version is live" (P3).
- **`.partial` lifecycle**: a failed build deletes the whole thing; `releases/` only ever contains fully-built versions (C1).
- **`git archive` instead of `git pull`**: exports the **exact snapshot of the commit** — no `.git`, no working-tree state involved.

> H7 (the cost of building on the prod box) still applies: this step needs network and CPU. The reference design accepts it; the advanced book's D1 answers with data when you shouldn't.

### 7.4 Steps 9–11: config preflight, backup, migration

```bash
sudo -n /opt/demo-app/bin/check-config.sh "$SHA" \
  || die 22 check-config "new release would crash on missing env"    # E6/H6

sudo -n /opt/demo-app/bin/backup.sh premigrate \
  || die 24 backup "pre-migration backup failed — refusing to migrate" # P5

sudo -n /opt/demo-app/bin/migrate-wrapper.sh "$SHA" \
  || die 26 migrate "migration failed — code NOT switched"            # D3
```

- **check-config (E6)**: runs `node dist/config.js --check-config` **as the app user, with the real `runtime.env` loaded**. "The new version needs `NEW_API_KEY` but nobody configured it" goes from *crash-after-switch, rollback saves us* to *refused-before-switch, zero user impact*. Note it runs as app: the exact runtime point of view (permissions and env alike), not the deploy user's guess.
- **Backup failure = refuse to migrate**: better a failed deploy than an unprotected migration (P5).
- **Migration failure = no code switch** (D3): live stays on the old version, old code + unchanged schema, still serving. A migration half-applied? `migrate.js` wraps each file in a transaction; a failing file rolls back completely and is never recorded in `schema_migrations`.
- **Concurrency protection (D6) is two-layered**: `migrate-wrapper.sh`'s flock (host-level, fail fast) + `pg_advisory_lock` inside `migrate.js` (database-level, works across hosts).

🧪 **D6 live** ([server]):

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
  #   old unhealthy → die 31 ("human help needed" — never report success falsely, E5)
fi
```

> **Why `ln -sfn` + `mv -T`**: `ln -sfn new current` alone is **not** atomic on most systems (it may unlink-then-symlink, with a "no current" instant in between). Build a temp symlink, then replace with `mv -T` (a rename — atomic in the kernel). This detail is the most steal-worthy line in the reference design.

**healthcheck.sh asserts five things** (full text in the repo; the essentials):

```bash
version=$(curl ... "$VERSION_URL")   # ① /version gitSha == target SHA (not "port is open")
ready=$(curl ... "$READY_URL")       # ② /health/ready 200 = a real DB read/write
hb=psql "SELECT now()-last_beat ..." # ③ worker heartbeat < 15s (covers the worker unit)
for u in $UNITS; do is-active ...    # ④ every unit active (no mixed states, P4)
sleep "$SOAK_SECONDS"; re-check all  # ⑤ 30s soak (catches "starts then dies" loops, P3)
```

① ③ ⑤ each close a false-positive hole: **the old process still answering** (the switch never took effect), **the worker crash-looping while web is fine**, and **up for 10 seconds then dead, after the check already passed**. The H3 hypothesis says the reference design's health check misses the first two — this v1 implementation *is* the fix. Chapter 9 manufactures both false positives for you.

### 7.6 Steps 15–16: retention, audit

```bash
# keep the newest 5 releases; never delete: current, previous (F5)
sudo -n /opt/demo-app/bin/audit.sh "$SHA" deploy ok "$(( $(date +%s) - START_TS ))"
```

`audit.log` looks like this (P10):

```
2026-10-25T12:00:07Z actor=deploy action=deploy sha=1f2e... result=ok duration=94s
2026-10-25T12:40:11Z actor=sam action=rollback sha=0d9c... result=ok duration=9s
```

**Exit-code quick reference** (this is the table the runbook points to; identical to the comment at the end of `deploy.sh`):

| Exit | step | Meaning |
|---|---|---|
| 11 / 12 | fetch / verify | git fetch failed / SHA not on main's history (force-push?) |
| 13 / 14 / 15 | preflight | low disk / Node major mismatch / commit lacks a lockfile |
| 20 | build | build failed (`.partial` cleaned; production untouched) |
| 22 | check-config | new release missing required env (caught pre-switch) |
| 24 | backup | pre-migration backup failed (refusing to migrate) |
| 26 | migrate | migration failed (code NOT switched) |
| 28 | restart | systemctl restart failed |
| 30 / 31 / 32 | health | rolled back, old healthy / rollback target also unhealthy (human needed) / first deploy failed with no fallback |
| 64 / 65 | arg | invalid arguments |
| 70 / 75 | freeze / lock | deploys frozen / another deploy in progress |

---

## Chapter 8: GitHub Actions — Deploy When CI Passes

### 8.1 The workflow (`.github/workflows/ci.yml` in the repo)

Two jobs: `check` (install → test → build → a config-preflight smoke test) and `deploy` (`needs: check`, with an `if` restricting to **pushes to main or manual dispatch on main**). The deploy job's core:

```yaml
concurrency:
  group: deploy-production
  cancel-in-progress: false      # never cancel a running deploy; queuing behavior → H5 (advanced book)
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

- **No off-the-shelf SSH action** (like appleboy/ssh-action): every dependency is supply-chain risk, and these 5 lines let you *understand* every connection (P13). Adopt an action after you understand these lines.
- **`KNOWN_HOSTS` pins the host fingerprint (A5)**: a replaced server or MITM makes `ssh` hard-fail instead of asking "fingerprint changed, continue?". The deploy channel has zero tolerance for host-identity ambiguity.

### 8.2 Three secrets + the host key

**[local]** fetch the server's host key (obtain it once over a network you trust; from then on, only ever compare against this copy):

```bash
ssh-keyscan -t ed25519 203.0.113.10
# output like: 203.0.113.10 ssh-ed25519 AAAAC3Nza...
```

GitHub → your repo → Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | `203.0.113.10` |
| `DEPLOY_SSH_KEY` | the full private key (`cat` it and paste the whole thing) |
| `DEPLOY_KNOWN_HOSTS` | the `ssh-keyscan` output line |

### 8.3 First deployment

**[local]**:

```bash
cd ~/Projects/demo-app
git commit --allow-empty -m "deploy: v1 pipeline ready" && git push
```

GitHub → Actions → watch the `ci` workflow: `check` green → `deploy` runs, streaming the server's pipeline output (the step logs from Chapter 7).

**[server]** double-check:

```bash
curl -s localhost:3000/version
# {"gitSha":"1f2e3d..."}   ← exactly this run's commit SHA
sudo tail -1 /var/log/demo-app/audit.log
# ... action=deploy sha=1f2e3d... result=ok duration=XXs
readlink /srv/demo-app/current
# releases/1f2e3d...
```

🎉 **From merged code to live new version with zero manual steps.** Next chapter: break things on purpose.

---

## Chapter 9: Story Time — Eight Bad Commits (the Scenario Theater)

> Format per script: **how to make it** → **push** → **what you should see** → **which principle it proves**. Remember to `git revert` afterwards. All of it on **your lab repo**.

### Script 1: bad-build (build fails, C1)

**[local]** add a syntax error to `src/db.js` (e.g. `const broken = {`), commit, push.

**You should see** in the deploy job:

```
build: SYNTAX ERROR in src/db.js:
FAILED step=build: build failed — no release created, live site untouched
```

**[server]** verify: `ls /srv/demo-app/releases | wc -l` unchanged; `curl localhost:3000/version` still the old SHA. **Principle: P6 (failures stay in preflight; production never notices).**

### Script 2: lockfile-mismatch (C2)

Make: hand-edit `pg`'s version in `package.json` to `9.0.0` (without running `pnpm install`), push.

You should see: on the server, `pnpm install --frozen-lockfile` refuses (lockfile out of sync with the manifest); step=build fails. **Principle: reproducibility.**

### Script 3: wrong-node-version (C2)

Make: change `.node-version` to `20.11.1`, push.

You should see: `FAILED step=preflight: server Node major=24, .node-version wants=20`. Live, untouched. **Principle: environment drift surfaces in preflight.**

### Script 4: bad-migration (migration fails, code doesn't switch, D3)

Make: create `migrations/003_bad.sql` containing `ALTER TABLE notes ADD COLUMN boom; ALTER TABLE notes ADD COLUMN boom;` (duplicate column, guaranteed error), push.

You should see:

```
migrate: applying 003_bad.sql
migrate: FAILED at 003_bad.sql: column "boom" of relation "notes" already exists
FAILED step=migrate: migration failed — code NOT switched, live still on ...
```

**[server]** verify: `/version` still the old SHA; `current` unchanged; **but a fresh backup exists** (`ls /var/backups/demo-app/db/ | tail -2` — the pre-migration backup fired first). **Principles: P2/P6 — a failed migration isn't a disaster, just another rejected change.** Cleanup: `git rm migrations/003_bad.sql && git commit && git push`.

### Script 5: bad-startup (migrates fine, won't boot → auto-rollback, E4)

Make: insert into `src/server.js` right after the config check:

```js
if (process.env.APP_ENV === 'production') { throw new Error('boom: bad-startup fixture') }
```

(local is `dev`, CI is `ci` — neither triggers; only the server does. The sneakiest kind of bug: "explodes only in production".)

You should see: the deploy reaches the health check, `version-mismatch` keeps failing, then:

```
health check FAILED — rolling back to <old-sha>
FAILED step=health: new release unhealthy; rolled back to <old-sha> (healthy). DB stays migrated — see expand/contract
```

**[server]** verify: `/version` is back to the old SHA and `/health/ready` is 200; `journalctl -u demo-app-web -n 20` shows the `boom` error. **Principles: P6 (auto-rollback) + P2 (the DB stays migrated — harmless here because the migration was additive; with a destructive one this is the incident scene, which is why the advanced book teaches expand/contract).** Cleanup: revert, push, watch it deploy green again.

### Script 6: bad-worker (web fine, worker crash-loops → health check catches it, E2/P3)

Make: add at the top of `main()` in `src/worker.js`:

```js
setInterval(() => { throw new Error('crash loop fixture') }, 3000)
```

You should see: the health check stalls on `worker-heartbeat=XXs` (stale heartbeat), then rolls back. A v0-style check that only polled the web port would have declared this deployment **successful** — with every worker on strike at midnight. **Principle: P3 (health checks cover every unit).** Cleanup: revert.

### Script 7: needs-new-env (missing config, caught before the switch, E6/H6)

Make: add `'NEW_SECRET_TOKEN'` to the `REQUIRED_ENV` array in `src/config.js` (and don't configure it anywhere), push.

You should see:

```
check-config: FAIL — missing required env: NEW_SECRET_TOKEN
FAILED step=check-config: new release would crash on missing env — kept current release
```

Compare with Script 5: the same defect class — one caught **before** the switch (zero impact), one caught **after** by rollback. **Principle: shift failure left.** Cleanup: revert.

### Script 8: duplicate deploys & concurrency (B2/B3/B5)

- **Idempotency**: manually re-trigger the same SHA (Actions → deploy workflow → Run workflow). Expect `sha already live and healthy — nothing to do`, plus an audit line `result=ok duration=1s`.
- **Concurrency**: push two commits quickly; in Actions, two deploys queue (concurrency) and run in order; the final live version is the second (the first, now older, gets skipped if it deploys later than the newer one — check the skip log). The server-side flock logs hold the evidence.
- **Disconnect-safety (B5)**: while a deploy runs in Actions, cancel the workflow (CI instantly "fails"), then on the server `tail /var/log/demo-app/deploy-*.log | grep -E '===|FAILED'` — the deploy completed anyway. A brief CI-state vs reality mismatch is part of H5 — **by design** (setsid), not a bug.

---

## Chapter 10: The One-Page Runbook

Print this page. During incidents, don't page through tutorials.

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
Note: migrations are never rolled back (P2). Suspect data? → next item.
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
Note: the server never auto-updates deploy scripts (H11 drift risk;
detection added in the advanced book)
```

---

## Chapter 11: Porting to Your Own Project

The skeleton is language-agnostic:

**Edit one file**: `deploy/app.conf` (app name/users/units/health URLs/build command/migrate command/backup dirs...).

**Usually two lines within it**: `BUILD_CMD`, `MIGRATE_CMD` (e.g. `go build -o dist/app ./cmd/server`, `python -m alembic upgrade head`).

**The adaptation checklist**:

| Item | Your app must provide |
|---|---|
| A `/version` equivalent | an endpoint returning the build-injected version (none? add one — 10 lines, worth it) |
| A `/health/ready` equivalent | checks key dependencies + a real read/write |
| A `--check-config` equivalent | a startup-path validation of required env (see Script 7's value) |
| A worker heartbeat equivalent | background jobs write a heartbeat row/file so health checks can cover them |
| A migration mechanism | anything versioned, replayable, recorded; **apps without migrations should still have the concept as "(empty)"** |
| Graceful shutdown | SIGTERM handling (in-flight requests/jobs) |

Also sync the **unit names in sudoers** and **the systemd unit paths**. The advanced book Chapter 11 ports the whole thing onto a tiny Go app and counts the changed lines as the portability evidence.

---

## What's Still Unsolved (the advanced book's table of contents)

1. The restart window still exists (tens to hundreds of ms) → **blue-green switching** (D3)
2. Builds still happen on the prod box (H7) → **the CI-artifact experiment** (D1)
3. The SSH port must stay public (H10) → **pull-based deploys** (D2)
4. The CI key is long-lived and static → **short-lived SSH certificates** (D4)
5. How to make destructive migrations safe → **the full expand/contract walkthrough**
6. Someone changed the deploy scripts without reinstalling — who notices? → **drift detection** (H11/F2)
7. What *are* the backup's RPO/RTO, really? → **measured tables**

---

*Next book: [Advanced — experiments, measurements, and upgrade decisions](03-advanced.md)*
