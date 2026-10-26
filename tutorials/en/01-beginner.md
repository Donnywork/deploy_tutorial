# Beginner: One Server, One Domain, One HTTPS URL

> **What you'll learn**: How to take a web application you wrote (database included) and deploy it onto a real public server, keep it running 24/7, serve it over your own domain with HTTPS, back it up automatically every day (and verify that backup with a real restore drill), and ship updates with a single command.
>
> **What you need**:
> - A computer of your own (Windows, macOS, or Linux — anything with a terminal)
> - A payment method: a VPS at ~$4–6/month + a domain name at ~$1–10/year
> - 3–5 focused hours. Every chapter ends with a checkpoint; make sure every item passes before moving on
>
> **What you don't need**: Any prior operations experience. Every concept is explained in plain English the first time it appears.

**Principles in this book**: An untested backup is no backup; don't lock yourself out; simplicity first. Chapters flag which principles apply along the way.

**Conventions**:
- **[local]** means run the command in a terminal on your own computer; **[server]** means SSH into the server first, then run it there.
- Throughout this tutorial, `203.0.113.10` stands in for your server IP, `deploy-demo.example.com` for your domain, and `sam` for your daily username — **replace all three with your own values everywhere**.
- When a code block starts with `# file: xxx`, it shows the complete contents of a file you should create at that path.

---

## Chapter 0: Crash Course in Vocabulary (10 minutes)

What stops first-time deployers is rarely the commands themselves — it's the wall of unfamiliar jargon. Here is every core term you'll meet in this book, explained in one sentence:

| Term | One-sentence explanation |
|---|---|
| VPS | A virtual "remote computer" rented from a cloud provider, equipped with a public IP and left running 24/7 — that's your "server" |
| SSH | The encrypted protocol used to log into a remote server and run commands; 90% of deployment work happens over SSH |
| Terminal | The command-line window on your computer (Terminal on macOS; Windows Terminal recommended on Windows) |
| Linux user | An account on the server (such as `root` or `sam`) — the exact same idea as user accounts on your personal computer |
| systemd | Linux's built-in service manager: it keeps programs running in the background, starts them at boot, and restarts them if they crash |
| Service (unit) | A single background program managed by systemd, defined in a unit file like `demo-app.service` |
| Port | One of 65,535 numbered communication "sockets" on a server. This book uses 22 (SSH), 80 (HTTP), 443 (HTTPS), and 3000 (app) |
| Nginx | A "reverse proxy" that stands in front of your app, terminates TLS certificates, and forwards incoming requests |
| DNS / A record | The internet's phone book; an A record maps a domain like `deploy-demo.example.com` to an IP address like `203.0.113.10` |
| TLS / HTTPS | The cryptographic "padlock" on websites. Certificates are issued for free by Let's Encrypt and renew automatically |
| Environment variables | Runtime configuration your program reads from its environment (such as a database password), stored in a `.env` file that **never enters git** |
| Database migration | A versioned script that alters database table schemas; committed alongside code and executed automatically at deploy time |

Flip back to this table whenever a term in later chapters feels fuzzy.

---

## Chapter 1: A Server of Your Own

### 1.1 Buy a VPS

Any reputable cloud provider works well: Hetzner, DigitalOcean, Vultr, Tencent Cloud Lighthouse, or Alibaba Cloud ECS. When creating your instance, pick:

- **OS**: Ubuntu 24.04 LTS (every command in this course is tested against it)
- **Size**: The smallest tier is plenty (1 vCPU / 1GB RAM easily runs `demo-app`; if you plan to run the load tests in the advanced book, 2GB is more comfortable)
- **Region**: Whichever datacenter is closest to you or your users

Once checkout finishes, you'll be given two essentials: a **public IP** (e.g., `203.0.113.10`) and a `root` password (or a prompt to attach an SSH key in the web console).

### 1.2 Generate an SSH key and log in for the first time

**[local]** First, check whether you already have an Ed25519 SSH key (if you do, there is no need to generate another):

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ssh-keygen -t ed25519 -C "sam@laptop"
```

Press Enter through the prompts to accept the defaults (an empty passphrase is fine for a tutorial environment; on a work laptop, set a strong passphrase).

> **Why SSH keys matter**: An SSH key is a matched pair of files. The **private key** (`id_ed25519`, which acts like your house key — **never share it with anyone**) stays on your laptop; the **public key** (`.pub`, which acts like the lock cylinder) goes onto the server. When you log in, SSH uses cryptographic signatures to prove you hold the private key. Unlike passwords, which can be brute-forced, modern SSH keys like `ed25519` are practically impossible to guess.

Paste the contents of your `.pub` file into your provider's "SSH Keys" field (most cloud consoles ask for it when creating the server), or log in with the initial `root` password and install the key manually in the next step.

**[local]** Log into your server for the first time:

```bash
ssh root@203.0.113.10
```

On your very first connection to a new host, SSH will pause and display:

```
The authenticity of host '203.0.113.10' can't be established.
ED25519 key fingerprint is SHA256:xxxxxxx...
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

