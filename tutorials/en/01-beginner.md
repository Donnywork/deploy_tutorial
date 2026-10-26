# Beginner: One Server, One Domain, One HTTPS URL

> **What you'll learn**: put a web app you wrote (database included) on a real public server, keep it running 24/7, serve it over a domain with HTTPS, back it up daily (and actually restore it once), and ship updates with a single command.
>
> **What you need**:
> - A computer of your own (Windows/Mac/Linux — anything with a terminal)
> - A payment method: a VPS at ~$4–6/month + a domain at ~$1–10/year
> - 3–5 hours. Every chapter ends with a checkpoint; pass them all before moving on
>
> **What you don't need**: any ops experience. Every concept is explained the first time it appears.

**Principles in this book** (from the [design document](../../deploy-experiment-prompt.md)'s 13 industry principles; chapters flag which apply): P5 an untested backup is no backup, P8 don't lock yourself out, P13 simplicity first.

**Conventions**:
- **[local]** = run in a terminal on your own computer; **[server]** = SSH into the server first, then run.
- The tutorial uses `203.0.113.10` for your server IP, `deploy-demo.example.com` for your domain, and `sam` for your username — **replace all three with your own everywhere**.
- When a code block starts with `# file: xxx`, it is the full content of a file to create.

---

## Chapter 0: Crash Course in Vocabulary (10 minutes)

What stops first-time deployers is usually vocabulary, not commands. One sentence per term:

| Term | One-sentence explanation |
|---|---|
| VPS | A "remote computer" rented from a cloud provider, with a public IP, always on — that's your "server" |
| SSH | The encrypted way to log into that remote computer and run commands; 90% of deployment is this |
| Terminal | The "black window" on your machine (Terminal on Mac; Windows Terminal recommended) |
| Linux user | An account on the server (like `root`, `sam`) — same idea as Windows accounts |
| systemd | Linux's "service manager": keeps programs running in the background, starts them at boot, restarts them on crash |
| Service (unit) | One program managed by systemd, e.g. `demo-app.service` |
| Port | One of 65,535 numbered "sockets" on the server. This book uses 22 (SSH), 80 (HTTP), 443 (HTTPS), 3000 (app) |
| Nginx | A "reverse proxy": stands in front of your app, handles TLS certificates and forwards requests |
| DNS / A record | The "phone book" that points `deploy-demo.example.com` at IP `203.0.113.10` |
| TLS / HTTPS | The "padlock" on websites. Certificates are free from Let's Encrypt and auto-renew |
| Environment variables | Configuration your program reads at runtime (like the DB password), kept in a `.env` file that **never enters git** |
| Database migration | A versioned script that changes table schemas; committed with code, executed at deploy time |

Come back to this table whenever a word feels fuzzy.

---

## Chapter 1: A Server of Your Own

### 1.1 Buy a VPS

Any provider works: Hetzner, DigitalOcean, Vultr, Tencent Cloud Lightweight, Alibaba Cloud ECS. Choose:

- **OS**: Ubuntu 24.04 LTS (every command in this course assumes it)
- **Size**: the smallest tier is fine (1 vCPU / 1GB RAM runs demo-app; the advanced book's load tests prefer 2GB)
- **Region**: close to your users

After checkout you receive: a **public IP** (e.g. `203.0.113.10`) and a root password (some providers use a web console instead).

### 1.2 Generate an SSH key and log in for the first time

**[local]** Check whether you already have a key (if so, don't generate another):

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ssh-keygen -t ed25519 -C "sam@laptop"
```

Accept the defaults (empty passphrase is fine for a tutorial; use one on a work machine).

> **Why**: an SSH key is a pair of files. The private key (`id_ed25519`, your house key — **never share it**) stays on your computer; the public key (`.pub`, the lock) goes to the server. SSH proves "it's me" with key material — passwords can be guessed; modern SSH keys (like ed25519) effectively cannot.

Paste the public key into your provider's "SSH keys" box (most providers show it while creating the server), or use the root-password path and configure it after first login.

**[local]** First login:

```bash
ssh root@203.0.113.10
```

You'll see:

```
The authenticity of host '203.0.113.10' can't be established.
ED25519 key fingerprint is SHA256:xxxxxxx...
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

> **What is this**: the server presents its "fingerprint" and asks "memorize it?". This is TOFU (Trust On First Use). The proper move is to compare against the fingerprint shown in your provider's console before typing yes — the intermediate book covers why a **changed** fingerprint must hard-fail a deployment (P7/A5). Seed planted.

Type `yes`. When the prompt becomes `root@ubuntu:~#`, you're in. **Do not close this window** — it's your lifeline in section 1.4.

### 1.3 Baseline updates

**[server]**:

```bash
apt update && apt upgrade -y
timedatectl set-timezone Asia/Shanghai   # your timezone
apt install -y unattended-upgrades && dpkg-reconfigure -f noninteractive unattended-upgrades
```

> `unattended-upgrades` auto-installs security patches. An unattended small server deserves at least this much self-defense.

### 1.4 Create a daily user, disable root login

Working as root all day is dangerous (one slip = a machine-wide incident; principle P7 starts with yourself). Create a user `sam`:

**[server]**:

```bash
adduser sam              # set a password, Enter through the rest
usermod -aG sudo sam     # add sam to the sudo group
```

Copy your public key over (assuming 1.2's key reached root):

```bash
mkdir -p /home/sam/.ssh && cp ~/.ssh/authorized_keys /home/sam/.ssh/ \
  && chown -R sam:sam /home/sam/.ssh && chmod 700 /home/sam/.ssh && chmod 600 /home/sam/.ssh/authorized_keys
```

**Open a new terminal** and test (**keep the root window open**):

**[local]**:

```bash
ssh sam@203.0.113.10
sudo whoami             # type sam's password; output "root" → sudo works
```

Once sam can log in and sudo, disable root SSH login:

**[server]** (the sam window):

```bash
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sshd -t && echo CONFIG_OK     # syntax check — only proceed on CONFIG_OK!
sudo systemctl reload ssh
```

> ⚠️ **P8: don't lock yourself out.** These three lines are the classic source of lockout stories worldwide. Three safety nets:
> 1. `sshd -t` only validates syntax; a failed check means `reload` never runs;
> 2. `reload` (not `restart`) doesn't kill existing connections — your root window stays alive;
> 3. While the old window stays connected, test a **new** login. If truly locked out, the provider's web console (VNC) is your out-of-band channel — go find it in the console *now*, so you're not hunting for it during an incident.

✅ **Checkpoint**:
- [ ] `ssh sam@203.0.113.10` works
- [ ] `ssh root@203.0.113.10` is refused (`Permission denied`)
- [ ] You know where the provider's VNC/web console lives

### 1.5 Firewall (ufw)

**[server]**:

```bash
sudo ufw allow OpenSSH     # allow port 22 FIRST!
sudo ufw allow 80/tcp      # HTTP
sudo ufw allow 443/tcp     # HTTPS
sudo ufw enable            # order matters: allow SSH before enable, or lock yourself out on the spot
sudo ufw status
```

Expected output includes:

```
To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere
```

> Only these three. The app's port 3000 and the database's 5432 are **deliberately not** open to the public — they should only ever be reached by Nginx and the app on the same machine.

✅ **Checkpoint**: `sudo ufw status` shows only 22/80/443; a fresh terminal can still SSH in.

---

## Chapter 2: Meet demo-app, Run It Locally

### 2.1 Get the code

The companion app ships in this very repository (the `demo-app/` directory). Copy it into your first own project:

**[local]**:

```bash
cp -r /path/to/deploy_tutorial/demo-app ~/Projects/demo-app
cd ~/Projects/demo-app
rm -rf node_modules        # in case the copy brought dependency caches along
git init -b main
pnpm install               # first install; also generates pnpm-lock.yaml
git add -A && git commit -m "demo-app v1: web + worker + migrations"
```

> **Why commit `pnpm-lock.yaml`**: it pins the exact version of every dependency. On the server, `pnpm install --frozen-lockfile` installs precisely the same versions — otherwise the classic "works on my machine" tragedy strikes (the intermediate book rehearses this as scenario C2).

The app looks like this (skim for now; every file is under 50 lines):

```
demo-app/
├── src/
│   ├── server.js     # web process: /health/ready, /version, /api/notes...
│   ├── worker.js     # worker process: consumes the job queue, graceful SIGTERM
│   ├── migrate.js    # migration runner (advisory lock against concurrency)
│   ├── config.js     # config validation (--check-config entrypoint)
│   └── db.js         # DB connection pool
├── migrations/       # SQL migrations
├── build.mjs         # the "build": copy to dist/ + inject version
├── docker-compose.yml# Postgres (bound to 127.0.0.1 only)
└── deploy/           # deployment assets (this book only uses naive/)
```

### 2.2 Run it locally (optional, strongly recommended)

Requires Docker locally (Docker Desktop / Rancher Desktop). Don't have it? Skip ahead — you can catch up later.

**[local]**:

```bash
cp .env.example .env
# edit .env: POSTGRES_PASSWORD=<anything, local only>
docker compose up -d db          # database only, on 127.0.0.1:5432
pnpm run migrate
pnpm run build
DATABASE_URL="postgres://demo_app:your-password@127.0.0.1:5432/demo_app" \
APP_ENV=dev STORAGE_DIR=$PWD/storage pnpm run dev
```

Expected:

```
demo-app web listening on 127.0.0.1:3000 (version dev)
```

Open `http://localhost:3000` in a browser, then in another terminal:

```bash
curl -s localhost:3000/health/ready
# {"ok":true,"db":true,"lastPingId":1,"notes":0}
```

`"db":true` means it actually wrote to the database. Now the full path (create note → enqueue → worker consumes):

```bash
curl -s -X POST localhost:3000/api/notes -H 'content-type: application/json' -d '{"title":"hello"}'
# {"note":{...},"jobId":1}
pnpm run worker          # start the worker in another terminal; Ctrl-C after a few seconds
curl -s localhost:3000/api/jobs/1
# {"id":"1",...,"status":"done","result":{"shouted":"HELLO","length":5},...}
```

With the local run green, the server side won't scare you.

### 2.3 Push to your own GitHub repository

**[local]**:

```bash
gh repo create demo-app --private --source=. --push    # if you have GitHub CLI
# or: create an empty private repo named demo-app on the web UI, then:
# git remote add origin git@github.com:yourname/demo-app.git && git push -u origin main
```

✅ **Checkpoint**: your private repo on GitHub shows `pnpm-lock.yaml` and all the code; `.env` is **not** there (`.gitignore` keeps it out).

---

## Chapter 3: Set Up House on the Server: Docker, Postgres, Node, Code

### 3.1 Install Docker and Postgres

**[server]**:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker sam
# log out and back in (exit, then ssh sam@...) for the docker group to take effect
docker version
```

The repository's `docker-compose.yml` starts a Postgres. Look at the key line:

```yaml
ports:
  - "127.0.0.1:5432:5432"
```

> **Why bind to 127.0.0.1 only**: writing `"5432:5432"` listens on **every** interface — effectively publishing your database to the internet (password or not, it's needless attack surface). With `127.0.0.1:5432:5432`, only the server itself can connect. One of the most common beginner security mistakes.

The database password comes from a `.env` file next to the compose file (distinct from the repo's `.env.example`; the server one **never enters git**):

```bash
cd /srv
sudo mkdir -p demo-app && sudo chown sam:sam demo-app && cd demo-app
# code lands here in the next section; docker-compose.yml ships in the repo
```

### 3.2 Install Node 24 and pnpm

**[server]**:

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
node -v          # v24.x.x
sudo npm install -g pnpm@11
pnpm -v
```

> The repo carries a `.node-version` file saying `24.22.1`. The intermediate book's deploy script checks "server's Node major == the major declared in the repo" — version drift is the other big source of "works locally, breaks in prod" (scenario C2). Also note: on 2026-10-21 Node.js fixed 10 CVEs (including an RCE-capable Brotli decoder flaw) — **always pin to a version that carries the latest security patches** (that release was 22.23.4 for the 22 line; this course uses the Active LTS 24.22.1).

### 3.3 A dedicated user for the app, and getting the code

Don't run the app as sam, and definitely not as root. Create a dedicated `app` user (P7: if the app is compromised, the attacker gets exactly this unprivileged identity):

```bash
sudo useradd --system --create-home --shell /bin/bash app
```

Give it a **read-only** GitHub deploy key (can pull, cannot push — bounded loss if leaked):

```bash
sudo -u app mkdir -p /home/app/.ssh
sudo -u app ssh-keygen -t ed25519 -f /home/app/.ssh/id_ed25519 -N "" -C "app@server pull key"
sudo -u app cat /home/app/.ssh/id_ed25519.pub
# paste into GitHub: repo → Settings → Deploy keys → Add (leave "write access" unchecked)
sudo -u app ssh-keyscan -t ed25519 github.com >> /tmp/kh && sudo -u app tee -a /home/app/.ssh/known_hosts < /tmp/kh >/dev/null
```

> `ssh-keyscan` pre-records GitHub's host key, so the upcoming `git clone` won't block on the "trust this fingerprint?" interactive prompt.

Clone the code (note that `app` owns `/srv/demo-app`):

```bash
sudo chown -R app:app /srv/demo-app
sudo -u app git clone git@github.com:yourname/demo-app.git /srv/demo-app
sudo -u app bash -c 'cd /srv/demo-app && pnpm install --frozen-lockfile && pnpm run build'
```

### 3.4 Config files and the database

Two files (same idea as the local ones in 2.2, with server paths):

**[server]** `# file: /srv/demo-app/.env` (the compose database password):

```bash
cd /srv/demo-app
sudo -u app bash -c 'umask 077 && echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)" > .env'
sudo -u app grep -c PASSWORD .env    # outputs 1 — it's there (don't cat it; fewer eyes on secrets)
```

Start the database:

```bash
sudo docker compose up -d db     # note: the app user is NOT in the docker group — plain sudo
docker ps --format '{{.Names}} {{.Status}}'
# demo-app-db Up 2 minutes (healthy)
docker exec demo-app-db pg_isready -U demo_app
# accepting connections
```

**[server]** `# file: /srv/demo-app/runtime.env` (app config, for systemd):

```bash
PW=$(sudo -u app sed -n 's/^POSTGRES_PASSWORD=//p' .env)
sudo bash -c "umask 077 && cat > /srv/demo-app/runtime.env <<EOF
DATABASE_URL=postgres://demo_app:$PW@127.0.0.1:5432/demo_app
APP_ENV=production
STORAGE_DIR=/srv/demo-app/storage
PORT=3000
EOF"
sudo chown root:app /srv/demo-app/runtime.env && sudo chmod 0640 /srv/demo-app/runtime.env
```

> **Why root-owned, mode 0640**: this file holds the DB password. `root:app 0640` means "root reads/writes, the app group reads, nobody else" — the app (running as `app`) can read it, while you, sam, cannot. The intermediate book makes "even the deploy user can't read it" a verifiable fact.

Create the schema:

```bash
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && pnpm run migrate'
# migrate: applying 001_init.sql
# migrate: applying 002_add_status.sql
# migrate: applied 2 file(s), done
```

### 3.5 Run it by hand, then watch it "die"

```bash
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && node dist/server.js'
# demo-app web listening on 127.0.0.1:3000 (version dev)
```

Verify from another window, then press `Ctrl-C` in the first:

```bash
curl -s localhost:3000/version
# {"gitSha":"dev"}
# after Ctrl-C: curl: (7) Failed to connect
```

**That's this chapter's core problem**: the process lives and dies with your terminal. `nohup`, `&`, and `tmux` are band-aids — the next chapter solves it properly with systemd.

✅ **Checkpoint**:
- [ ] `docker ps` shows `demo-app-db` healthy
- [ ] `sudo -u app` runs `dist/server.js`; `curl /health/ready` says `"db":true`
- [ ] `/srv/demo-app/runtime.env` shows permissions `-rw-r-----  root app`
- [ ] ufw still only allows 22/80/443

---

## Chapter 4: systemd — Make the App Always Show Up

### 4.1 Write a service unit

**[server]** create `# file: /etc/systemd/system/demo-app.service`:

```ini
[Unit]
Description=demo-app web (v0 naive)
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
User=app
Group=app
WorkingDirectory=/srv/demo-app
EnvironmentFile=/srv/demo-app/runtime.env
ExecStart=/usr/bin/node /srv/demo-app/dist/server.js
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

Read it line by line (writing your own service later is just editing these lines):

| Line | Meaning |
|---|---|
| `Wants=/After=` | Start after network and Docker (the database runs in Docker) |
| `User=app` | Run as the unprivileged app user, not root (P7) |
| `EnvironmentFile=` | Load these environment variables before starting (that 0640 file) |
| `ExecStart=` | The command to run — **must be an absolute path** |
| `Restart=always` | Always restart on crash/OOM |
| `WantedBy=multi-user.target` | The "start at boot" hook |

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now demo-app
systemctl status demo-app --no-pager
```

Expect `Active: active (running)`. Test the endpoint:

```bash
curl -s localhost:3000/health/ready && echo
# {"ok":true,"db":true,...}
```

### 4.2 Three proofs that it "always shows up"

**🧪 Experiment 1: kill it**

```bash
sudo kill -9 $(systemctl show -p MainPID --value demo-app)
sleep 3 && systemctl is-active demo-app    # active — auto-restarted
```

**🧪 Experiment 2: logs** (systemd collected stdout/stderr for you):

```bash
journalctl -u demo-app -n 20 --no-pager    # last 20 lines
journalctl -u demo-app -f                  # live tail (Ctrl-C exits, doesn't stop the service)
```

> From now on, the first reaction to "why did the app die" is `journalctl -u <service> -n 100`.

**🧪 Experiment 3: reboot the whole machine**

```bash
sudo reboot
# wait a minute, ssh back in
curl -s localhost:3000/health/ready && echo
# {"ok":true,...} — boot-persistence works, and Postgres came back too
```

✅ **Checkpoint**: you saw all three results with your own eyes. "Is the app running?" now has a canonical answer: `systemctl is-active demo-app`.

---

## Chapter 5: Nginx + HTTPS — A Proper Street Address

### 5.1 DNS

In your domain registrar's panel, add an **A record**:

```
Host: deploy-demo      (the prefix of deploy-demo.example.com)
Value: 203.0.113.10
```

**[local]** Verify propagation (usually minutes):

```bash
dig +short deploy-demo.example.com
# 203.0.113.10
```

### 5.2 The Nginx reverse proxy

**[server]**:

```bash
sudo apt install -y nginx
sudo tee /etc/nginx/sites-available/demo-app >/dev/null <<'EOF'
server {
    listen 80;
    server_name deploy-demo.example.com;   # your domain

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
sudo ln -sfn /etc/nginx/sites-available/demo-app /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

> **What a reverse proxy does**: the app only listens on `127.0.0.1:3000` (unreachable from the internet); Nginx owns ports 80/443 and forwards to the app. Benefits: certificates live in one place, changing the app port never touches the domain, and if the app dies Nginx can at least return a decent error page.

Open `http://deploy-demo.example.com` — you should see the demo-app homepage.

### 5.3 HTTPS (Let's Encrypt)

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d deploy-demo.example.com
# email → agree → sharing preference
# choose Redirect (force HTTPS)
```

`certbot` did three things worth knowing: proved to Let's Encrypt that you control the domain (it verifies via a temporary file served on port 80), rewrote the Nginx config to attach the certificate, and installed an auto-renewal timer. Verify renewal:

```bash
sudo certbot renew --dry-run
# Congratulations, all simulated renewals succeeded
sudo systemctl list-timers | grep certbot
```

```bash
curl -sI https://deploy-demo.example.com | head -3
# HTTP/2 200 ...
```

> No domain? See Appendix A. But in production **HTTPS is not optional**: without it, traffic between your users and the server — including session cookies — is visible and modifiable by any network intermediary.

✅ **Checkpoint**: `https://deploy-demo.example.com` shows the padlock; plain HTTP 301s to HTTPS.

---

## Chapter 6: Backups and a Restore Drill (P5: An Untested Backup Is No Backup)

> This chapter comes from a painful principle (P5): in GitLab's 2017 data-loss incident, **every one** of their backup mechanisms turned out to be broken. So the deliverable here is not "a backup script" but "a backup script I have personally restored from".

### 6.1 Write the backup script

**[server]** `# file: /home/sam/backup-naive.sh` (same content as `deploy/naive/backup-naive.sh` in the repo):

```bash
#!/usr/bin/env bash
set -euo pipefail
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST=$HOME/backups/demo-app
mkdir -p "$DEST/db" "$DEST/storage"

echo "==> dumping database"
docker exec demo-app-db pg_dump -U demo_app --format=custom demo_app > "$DEST/db/$STAMP.dump"

echo "==> archiving file storage"
tar -czf "$DEST/storage/$STAMP.tar.gz" -C /srv/demo-app storage

echo "==> pruning: keep newest 14"
ls -1t "$DEST/db" | tail -n +15 | while read -r f; do rm -f "$DEST/db/$f"; done
ls -1t "$DEST/storage" | tail -n +15 | while read -r f; do rm -f "$DEST/storage/$f"; done

echo "==> latest:"
ls -lh "$DEST/db" | tail -3
```

Two points:
- `pg_dump --format=custom` produces a compressed binary backup, restored with `pg_restore`, with selective table restore supported;
- **The backup must include `/srv/demo-app/storage`** (file storage). Backing up only the database is P5's most classic blind spot: the database is pristine while all user-uploaded files are gone.

```bash
chmod +x ~/backup-naive.sh && ~/backup-naive.sh
# ==> latest:
# -rw-r--r-- 1 sam sam 12K 2026-10-25 12:00 20261025T040000Z.dump
```

### 6.2 Run it daily (cron)

```bash
crontab -e
# append this line (03:17 server time daily; off the hour to avoid collisions):
17 3 * * * /home/sam/backup-naive.sh >> /home/sam/backups/backup.log 2>&1
```

> crontab's five fields: minute hour day month weekday. Tomorrow morning, `ls ~/backups/demo-app/db` showing a fresh file counts as success.

### 6.3 The restore drill (the soul of this chapter)

🧪 **Experiment: pretend disaster struck; restore the database to five minutes ago.**

First, make some data:

```bash
curl -s -X POST https://deploy-demo.example.com/api/notes -H 'content-type: application/json' -d '{"title":"before backup"}'
~/backup-naive.sh
curl -s -X POST https://deploy-demo.example.com/api/notes -H 'content-type: application/json' -d '{"title":"after backup (should vanish)"}'
```

Start a **temporary** restore database (completely separate from production):

```bash
docker run -d --name restore-drill -e POSTGRES_PASSWORD=drill \
  -e POSTGRES_USER=drill -e POSTGRES_DB=drill postgres:16-alpine
LATEST=$(ls -1t ~/backups/demo-app/db | head -1)
docker cp ~/backups/demo-app/db/$LATEST restore-drill:/tmp/restore.dump
time docker exec restore-drill pg_restore -U drill -d drill --no-owner /tmp/restore.dump
```

Compare:

```bash
docker exec restore-drill psql -U drill -d drill -Atc "SELECT title FROM notes ORDER BY id"
# before backup          ← "after backup" is absent, as expected (RPO = backup interval)
docker exec demo-app-db psql -U demo_app -d demo_app -Atc "SELECT title FROM notes ORDER BY id"
# before backup
# after backup (should vanish)
docker rm -f restore-drill
```

**Two concepts that are now yours** (the advanced book measures them properly):

- **RPO** (Recovery Point Objective): how much data you can afford to lose. Your current scheme: daily backups → worst case 24 hours.
- **RTO** (Recovery Time Objective): how long until you're back. The `time` output above is your first-hand RTO datapoint — write it down.

### 6.4 An off-site copy

Backups on the same machine and disk as the database = one fire takes all. The cheapest off-siteing:

**[local]** pull backups to your own computer:

```bash
mkdir -p ~/demo-app-backups
rsync -av sam@203.0.113.10:backups/demo-app/ ~/demo-app-backups/
```

Put that in your local cron too (Mac: `crontab -e`; Windows: Task Scheduler running the same command). The next step up (object storage + rclone) is in the advanced book, Chapter 6.

✅ **Checkpoint**:
- [ ] You ran a backup by hand; `~/backups/demo-app/db` contains a `.dump`
- [ ] You completed a full restore drill and "after backup" indeed did not come back (that absence is the evidence you want)
- [ ] cron is configured; a copy exists locally
- [ ] You can answer: what is my RPO?

---

## Chapter 7: Your First Pipeline — deploy-v0 and Its Eight Sins

Right now every code change means manually SSH-ing and typing commands. Let's script it — and then honestly face every flaw in that script. They are precisely the intermediate book's table of contents.

### 7.1 The v0 deploy script

**[server]** `# file: /home/sam/deploy-naive.sh` (same as `deploy/naive/deploy-naive.sh`):

```bash
#!/usr/bin/env bash
set -e
cd /srv/demo-app
echo "==> pulling latest code"
sudo -u app git pull --ff-only origin main
echo "==> installing dependencies (on the PRODUCTION machine)"
sudo -u app pnpm install --frozen-lockfile
echo "==> building (on the PRODUCTION machine)"
sudo -u app pnpm run build
echo "==> migrating"
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && pnpm run migrate'
echo "==> restarting"
sudo systemctl restart demo-app
echo "deployed: $(sudo -u app git -C /srv/demo-app rev-parse --short HEAD)"
```

```bash
chmod +x ~/deploy-naive.sh
```

### 7.2 Experience the full loop

**[local]** change one line and walk the whole path:

```bash
cd ~/Projects/demo-app
sed -i '' 's/<h1>demo-app<\/h1>/<h1>demo-app v2<\/h1>/' src/server.js   # macOS; on Linux use sed -i
git commit -am "v2: change title" && git push
```

**[server]**:

```bash
~/deploy-naive.sh && curl -s https://deploy-demo.example.com | grep h1
# <h1>demo-app v2</h1>
```

Congratulations — you have a deployment pipeline! Now, the honest part.

### 7.3 Judgment day: the eight sins

**🧪 Sin #1: the downtime window.** During the script's `systemctl restart`, requests fail. Measure it:

**[local]** hammer requests while deploying:

```bash
while true; do
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://deploy-demo.example.com/health/ready || echo FAIL
  sleep 0.2
done
```

**[server]** run `~/deploy-naive.sh` in another terminal; watch the local output. You'll see some `000 ...s` or `FAIL` lines — that's "the site is down" from the user's perspective. **Note the duration of consecutive failures** (typically hundreds of ms to a few seconds). The intermediate book makes the switch atomic; the advanced book's D3 experiment squeezes it toward zero with blue-green.

**🧪 Sin #2: building on the production machine.** `pnpm install` + `build` run on the box serving users: they steal CPU/RAM (visibly hurting latency on small machines), and **with no internet there is no deployment**. Try it (your origin is the SSH form, which uses port 22 — block both; your existing SSH session survives, because OUTPUT rules only block *new* outbound connections):

```bash
sudo iptables -A OUTPUT -p tcp --dport 22 -j DROP    # git@github.com goes through here
sudo iptables -A OUTPUT -p tcp --dport 443 -j DROP
~/deploy-naive.sh        # expected: fails at the git pull stage
sudo iptables -D OUTPUT -p tcp --dport 22 -j DROP    # remove both rules when done
sudo iptables -D OUTPUT -p tcp --dport 443 -j DROP
```

**🧪 Sin #3: half-done states.** Suppose `build` fails (push a deliberate syntax error locally): `set -e` stops the script — but notice, if the failure happened *between migrate and restart*, the database already has the new schema while the old code is still running. Nothing broke this time purely by luck.

**🧪 Sin #4: no health check.** The script declares victory when it finishes. Did the new version start? Is `/health/ready` green? Nobody knows. In the real world, versions that crash within 30 seconds of restart (OOM, missing env) are everywhere.

**🧪 Sin #5: rollback by adrenaline.** New version down? `git reset` + rebuild + restart, all in a panic — and the old version may already be gone. **Rollback should be as convenient as deploy** (intermediate book, E7).

**🧪 Sin #6: excessive privileges.** The script runs as sam with full sudo. Deploy logic needs exactly: restart one service, run one migration, make one backup. P7 says shrink to those.

**🧪 Sin #7: no records.** Who deployed what, when, with what outcome? Today the answer is "grep shell history" (P10 auditability).

**🧪 Sin #8: the code/migration skew window.** The order is `migrate → restart`: between migration completing and new code starting, you're running **old code against the new schema**. Additive migrations usually survive; destructive ones kill the old code on the spot (P2). The correct pattern (expand/contract) is advanced book Chapter 6.

### 7.4 Beginner book wrap-up

You now have a **daily-usable** go-live process — and an honest list of its flaws. The intermediate book turns each sin into an engineering solution:

| Sin | The intermediate fix |
|---|---|
| #1 downtime window | `releases/<sha>` directories + atomic `current` symlink switch |
| #2 building in prod | kept for now; the advanced book's D1 experiment decides with data |
| #3 half-done states | build into `.partial`; promote to a release only after everything succeeds |
| #4 no health check | assert `/version` == target SHA + real DB read/write + worker heartbeat + soak window |
| #5 rollback by adrenaline | `rollback.sh`: a first-class command, no internet required |
| #6 excessive privileges | a `deploy` user + SSH forced command + sudoers whitelist |
| #7 no records | audit.log: one line per operation (who/when/SHA/result/duration) |
| #8 code/migration skew | a failed migration means no code switch; destructive changes go expand/contract |

✅ **Graduation checkpoint**:
- [ ] You can say without looking up: what `systemctl status` / `journalctl -u` / `ufw status` are for
- [ ] You completed a full restore drill and can state your RPO
- [ ] You measured v0's downtime window yourself and have a number
- [ ] You can retell each of the eight sins in your own words

---

## Appendix A: No Domain?

- **IP + HTTP only**: skip the certbot section, set `server_name _;`. Downsides: no padlock, plaintext, cookies exposed. Temporary use only.
- **sslip.io / nip.io**: `203.0.113.10.sslip.io` resolves to `203.0.113.10` automatically. Great for DNS/certificate practice; shared domains hit Let's Encrypt rate limits — **never for production**.
- Honest advice: a $2/year domain is the best learning investment available.

## Appendix B: Free Local VM Practice

Three Multipass commands for the same Ubuntu:

```bash
brew install --cask multipass          # or the official installer
multipass launch --name lab --memory 2G --disk 10G 24.04
multipass shell lab                    # equivalent to ssh; the rest of the chapters work as-is
multipass delete lab && multipass purge  # destroy when done
```

Limitations: no real public IP → Chapter 5's HTTPS becomes self-signed practice, and the intermediate book's real GitHub Actions path must be simulated by playing the CI's ssh call from your host machine (method in the advanced book, Appendix C). **Bottom line: learn concepts on a VM; learn the real chain on a real VPS.**

## Appendix C: Porting to Your Own App

The skeleton is universal. Walk this table per project:

| What changes | Where |
|---|---|
| App port (3000) | `PORT` in `runtime.env` + Nginx `proxy_pass` |
| The "build" command (`pnpm run build`) | anything producing a runnable artifact (`go build`, `mvn package`...) |
| The database (containerized Postgres) | MySQL/SQLite is a compose-file and connection-string swap; no DB → drop the migrate steps |
| systemd unit | the `ExecStart` line; Java → `java -jar app.jar`, Python → `.venv/bin/gunicorn ...` |
| Backup script | `pg_dump` → `mysqldump`/file snapshots; **keep the storage backup** (P5) |
| `/health/ready` | strongly recommended for your app too: check key dependencies + real read/write |

## Appendix D: Common Errors Quick Reference

| Error | Cause → fix |
|---|---|
| `Permission denied (publickey)` | key mismatch / wrong user → `ssh -v` shows which keys were tried |
| `curl: (7) Failed to connect ... port 3000` | app not running → `systemctl status demo-app`, `journalctl -u demo-app -n 50` |
| `502 Bad Gateway` (Nginx page) | Nginx alive, backend dead → same as above; it's the app 90% of the time |
| `EADDRINUSE` | port 3000 taken → `sudo ss -ltnp | grep 3000` |
| `password authentication failed for user "demo_app"` | `.env` password differs from `runtime.env`'s `DATABASE_URL` → align, then recreate (changing the password on an existing volume doesn't take effect; `docker compose down -v` starts fresh, **deleting data**) |
| `pnpm install` lockfile mismatch | `package.json` changed locally without refreshing the lock → run `pnpm install` locally, commit `pnpm-lock.yaml` |
| Page still old after deploy | stale build / browser cache → `curl -s yourdomain/version`; hard-refresh |
| disk full | logs/backups piled up → `df -h`, `journalctl --vacuum-size=200M`, clean `~/backups` |

---

*Next book: [Intermediate — push-to-deploy with automatic rollback](02-intermediate.md)*