> **What this means**: The server is presenting its cryptographic "fingerprint" and asking whether you want to trust and remember it. This model is called TOFU (Trust On First Use). The rigorous habit is to verify that this fingerprint matches the one displayed in your cloud provider's console before typing `yes` — **in the intermediate book, you'll configure automated deployments to hard-fail immediately if a server's fingerprint ever changes** (the deploy channel pins the host key, so any mismatch aborts the connection). Consider that seed planted.

Type `yes` and press Enter. Once your prompt changes to `root@ubuntu:~#`, you are inside the server. **Do not close this terminal window** — while you reconfigure SSH in section 1.4, this active session is your lifeline.

### 1.3 Baseline updates

**[server]** Bring the operating system packages up to date, set your timezone, and enable automatic security patches:

```bash
apt update && apt upgrade -y
timedatectl set-timezone Asia/Shanghai   # your timezone
apt install -y unattended-upgrades && dpkg-reconfigure -f noninteractive unattended-upgrades
```

> `unattended-upgrades` automatically installs critical security patches in the background. For a small server without a dedicated ops team watching it around the clock, this is the bare minimum of self-defense.

### 1.4 Create a daily user, disable root login

Doing day-to-day work as `root` is asking for trouble: one mistyped command can turn into a machine-wide catastrophe. Practicing least privilege starts with your own login account. Let's create an everyday user named `sam`:

**[server]**:

```bash
adduser sam              # set a password, Enter through the rest
usermod -aG sudo sam     # add sam to the sudo group
```

Copy your authorized SSH public key over to `sam` (assuming your key from section 1.2 is already in `/root/.ssh/authorized_keys`):

```bash
mkdir -p /home/sam/.ssh && cp ~/.ssh/authorized_keys /home/sam/.ssh/ \
  && chown -R sam:sam /home/sam/.ssh && chmod 700 /home/sam/.ssh && chmod 600 /home/sam/.ssh/authorized_keys
```

Now **open a second terminal window** on your computer to test the new account (**keep your original `root` window open!**):

**[local]**:

```bash
ssh sam@203.0.113.10
sudo whoami             # type sam's password; output "root" → sudo works
```

Once you have confirmed that `sam` can both log in over SSH and elevate privileges with `sudo`, disable direct `root` logins over SSH:

**[server]** (run this inside the `sam` window):

```bash
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sshd -t && echo CONFIG_OK     # syntax check — only proceed on CONFIG_OK!
sudo systemctl reload ssh
```

> ⚠️ **Principle: Don't lock yourself out.** Those three lines are the single most common source of server lockout stories worldwide. Notice the three safety nets built into the sequence above:
> 1. `sshd -t` validates the configuration syntax beforehand; if there is a typo, `reload` never runs.
> 2. Using `reload` (instead of `restart`) tells the SSH daemon to re-read its config without dropping existing sessions — so your open `root` window stays alive.
> 3. While keeping the old session open, you always test a **brand-new** login before closing anything. And if you ever do lock yourself out completely, your cloud provider's web-based VNC console is your out-of-band rescue channel — go locate that button in your provider's dashboard *right now*, so you aren't hunting for it in a panic during an incident.

✅ **Checkpoint**:
- [ ] `ssh sam@203.0.113.10` logs in cleanly
- [ ] `ssh root@203.0.113.10` is rejected (`Permission denied`)
- [ ] You know exactly where your cloud provider's VNC / web console lives

### 1.5 Firewall (ufw)

**[server]** Configure the Uncomplicated Firewall (`ufw`) to allow only SSH and web traffic:

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

> Expose only these three ports. The application's port `3000` and PostgreSQL's port `5432` are **deliberately kept closed** to the public internet — they should only ever be reached locally by Nginx and the app on the same machine.

✅ **Checkpoint**: `sudo ufw status` lists only ports 22, 80, and 443; opening a fresh terminal window can still SSH into the server.

---

## Chapter 2: Meet demo-app, Run It Locally

### 2.1 Get the code

The companion application for this course lives right inside this repository (under `demo-app/`). Copy it out into a fresh directory to serve as your own project:

**[local]**:

```bash
cp -r /path/to/deploy_tutorial/demo-app ~/Projects/demo-app
cd ~/Projects/demo-app
rm -rf node_modules        # in case the copy brought dependency caches along
git init -b main
pnpm install               # first install; also generates pnpm-lock.yaml
git add -A && git commit -m "demo-app v1: web + worker + migrations"
```

> **Why `pnpm-lock.yaml` must be committed**: The lockfile pins the exact version and cryptographic checksum of every dependency in your tree. On the server, running `pnpm install --frozen-lockfile` guarantees that the exact same package versions are installed — preventing the classic "works on my machine, breaks in production" tragedy (which you'll deliberately trigger and debug in the intermediate book's bad-commit drills).

Take a quick look at the project layout (every source file is under 50 lines of code):

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

Running locally requires Docker (Docker Desktop or Rancher Desktop on macOS/Windows). If you don't have Docker installed on your laptop, feel free to skip straight to Chapter 3 and run everything on the server.

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

Expected output:

```
demo-app web listening on 127.0.0.1:3000 (version dev)
```

Open `http://localhost:3000` in your browser, then open another terminal window to hit the readiness endpoint:

```bash
curl -s localhost:3000/health/ready
# {"ok":true,"db":true,"lastPingId":1,"notes":0}
```

Seeing `"db":true` confirms that the web process connected to Postgres and completed a real write check. Next, exercise the full asynchronous pipeline (create a note → enqueue a background job → consume it with the worker):

```bash
curl -s -X POST localhost:3000/api/notes -H 'content-type: application/json' -d '{"title":"hello"}'
# {"note":{...},"jobId":1}
pnpm run worker          # start the worker in another terminal; Ctrl-C after a few seconds
curl -s localhost:3000/api/jobs/1
# {"id":"1",...,"status":"done","result":{"shouted":"HELLO","length":5},...}
```

Once you've seen the pieces work together on your own machine, setting them up on the server will feel straightforward.

### 2.3 Push to your own GitHub repository

**[local]**:

```bash
gh repo create demo-app --private --source=. --push    # if you have GitHub CLI
# or: create an empty private repo named demo-app on the web UI, then:
# git remote add origin git@github.com:yourname/demo-app.git && git push -u origin main
```

✅ **Checkpoint**: Your private repository on GitHub contains `pnpm-lock.yaml` and all application source files, while `.env` is **not** present (kept out by `.gitignore`).

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

The repository's `docker-compose.yml` launches a PostgreSQL container. Pay close attention to how its port mapping is written:

```yaml
ports:
  - "127.0.0.1:5432:5432"
```

> **Why bind to `127.0.0.1` only**: Writing `"5432:5432"` tells Docker to bind port 5432 on **every** network interface (bypassing `ufw` rules in the process) — effectively publishing your database to the entire internet. Even with a password, exposing a database port publicly creates needless attack surface. Prefixing the mapping with `127.0.0.1:` ensures only processes on the server itself can connect. Forgetting that prefix is one of the most common security mistakes beginners make with Docker.

The database container reads its initial password from a `.env` file alongside `docker-compose.yml` (not to be confused with `.env.example` in git; the server's `.env` **never enters git**). First, prepare the application directory under `/srv`:

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

> Notice the `.node-version` file in the repository root, which specifies `24.22.1`. In the intermediate book, the deployment script verifies that the server's Node major version matches what the repository declares — runtime version drift is another classic culprit behind "works locally, breaks in prod" (and you'll rehearse a Node version mismatch in the intermediate bad-commit drills). Also note: on 2026-10-21, Node.js patched 10 CVEs (including an RCE-capable flaw in the Brotli decoder) — **always pin your runtime to a release that includes the latest security patches** (`22.23.4` for the 22.x line; this course uses the Active LTS release `24.22.1`).

### 3.3 A dedicated user for the app, and getting the code

Never run a web application as `root`, and don't run it as your sudo-capable `sam` user either. Instead, create a dedicated, unprivileged `app` system user — that way, if the application is ever compromised, an attacker inherits only this locked-down identity:

```bash
sudo useradd --system --create-home --shell /bin/bash app
```

Next, generate a **read-only** GitHub deploy key for the `app` user (it can pull code from your repository, but cannot push — bounding the blast radius if the key is ever leaked):

```bash
sudo -u app mkdir -p /home/app/.ssh
sudo -u app ssh-keygen -t ed25519 -f /home/app/.ssh/id_ed25519 -N "" -C "app@server pull key"
sudo -u app cat /home/app/.ssh/id_ed25519.pub
# paste into GitHub: repo → Settings → Deploy keys → Add (leave "write access" unchecked)
sudo -u app ssh-keyscan -t ed25519 github.com >> /tmp/kh && sudo -u app tee -a /home/app/.ssh/known_hosts < /tmp/kh >/dev/null
```

> `ssh-keyscan` pre-populates GitHub's host key into `/home/app/.ssh/known_hosts`, ensuring that non-interactive `git clone` and `git pull` commands won't hang waiting for someone to type `yes` at a fingerprint prompt.

Now hand ownership of `/srv/demo-app` to `app`, clone the repository, install dependencies, and run the initial build:

```bash
sudo chown -R app:app /srv/demo-app
sudo -u app git clone git@github.com:yourname/demo-app.git /srv/demo-app
sudo -u app bash -c 'cd /srv/demo-app && pnpm install --frozen-lockfile && pnpm run build'
```

### 3.4 Config files and the database

Now create the two server-side configuration files (mirroring what you used locally in section 2.2, but locked down with production ownership and permissions).

**[server]** `# file: /srv/demo-app/.env` (holds the database password read by Docker Compose):

```bash
cd /srv/demo-app
sudo -u app bash -c 'umask 077 && echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)" > .env'
sudo -u app grep -c PASSWORD .env    # outputs 1 — it's there (don't cat it; fewer eyes on secrets)
```

Start the Postgres container and verify it is healthy:

```bash
sudo docker compose up -d db     # note: the app user is NOT in the docker group — plain sudo
docker ps --format '{{.Names}} {{.Status}}'
# demo-app-db Up 2 minutes (healthy)
docker exec demo-app-db pg_isready -U demo_app
# accepting connections
```

**[server]** `# file: /srv/demo-app/runtime.env` (application runtime environment variables, read by systemd):

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

> **Why `root:app` ownership with mode `0640`**: This file contains your production database password. Setting `root:app` and `0640` means `root` can read and write it, members of the `app` group can read it, and no other user on the system can touch it. The application process (running as `app`) can read its configuration, while your everyday `sam` account cannot casually inspect it without `sudo`. In the intermediate book, we'll take this one step further and prove that even the dedicated `deploy` user cannot read `runtime.env`.

Run the database migrations to initialize the schema:

```bash
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && pnpm run migrate'
# migrate: applying 001_init.sql
# migrate: applying 002_add_status.sql
# migrate: applied 2 file(s), done
```

### 3.5 Run it by hand, then watch it "die"

Start the application manually in the foreground:

```bash
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && node dist/server.js'
# demo-app web listening on 127.0.0.1:3000 (version dev)
```

From a second terminal window on the server, verify that it responds — then press `Ctrl-C` in the first window:

```bash
curl -s localhost:3000/version
# {"gitSha":"dev"}
# after Ctrl-C: curl: (7) Failed to connect
```

**That right there is the central problem of this chapter**: a foreground process lives and dies with your terminal session. If your Wi-Fi drops or you close your laptop, your site goes down. Hacks like `nohup`, backgrounding with `&`, or running inside `tmux` are fragile band-aids — in the next chapter, we solve process supervision properly with `systemd`.

✅ **Checkpoint**:
- [ ] `docker ps` shows `demo-app-db` as `healthy`
- [ ] Running `dist/server.js` via `sudo -u app` works, and `curl localhost:3000/health/ready` returns `"db":true`
- [ ] `/srv/demo-app/runtime.env` has permissions `-rw-r-----  root app`
- [ ] `ufw` still allows only ports 22, 80, and 443

---

## Chapter 4: systemd — Make the App Always Show Up

### 4.1 Write a service unit

**[server]** Create `# file: /etc/systemd/system/demo-app.service`:

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

Take a moment to read through each directive (when you write a systemd unit for your own projects later, these are the exact lines you'll customize):

| Directive | What it does |
|---|---|
| `Wants=/After=` | Wait until networking is online and the Docker daemon has started (since Postgres runs in Docker) |
| `User=app` | Run the process as the unprivileged `app` user rather than `root` (least privilege) |
| `EnvironmentFile=` | Load runtime environment variables from our `0640` config file before launching the process |
| `ExecStart=` | The exact command to execute — **the binary path must be absolute** |
| `Restart=always` | Automatically restart the process whenever it exits (whether from an unhandled exception or an OOM kill) |
| `WantedBy=multi-user.target` | Hook into the standard multi-user runlevel so the service starts automatically on boot |

Reload systemd, enable the unit at boot, and start it immediately:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now demo-app
systemctl status demo-app --no-pager
```

Look for `Active: active (running)` in the output, then test the readiness endpoint:

```bash
curl -s localhost:3000/health/ready && echo
# {"ok":true,"db":true,...}
```

### 4.2 Three proofs that it "always shows up"

**🧪 Experiment 1: Kill the process and watch it self-heal**

```bash
sudo kill -9 $(systemctl show -p MainPID --value demo-app)
sleep 3 && systemctl is-active demo-app    # active — auto-restarted
```

**🧪 Experiment 2: Inspect the logs** (systemd automatically captures `stdout` and `stderr` for you):

```bash
journalctl -u demo-app -n 20 --no-pager    # last 20 lines
journalctl -u demo-app -f                  # live tail (Ctrl-C exits, doesn't stop the service)
```

> From this day forward, your first reflex whenever an application misbehaves on a Linux server should be `journalctl -u <service> -n 100`.

**🧪 Experiment 3: Reboot the entire machine**

```bash
sudo reboot
# wait a minute, ssh back in
curl -s localhost:3000/health/ready && echo
# {"ok":true,...} — boot-persistence works, and Postgres came back too
```

✅ **Checkpoint**: You have run all three experiments and seen the results firsthand. From now on, the question "is the app running?" has a single canonical answer: `systemctl is-active demo-app`.

---

## Chapter 5: Nginx + HTTPS — A Proper Street Address

### 5.1 DNS

Log into your domain registrar's DNS dashboard and add an **A record**:

```
Host: deploy-demo      (the prefix of deploy-demo.example.com)
Value: 203.0.113.10
```

**[local]** Verify that the DNS record resolves to your server's IP (propagation usually takes a few minutes):

```bash
dig +short deploy-demo.example.com
# 203.0.113.10
```

### 5.2 The Nginx reverse proxy

**[server]** Install Nginx and configure a virtual host that proxies traffic to port `3000`:

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

> **What a reverse proxy actually does**: Your Node.js process listens exclusively on the loopback interface `127.0.0.1:3000`, completely unreachable from the outside world. Nginx sits in front on public ports 80 and 443, accepts incoming client connections, and forwards them over loopback to your app. This separation gives you three big wins: TLS certificates are managed in one place, changing your app's internal port never affects your public URL, and if the app is briefly down, Nginx can serve a clean error page instead of a raw connection refusal.

Open `http://deploy-demo.example.com` in your browser — you should see the `demo-app` homepage.

### 5.3 HTTPS (Let's Encrypt)

Now use Certbot to obtain and install a free Let's Encrypt TLS certificate:

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d deploy-demo.example.com
# email → agree → sharing preference
# choose Redirect (force HTTPS)
```

Behind the scenes, `certbot` just performed three important steps: it proved to Let's Encrypt that you control `deploy-demo.example.com` (by serving a temporary challenge token over port 80), rewrote your Nginx configuration to enable TLS and redirect HTTP to HTTPS, and installed a systemd timer to renew the certificate automatically before it expires. Verify the renewal timer and perform a dry run:

```bash
sudo certbot renew --dry-run
# Congratulations, all simulated renewals succeeded
sudo systemctl list-timers | grep certbot
```

Confirm that HTTPS is live over HTTP/2:

```bash
curl -sI https://deploy-demo.example.com | head -3
# HTTP/2 200 ...
```

> Don't have a domain yet? See Appendix A for workarounds. Just remember that **in production, HTTPS is non-negotiable**: without it, every byte between your users and your server — including passwords and session cookies — travels in cleartext, visible and modifiable by any network intermediary along the path.

✅ **Checkpoint**: Opening `https://deploy-demo.example.com` in a browser displays the security padlock, and `curl -I http://deploy-demo.example.com` returns a `301` redirect to `https://`.

---

## Chapter 6: Backups and a Restore Drill (An Untested Backup Is No Backup)

> This chapter is built on a hard-won operational rule: **an untested backup is no backup**. During GitLab's famous 2017 production database outage, the team discovered that **every single one** of their five backup mechanisms was either failing silently or producing unusable files. Accordingly, the deliverable of this chapter is not "a backup script" — it is "**a backup script you have personally used to restore data**."

### 6.1 Write the backup script

**[server]** `# file: /home/sam/backup-naive.sh` (identical to `deploy/naive/backup-naive.sh` in the repository):

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

Two details in this script are worth calling out:
- `pg_dump --format=custom` writes a compressed binary archive that is restored with `pg_restore` and even allows restoring individual tables selectively.
- **The backup must include `/srv/demo-app/storage`** (on-disk file storage). Backing up the database while forgetting user-uploaded files on disk is the most common backup blind spot: when disaster strikes, your database rows come back intact, but every uploaded attachment is gone forever.

Make the script executable and run your first backup:

```bash
chmod +x ~/backup-naive.sh && ~/backup-naive.sh
# ==> latest:
# -rw-r--r-- 1 sam sam 12K 2026-10-25 12:00 20261025T040000Z.dump
```

### 6.2 Run it daily (cron)

Schedule the script to run every night via `cron`:

```bash
crontab -e
# append this line (03:17 server time daily; off the hour to avoid collisions):
17 3 * * * /home/sam/backup-naive.sh >> /home/sam/backups/backup.log 2>&1
```

> The five time fields in a `crontab` entry represent: minute, hour, day of month, month, and day of week. When you check `ls ~/backups/demo-app/db` tomorrow morning and see a fresh `.dump` file, your scheduled job is working.

### 6.3 The restore drill (the soul of this chapter)

🧪 **Experiment: Pretend disaster just struck, and restore the database to the snapshot taken five minutes ago.**

First, create a pair of notes — one before the backup, and one after:

```bash
curl -s -X POST https://deploy-demo.example.com/api/notes -H 'content-type: application/json' -d '{"title":"before backup"}'
~/backup-naive.sh
curl -s -X POST https://deploy-demo.example.com/api/notes -H 'content-type: application/json' -d '{"title":"after backup (should vanish)"}'
```

Now spin up a **temporary** PostgreSQL container dedicated to the restore drill (completely isolated from your live production database):

```bash
docker run -d --name restore-drill -e POSTGRES_PASSWORD=drill \
  -e POSTGRES_USER=drill -e POSTGRES_DB=drill postgres:16-alpine
LATEST=$(ls -1t ~/backups/demo-app/db | head -1)
docker cp ~/backups/demo-app/db/$LATEST restore-drill:/tmp/restore.dump
time docker exec restore-drill pg_restore -U drill -d drill --no-owner /tmp/restore.dump
```

Compare the contents of the restored database against the live database:

```bash
docker exec restore-drill psql -U drill -d drill -Atc "SELECT title FROM notes ORDER BY id"
# before backup          ← "after backup" is absent, as expected (RPO = backup interval)
docker exec demo-app-db psql -U demo_app -d demo_app -Atc "SELECT title FROM notes ORDER BY id"
# before backup
# after backup (should vanish)
docker rm -f restore-drill
```

**Two fundamental reliability metrics now belong to you** (and you'll measure them rigorously in the advanced book):

- **RPO** (Recovery Point Objective): The maximum age of data you can afford to lose when disaster strikes. With a once-daily backup schedule, your worst-case RPO is 24 hours.
- **RTO** (Recovery Time Objective): How long it takes to restore service after an outage begins. The elapsed time printed by `time` above is your very first empirical RTO measurement — jot it down.

### 6.4 An off-site copy

Keeping backups on the exact same server and disk as your live database means a single hardware or provider failure wipes out both at once. The simplest, zero-cost off-site backup is pulling a copy to your own machine:

**[local]** Sync the backup directory down to your computer:

```bash
mkdir -p ~/demo-app-backups
rsync -av sam@203.0.113.10:backups/demo-app/ ~/demo-app-backups/
```

Schedule that `rsync` command on your local machine as well (via `crontab -e` on macOS/Linux, or Task Scheduler on Windows). We'll cover automated cloud off-site backups using object storage and `rclone` in Chapter 6 of the advanced book.

✅ **Checkpoint**:
- [ ] You ran a manual backup and verified that `~/backups/demo-app/db` contains a `.dump` file
- [ ] You completed the full restore drill and confirmed that the `"after backup"` row was absent in the restored database (which is the exact proof you want)
- [ ] `cron` is configured on the server, and an off-site copy sits on your local machine
- [ ] You can state without hesitation: what is my current RPO?

---

## Chapter 7: Your First Pipeline — deploy-v0 and Its Eight Sins

Right now, shipping every code change requires SSH-ing into the server and typing a sequence of commands by hand. Let's wrap those commands into a deployment script — and then take an honest look at every flaw hiding inside it. Those eight flaws form the exact table of contents for the intermediate book.

### 7.1 The v0 deploy script

**[server]** `# file: /home/sam/deploy-naive.sh` (identical to `deploy/naive/deploy-naive.sh`):

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

Make it executable:

```bash
chmod +x ~/deploy-naive.sh
```

### 7.2 Experience the full loop

**[local]** Edit a single line of code, commit, and push to GitHub:

```bash
cd ~/Projects/demo-app
sed -i '' 's/<h1>demo-app<\/h1>/<h1>demo-app v2<\/h1>/' src/server.js   # macOS; on Linux use sed -i
git commit -am "v2: change title" && git push
```

**[server]** Trigger your deployment script and verify the updated heading:

```bash
~/deploy-naive.sh && curl -s https://deploy-demo.example.com | grep h1
# <h1>demo-app v2</h1>
```

Congratulations — you have a working deployment pipeline! Now comes the honest reckoning.

### 7.3 Judgment day: the eight sins

**🧪 Sin #1: The downtime window.** While `systemctl restart` stops the old process and boots the new one, incoming requests fail. Let's measure that gap firsthand.

**[local]** Poll the readiness endpoint every 200ms in a tight loop:

```bash
while true; do
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://deploy-demo.example.com/health/ready || echo FAIL
  sleep 0.2
done
```

**[server]** In another terminal, run `~/deploy-naive.sh` and watch your local output. You'll spot several `000 ...s` or `FAIL` lines — from a user's perspective, the site was unreachable during that window. **Write down how long the consecutive failures lasted** (typically a few hundred milliseconds to a couple of seconds). The intermediate book shrinks this window with an atomic symlink switch, and the advanced book's blue-green deployment experiment drives it down toward zero.

**🧪 Sin #2: Building on the production machine.** Running `pnpm install` and `pnpm run build` on the same machine that serves live traffic steals CPU and RAM (visibly spiking response latency on small instances), and **if external network access is down, you cannot deploy at all**. Prove it to yourself (note that your Git remote uses SSH over port 22, so we block outbound ports 22 and 443; your current SSH session won't drop because `iptables` `OUTPUT` rules only block *new* outbound connections):

```bash
sudo iptables -A OUTPUT -p tcp --dport 22 -j DROP    # git@github.com goes through here
sudo iptables -A OUTPUT -p tcp --dport 443 -j DROP
~/deploy-naive.sh        # expected: fails at the git pull stage
sudo iptables -D OUTPUT -p tcp --dport 22 -j DROP    # remove both rules when done
sudo iptables -D OUTPUT -p tcp --dport 443 -j DROP
```

**🧪 Sin #3: Half-done states.** Suppose `pnpm run build` fails halfway through (for instance, you pushed a syntax error). Even though `set -e` aborts the script, think about where the server is left: if `dist/` was partially overwritten, or if a failure occurred *between `migrate` and `restart`*, the database now holds the new schema while the old code is still running in memory. If nothing broke today, it was pure luck.

**🧪 Sin #4: No health check.** The script prints `deployed:` and declares victory the moment `systemctl restart` returns. Did the new process actually stay up? Can `/health/ready` still talk to the database? The script has no idea. In real-world operations, deployments that crash within 30 seconds of startup (due to missing environment variables, bad config, or OOM kills) happen all the time.

**🧪 Sin #5: Rollback by adrenaline.** What happens when a new release goes live and immediately starts throwing 500s? Right now, rolling back means frantically SSH-ing in to run `git reset`, rebuilding from scratch, and restarting — all while users are staring at errors and the previous build artifacts have already been overwritten. **Rolling back should be a calm, single-command operation that works even without internet access** (which is exactly what the intermediate book's `rollback.sh` provides).

**🧪 Sin #6: Excessive privileges.** This script runs as `sam`, an account with unrestricted `sudo` access over the entire machine. Yet deploying an application only requires permission to do three specific things: restart the app services, run migrations, and trigger a backup. Least privilege demands narrowing the deployment channel down to those exact operations.

**🧪 Sin #7: No audit trail.** Who deployed which commit, when, how long did it take, and did it succeed or roll back? Right now, the only way to answer those questions is to archaeology-dig through someone's `.bash_history`.

**🧪 Sin #8: The code/migration skew window.** Because the script runs `migrate` before `restart`, there is a window between the migration finishing and the new process starting where **old application code is running against the new database schema**. Purely additive migrations usually survive this gap, but destructive schema changes (like dropping or renaming a column) will immediately break the running code — and make rolling back impossible. You'll learn the safe two-phase pattern (expand/contract) in Chapter 6 of the advanced book.

### 7.4 Beginner book wrap-up

You now have a **genuinely usable** deployment workflow for small projects — along with an honest diagnosis of its engineering limits. The intermediate book systematically replaces each of the eight sins with a production-grade mechanism:

| Sin | The intermediate fix |
|---|---|
| #1 downtime window | Immutable `releases/<sha>` directories + an atomic `current` symlink switch |
| #2 building in prod | Kept initially for simplicity; evaluated with empirical data in the advanced book's build-location experiment |
| #3 half-done states | Build and stage inside a temporary `.partial` directory; promote to a release only after every check passes |
| #4 no health check | Assert `/version` == target SHA + real DB read/write + worker heartbeat + a post-start soak window |
| #5 rollback by adrenaline | `rollback.sh`: a first-class, single-command rollback that requires no network access |
| #6 excessive privileges | A dedicated `deploy` user + SSH forced command + a locked-down `sudoers` whitelist |
| #7 no audit trail | `audit.log`: one structured line appended per operation (who, when, SHA, outcome, duration) |
| #8 code/migration skew | Never switch code if a migration fails; handle breaking schema changes via expand/contract |

✅ **Graduation checkpoint**:
- [ ] You can explain from memory what `systemctl status`, `journalctl -u`, and `ufw status` each do
- [ ] You have completed a full database restore drill and can state your RPO
- [ ] You have measured `deploy-naive.sh`'s downtime window yourself and recorded the number
- [ ] You can explain each of the eight sins in your own words

---

## Appendix A: No Domain?

- **Direct IP + HTTP only**: Skip the `certbot` section and set `server_name _;` in your Nginx config. The downsides are significant: no browser padlock, cleartext traffic, and exposed session cookies. Use this only for throwaway testing.
- **Wildcard DNS services (`sslip.io` / `nip.io`)**: A hostname like `203.0.113.10.sslip.io` automatically resolves to `203.0.113.10` with zero configuration. This is handy for practicing DNS resolution and TLS certificate issuance, but because everyone shares the same parent domain, you can easily hit Let's Encrypt rate limits — **never use it in production**.
- **Honest advice**: Spending $2/year on a real domain name is the highest-leverage learning investment you can make.

## Appendix B: Free Local VM Practice

If you don't want to rent a cloud VPS yet, three Multipass commands will spin up an identical Ubuntu 24.04 virtual machine on your laptop:

```bash
brew install --cask multipass          # or the official installer
multipass launch --name lab --memory 2G --disk 10G 24.04
multipass shell lab                    # equivalent to ssh; the rest of the chapters work as-is
multipass delete lab && multipass purge  # destroy when done
```

Limitations: Because a local VM has no public IP address, Chapter 5's HTTPS setup requires a self-signed certificate instead of Let's Encrypt, and the intermediate book's GitHub Actions workflow must be simulated by invoking the CI SSH command from your host machine (covered in Appendix C of the advanced book). **Bottom line: a local VM is great for learning the concepts, but use a real VPS to experience the full end-to-end chain.**

## Appendix C: Porting to Your Own App

The deployment skeleton you built in this book is language-agnostic. When adapting it to your own project, walk through this checklist:

| What changes | Where to update it |
|---|---|
| Application port (`3000`) | `PORT` in `runtime.env` + `proxy_pass` in your Nginx site config |
| The "build" step (`pnpm run build`) | Any command that produces a runnable artifact (`go build`, `mvn package`, frontend bundle, etc.) |
| Database (containerized Postgres) | Swapping to MySQL or SQLite only changes `docker-compose.yml` and `DATABASE_URL`; if your app has no database, drop the `migrate` steps |
| systemd service unit | Update the `ExecStart=` line (e.g., `/usr/bin/java -jar app.jar` for Java, or `/srv/.../.venv/bin/gunicorn ...` for Python) |
| Backup script | Replace `pg_dump` with `mysqldump` or a SQLite `.backup` command; **always keep the `storage` directory archive** |
| `/health/ready` endpoint | Strongly recommended for every app: verify critical dependencies and perform a real database read/write check |

## Appendix D: Common Errors Quick Reference

| Error | Cause → Fix |
|---|---|
| `Permission denied (publickey)` | Local private key doesn't match the server's `authorized_keys`, or you specified the wrong username → run `ssh -v user@ip` to see which keys SSH tried |
| `curl: (7) Failed to connect ... port 3000` | The application process is not running → check `systemctl status demo-app` and `journalctl -u demo-app -n 50` |
| `502 Bad Gateway` (Nginx error page) | Nginx is up, but nothing is answering on port 3000 → same commands as above; 90% of the time the app crashed on startup |
| `EADDRINUSE` | Port 3000 is already occupied by another process → run `sudo ss -ltnp | grep 3000` to find and stop the conflicting PID |
| `password authentication failed for user "demo_app"` | The password in `.env` does not match `DATABASE_URL` in `runtime.env` → align the two passwords, then recreate the container (note: changing `.env` on an existing volume does not update Postgres's stored password; in a lab environment, `docker compose down -v` resets the volume from scratch, **deleting all database data**) |
| `pnpm install` lockfile mismatch | `package.json` was edited locally without updating the lockfile → run `pnpm install` locally and commit the updated `pnpm-lock.yaml` |
| Page still shows old content after deploy | Build step didn't run or the browser cached the response → check `curl -s https://yourdomain/version`, then hard-refresh the browser |
| `disk full` / `No space left on device` | Logs or old backups filled the disk → inspect usage with `df -h`, trim journal logs with `sudo journalctl --vacuum-size=200M`, and prune `~/backups` |

---

*Next book: [Intermediate — push-to-deploy with automatic rollback](02-intermediate.md)*
