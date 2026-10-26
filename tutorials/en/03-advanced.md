# Advanced: Experiments, Measurements, and Upgrade Decisions

> **What you'll learn**: How to answer four real architectural questions through controlled experiments—where to build, how to trigger deployments, how to switch traffic, and how to manage credentials; how to turn backups from "they should work" into a drilled record backed by measured RPO and RTO numbers; how to inflict real deployment incidents on yourself (`kill -9`, power loss, OOM) and watch the system heal; and finally, how to walk away with an honest decision framework for when Kubernetes is actually worth the cost.
>
> **Prerequisites**: You have completed the Intermediate book (with the v1 pipeline running live) and are willing to break your own lab server. **Strongly recommended**: spin up a fresh, hourly-billed VPS for the experiments in this book and destroy it when you finish (total cost is usually <$1). Do not run the destructive experiments in Chapters 2, 3, or 7 on a machine serving real users.
>
> **Principles**: Build once, deploy everywhere; rollback safety; drilled backups; contained blast radius; short-lived credentials; reconcilable desired state; and simplicity first—including knowing when **not** to adopt a tool.

**Method**: Every section in this book is a controlled experiment that follows a fixed structure:

```
Hypothesis: we believe X (usually the reference design or an industry "best practice")
Steps:     how to run the experiment (commands)
Observe:   what to watch, how to record
Verdict:   X holds / fails; under what conditions a switch is worth it (upgrade trigger)
```

> The iron rule of this format: **every conclusion requires empirical evidence (commands, logs, exit codes), never bare assertions.** After completing each experiment, leave yourself at least one line of concrete evidence in your notes.

---

## Chapter 1: The Measurement Toolbox

Architecture debates without numbers are just opinions colliding. Before changing how we deploy, let's put together four practical measurement tools:

### 1.1 Measuring the downtime window (millisecond precision)

**[local]** `# file: measure-downtime.sh`

```bash
#!/usr/bin/env bash
# fire a request every 50ms, log every result, summarize the consecutive-failure window
URL="${1:-https://deploy-demo.example.com/health/ready}"
: > /tmp/downtime.tsv
while true; do
  t=$(date +%s%3N)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || echo 000)
  printf '%s\t%s\n' "$t" "$code" >> /tmp/downtime.tsv
  [ "$code" = "000" ] && echo "FAIL at $(date +%H:%M:%S.%3N)"
  sleep 0.05
done
# stop with Ctrl-C, then analyze:
# awk -F'\t' '$2!="200"{print}' /tmp/downtime.tsv | head
# first-minus-last timestamp of the failure run = the downtime window (ms)
```

> **macOS note**: `date +%s%3N` uses a GNU extension; macOS's BSD `date` prints a literal `N` instead of milliseconds. To run this measurement from a Mac, install GNU coreutils (`brew install coreutils`) and replace `date` with `gdate` in the script.

### 1.2 Latency and throughput

```bash
# hey (brew install hey, or grab a release)
hey -z 60s -c 10 https://deploy-demo.example.com/health/ready
# watch three numbers: average latency, p99, errors. Run before AND after each comparative experiment
```

### 1.3 RPO / RTO

- **RPO** (Recovery Point Objective — how much data loss is tolerable) = backup interval + replication lag. Under our current v1 scheme—daily scheduled backups plus a `premigrate` backup before every deploy—the worst-case data loss is 24h.
- **RTO** (Recovery Time Objective — how much downtime is tolerable) = detection time + recovery time. In Chapter 6, we will measure end-to-end how long it takes to rebuild a machine from scratch using a backup.

### 1.4 The experiment log template

Record five lines per experiment in `docs/experiments.md` inside your repository:

```
## E<number> <name> (date)
Hypothesis:
Steps:
Observe:   (paste key logs/numbers)
Verdict:
Trigger:   (under what conditions to switch / not switch)
```

---

## Chapter 2: Experiment — the Restart Window and Blue-Green

### 2.1 Baseline: measure v1's window

**Hypothesis**: The Intermediate book's "atomic symlink switch + service restart" still leaves an observable downtime window lasting tens to hundreds of milliseconds.

**Steps**:
1. **[local]** Start `measure-downtime.sh` against your live endpoint.
2. **[server]** Trigger a deployment (change an inconsequential string and push).
3. Press Ctrl-C once the deployment completes, then analyze `/tmp/downtime.tsv`.

**Observe**: You will see a streak of `000` responses—and between them, a gap in the stream of `200`s. Typical durations run from **200 to 1500ms**, depending on how long systemd waits for the old process to drain and how quickly the new process boots. **Record the honest numbers; do not claim zero downtime.** In-flight requests tell their own story: graceful shutdown lets most established requests finish, but new connections arriving while the listening socket is closed fail immediately.

**Verdict**: The v1 downtime window equals old-process stop time + new-process boot time + time to become healthy. Eliminating that gap requires keeping **both the old and new processes alive simultaneously**—which is the essence of blue-green deployment.

### 2.2 Minimal blue-green: two slots + an Nginx switch

Single-machine blue-green deployment needs no container orchestrator: just two release slots, an Nginx upstream block that remembers which slot is currently "on stage," and a short switch script.

**Layout** (on the lab machine):

```
/srv/demo-app/
├── releases/<sha>/          # unchanged
├── blue  → releases/<shaA>  # slot symlinks
├── green → releases/<shaB>
└── current → blue           # "who is on stage"
```

Application configuration: run blue on `PORT=3010` and green on `3020` (supplied via `runtime.env.blue/green`). Update Nginx to route through an `upstream` block:

```nginx
# replace the location block in /etc/nginx/sites-available/demo-app:
location / {
    proxy_pass http://demo_backend;
    ...
}
# and add at the top of the file:
upstream demo_backend {
    server 127.0.0.1:3010;   # blue (initial)
}
```

**The switch script** `# file: /opt/demo-app/bin/switch-slot.sh` (the essential 30 lines):

```bash
#!/usr/bin/env bash
# switch-slot.sh <sha> — stage the new version on the "off-stage" slot, health-check it,
# flip Nginx, then stop the old slot
set -euo pipefail
. /opt/demo-app/bin/app.conf
SHA="${1:?sha}"; NEXT_PORT="${2:?3010|3020}"

# 1. point the off-stage slot at the new release
# note: readlink WITHOUT -f — current's direct target IS the slot name (blue/green);
# readlink -f resolves all the way to releases/<sha>, so the on-stage slot is never detected
DEPLOYED=$(basename "$(readlink "$SRV_ROOT/current")")
[ "$DEPLOYED" = "blue" ] && NEXT=green || NEXT=blue
ln -sfn "releases/$SHA" "$SRV_ROOT/.slot.tmp" && mv -T "$SRV_ROOT/.slot.tmp" "$SRV_ROOT/$NEXT"

# 2. start the off-stage units (templated demo-app-web@.service units, one port each)
systemctl start "demo-app-web@$NEXT" "demo-app-worker@$NEXT"

# 3. health-check the NEW slot (healthcheck.sh's 2nd argument overrides the port)
/opt/demo-app/bin/healthcheck.sh "$SHA" "$NEXT_PORT"

# 4. atomically flip Nginx: rewrite the upstream file + reload (reload drops no connections)
sed -i "s/server 127.0.0.1:30[0-9]*;/server 127.0.0.1:$NEXT_PORT;/" \
  /etc/nginx/sites-available/demo-app
nginx -t && systemctl reload nginx
ln -sfn "$NEXT" "$SRV_ROOT/.cur.tmp" && mv -T "$SRV_ROOT/.cur.tmp" "$SRV_ROOT/current"

# 5. after a watch window, stop the old slot (the soak duty moves here)
sleep 30
OLD=$([ "$NEXT" = blue ] && echo green || echo blue)
systemctl stop "demo-app-web@$OLD" "demo-app-worker@$OLD" || true
echo "switched to $NEXT ($SHA)"
```

(Completing the setup—creating a templated `demo-app-web@.service` unit, preparing both `runtime.env` variants, and wiring this script into `deploy.sh` in place of steps 12 and 13—is left as this chapter's hands-on exercise. Every concept comes straight from the Intermediate book; the only shift is moving from a single `current` symlink to alternating between two slots.)

### 2.3 Measure and conclude

**Steps**: Repeat the downtime measurement from Section 2.1, this time deploying through the blue-green path.

**Observe**: `/tmp/downtime.tsv` records **not a single `000`**. Nginx's `reload` swaps upstreams seamlessly while existing connections finish draining on the old workers. The measured downtime window is **≈ 0ms**. (Honest caveats still apply: database migrations still run before the flip; long-lived connections and WebSockets need explicit reconnect handling; and during the 30 seconds when old and new workers run side by side, either worker may claim a queued job—which is exactly why `FOR UPDATE SKIP LOCKED` from the Intermediate book matters.)

**Verdict and upgrade triggers**:

| Option | Downtime | Complexity cost | Worth it when |
|---|---|---|---|
| v1 restart switch | ~0.2–1.5s | Low | Internal tools, low traffic, or users who can tolerate a brief refresh during deploys |
| Single-machine blue-green | ≈0ms | +slot management, 2× process memory | Public-facing services, formal SLAs, and enough RAM to hold two copies at once |
| Multi-machine rolling / K8s | ≈0ms | Full orchestration stack | Too many machines to manage by hand (see Chapter 9) |

---

## Chapter 3: Experiment — Where to Build

**Hypothesis**: Building directly on the production server has three drawbacks: (a) it steals CPU and RAM from the live service, (b) an internet or registry outage blocks deployments, and (c) building the same commit twice may not produce identical artifacts. Building artifacts in CI fixes all three, at the cost of artifact distribution infrastructure.

### 3.1 Baseline: the cost of building in place

**Steps**:
1. **[server]** Keep resources constrained—a 1GB RAM lab machine is ideal for this test.
2. **[local]** Run `hey -z 120s -c 10` continuously while triggering a deployment.
3. Record `hey`'s p99 latency and error count during the deploy; watch available memory with `free -m`; and if the kernel OOM-killer strikes, capture the evidence with `journalctl -k | grep -i oom`.

**Observe** (typical on a 1GB machine): During `pnpm install` and TypeScript compilation, p99 latency climbs sharply (often 2–5×). Under tighter memory pressure, the Node build process may be killed by the OOM killer—**the deployment fails, yet the live service keeps serving traffic without interruption** thanks to `.partial` directory isolation. Record that observation too; it is a real strength of the v1 design.

### 3.2 The CI-artifact variant

Add a `package` job to your GitHub Actions workflow (the essential changes):

```yaml
package:
  needs: check
  if: github.ref == 'refs/heads/main'
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: pnpm/action-setup@v4
      with: { version: 11 }
    - uses: actions/setup-node@v4
      with: { node-version: 24, cache: pnpm }
    - run: pnpm install --frozen-lockfile && pnpm run build
      env: { GIT_SHA: ${{ github.sha }} }
    - run: tar -czf artifact.tar.gz dist migrations
    - run: sha256sum artifact.tar.gz | tee artifact.sha256
    - uses: actions/upload-artifact@v4
      with:
        name: release-${{ github.sha }}
        path: artifact.*
        retention-days: 14
```

On the server, replace steps 6–8 of `deploy.sh` with "download the artifact, verify its `sha256` checksum, and extract the tarball" (via `gh run download` or a pre-signed object-storage URL). **The core principle: build once, deploy everywhere—the exact bytes that CI tested and packaged are the exact bytes that run in production.**

### 3.3 The three comparisons

| # | Experiment | Server-build (v1) | CI-artifact |
|---|---|---|---|
| 1 | Load test during deploy (same as 3.1) | p99 latency degrades | **No degradation** (the server only extracts a tarball) |
| 2 | Deploy with outbound internet cut | `git fetch` fails immediately; **however, `rollback.sh` still works** because it never touches the network | Once the artifact has arrived over the deploy channel, extraction needs no internet—though the transfer channel itself still does. **Common ground: rollback is always offline-capable** |
| 3 | Reproducibility | Build the same SHA twice and the `sha256` **differs** (`dist/version.json` embeds `buildTime`!) | Same root cause; fix it by dropping `buildTime` or pinning `SOURCE_DATE_EPOCH`, after which repeated builds yield identical checksums |

**Observe 3, live**:

```bash
# build the same SHA twice on the server, compare artifact hashes
cd /srv/demo-app && sudo -u deploy bash -c \
  'cd /tmp && rm -rf r1 r2 && mkdir r1 r2
   for d in r1 r2; do (cd $d && git --git-dir=/srv/demo-app/repo.git archive <SHA> | tar -x \
     && env GIT_SHA=<SHA> pnpm install --frozen-lockfile >/dev/null 2>&1 && pnpm run build >/dev/null 2>&1); done
   find r1/dist -type f | sort | xargs sha256sum > 1.sums
   find r2/dist -type f | sort | xargs sha256sum > 2.sums
   diff 1.sums 2.sums && echo REPRODUCIBLE || echo NOT-REPRODUCIBLE'
# expected: the version.json line differs → NOT-REPRODUCIBLE. Drop buildTime → REPRODUCIBLE
```

**Verdict and upgrade triggers**:

| Dimension | Server build | CI build |
|---|---|---|
| Impact on live traffic | Yes (worse on smaller machines) | None |
| Network dependency | `git fetch` + language package registry | Only the artifact transfer channel |
| Rollback speed | Instant from `releases/` | Identical (the `releases/` layout is unchanged) |
| Extra infrastructure | Zero | Artifact storage + download credentials |
| **Switch when** | — | Machines ≤2GB RAM / multiple servers deploying the same build / compliance requires artifact archival / flaky package registries |

For a single-machine `demo-app`, **staying with server-side builds is also a completely defensible engineering call** (simplicity first). Having run both experiments yourself, that decision is now backed by your own data rather than industry folklore.

---

## Chapter 4: Experiment — Push (SSH) or Pull (Poll)

**Hypothesis**: Push-over-SSH requires keeping inbound port 22 open, leaving it permanently exposed to internet-wide scanning and brute-force attacks. A Pull model—where the server periodically polls GitHub—shrinks the inbound attack surface to zero, at the cost of polling latency and DIY failure visibility.

### 4.1 First, look at what port 22 sees

```bash
sudo journalctl -u ssh --since today | grep -c "Invalid user"   # today's brute-force attempts
# a lab machine open for days usually shows hundreds to tens of thousands
sudo apt install -y fail2ban && sudo systemctl enable --now fail2ban   # the minimum mitigation
```

### 4.2 The pull prototype (30 core lines)

**The reuse insight**: Pull is not a brand-new deployment system—it is simply a **different caller**. `deploy.sh` does not change by a single character.

`# file: /opt/demo-app/bin/poll.sh` (owned by `root`, triggered every 60s by a systemd timer):

```bash
#!/usr/bin/env bash
# poll.sh — check GitHub's main HEAD; if it differs from live, run deploy.sh
set -euo pipefail
. /opt/demo-app/bin/app.conf
REPO="yourname/demo-app"
TOKEN_FILE="/opt/demo-app/env/poll.token"     # read-only token, root:app 0640

CURRENT=$(basename "$(readlink "$SRV_ROOT/current")")
LATEST=$(curl -fsS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  "https://api.github.com/repos/$REPO/commits/main" | jq -r .sha)

if [ "$LATEST" = "$CURRENT" ]; then echo "up to date"; exit 0; fi
echo "drift detected: live=$CURRENT latest=$LATEST — deploying"
sudo -u deploy flock -n "$LOCK_FILE" /opt/demo-app/bin/deploy.sh "$LATEST" \
  || echo "deploy failed or locked (see audit.log)"
```

```ini
# /etc/systemd/system/demo-app-poll.service
[Unit]
Description=demo-app deploy poller
[Service]
Type=oneshot
ExecStart=/opt/demo-app/bin/poll.sh
```

```ini
# /etc/systemd/system/demo-app-poll.timer
[Unit]
Description=run demo-app poller every minute
[Timer]
OnCalendar=*:*:00
Persistent=true
[Install]
WantedBy=timers.target
```

Once the timer is enabled, you can run `sudo ufw delete allow OpenSSH` (or restrict SSH to your office IP range)—**shrinking your inbound SSH exposure to zero**. That is the entire security payoff of the pull model.

### 4.3 The comparison

| Dimension | Push-SSH | Pull |
|---|---|---|
| Inbound exposure | Port 22 (mitigated by forced command + fail2ban) | **Zero** (only ports 80/443 open) |
| Deploy latency | Seconds after push | ≤ polling interval (60s) |
| Failure visibility | The GitHub Actions page turns red immediately | DIY (logs and alerting; see Chapter 8) |
| Audit trail | Initiated by CI, clear causal chain | Server-initiated (`actor=poller`) |
| External dependency | GitHub Actions healthy + server reachable from the internet | Server can make outbound HTTPS requests to GitHub |

**Upgrade triggers**: Switch to Pull when you have ≥2 machines (and don't want CI pushing to each host in a loop), face a strict "no inbound management ports" compliance rule, or want to eliminate SSH brute-force noise entirely. Stick with Push when you run a single machine and value instant feedback in the GitHub Actions UI. **Running both side by side is also a great pattern**—using Push for instant deploys and Pull as a periodic reconciliation backstop (see Chapter 8).

---

## Chapter 5: Trust and Credentials — Key Lifetimes and Trust Boundaries

### 5.1 The blast radius of static keys → short-lived SSH certificates

**Hypothesis**: The CI private key in v1 is static and long-lived; if leaked, an attacker can trigger a deployment of any commit on `main` at any time. Short-lived SSH certificates compress a credential's lifetime from "forever" down to a few minutes.

**Minimal proof of concept** (worth seeing in the lab; production can wait until you hit the trigger):

```bash
# 1. create a CA once on the server (root guards the CA private key; it never leaves the machine)
sudo ssh-keygen -t ed25519 -f /etc/ssh/democa
# 2. make sshd trust certificates signed by this CA (/etc/ssh/sshd_config.d/ca.conf):
#      TrustedUserCAKeys /etc/ssh/democa.pub
#    keep the existing authorized_keys as fallback (don't lock yourself out: add the new trust before removing the old)
sudo systemctl reload ssh
# 3. on each deploy, CI mints a 5-minute certificate on the fly:
#    -O clear -O force-command=... is critical: certificate auth does NOT read
#    authorized_keys — without it, the 5-minute window grants a full deploy-user
#    shell instead of one controlled deployment
ssh-keygen -t ed25519 -f key -N "" -C "ci-ephemeral"
ssh-keygen -s /etc/ssh/democa -I ci-deploy -n deploy -V +5m \
  -O clear -O force-command="/opt/demo-app/bin/deploy-entry" key.pub
ssh -i key -o CertificateFile=key-cert.pub deploy@host "deploy <sha>"
```

**Observe**: Five minutes later, the exact same key is rejected (`Permission denied`). The blast radius of a leaked credential shrinks from "forever" to "any legitimate SHA within a five-minute window"—provided `force-command` is baked into the certificate as well. **Expiration controls *how long* a key works; the forced command controls *what* it is allowed to do.** Neither is sufficient on its own: a short-lived certificate without `force-command` is still a five-minute pass to an interactive shell.

**Verdict**: For a single small project, a static key constrained by a forced command and an audit log already keeps the blast radius tiny (simplicity first: operating a CA safely costs more effort than it saves). **Multi-machine fleets, multi-team organizations, and compliance environments** are where short-lived certificates (or OIDC-issued dynamic credentials) earn their keep. Upgrade triggers: sharing deploy keys across >3 CI repositories, or experiencing even a single suspected key leak.

### 5.2 TOCTOU — the builder and the runner are different people

**Hypothesis**: Releases are built by the `deploy` user and executed by the `app` user. In the window between "build finished" and "service restarted," can the `deploy` user (or an attacker who compromises that account) tamper with the code that is about to run?

**Steps** (on the lab machine):
1. Start a deployment and, **before** its health check finishes, simulate tampering: `sudo -u deploy sh -c 'echo "process.exit(99)" >> /srv/demo-app/releases/<sha>/dist/server.js'`
2. Watch the outcome: the health check fails and triggers an automatic rollback. The tampered code **never stayed live in production**, but look closer: **that `<sha>` release directory is now permanently poisoned, and v1 has no mechanism to detect that a release directory's contents no longer match its Git SHA.**
3. The fix: immediately after the build step finishes, run `chown -R root:root` on the release directory and make it read-only (so `deploy` surrenders write access the moment the build completes), and have `migrate-wrapper.sh` verify root ownership before invoking `runuser`. Apply this hardening and rerun steps 1–2: the tampering attempt dies immediately with `EPERM`.

**Verdict**: The hypothesis is **confirmed**—a time-of-check to time-of-use (TOCTOU) window exists in v1, and the fix is dropping write privileges immediately after building. Note a related residual risk: `pnpm install` runs package `postinstall` scripts under the `deploy` user, which means a compromised npm dependency could read the repository's deploy key from `repo.git`. The minimal mitigation is keeping that deploy key read-only and easy to rotate; the complete fix is building artifacts in CI (Chapter 3) so the production server never runs a package manager at all.

### 5.3 Boundary inputs against the sudoers glob

Treat the Intermediate book's `sudoers` file as a firing range and test boundary inputs against it:

```bash
sudo -u deploy sudo /opt/demo-app/bin/migrate-wrapper.sh "abc...40-hex... extra arg"
# inside the script: exactly one sha argument required → the second layer catches it
sudo -u deploy sudo /opt/demo-app/bin/migrate-wrapper.sh "../../../../etc/passwd"
# layer one: sudoers' [0-9a-f]* refuses outright (leading / not in the class — never reaches the script);
# layer two: had the glob been bypassed (e.g. arguments with spaces), the in-script case refuses again
```

**Verdict**: The `sudoers` character-class glob blocks path traversal at the gate, while the script's internal validation blocks multi-word arguments that slip past `sudo`'s space-spanning `*` glob. Defense in depth is not a slogan—it is two independent checks that each catch what the other might miss. Residual risk: the trailing `*` on `audit.sh` still allows the `deploy` user to spam the local audit log; we close that gap in Chapter 8.

---

## Chapter 6: Data, Advanced — expand/contract, Big-Table Locks, Measured RPO/RTO

### 6.1 The correct shape of a destructive migration

**Hypothesis**: A destructive (`contract`) schema change such as dropping the `notes.body` column, if deployed in a single release, breaks rollback—because the previous version of the application code still runs `SELECT body`. Splitting the change into a two-phase expand/contract sequence keeps rollback safe at every point in time.

**The wrong way, live** (on the lab machine—witness the failure before applying the cure):

```bash
# drop the column + deploy → then manually rollback.sh to the old code
# old code SELECTs body → ERROR: column "body" of relation "notes" does not exist → 500s
# you have just manufactured the textbook "rollback-unsafe" case
```

**The right way — split migration 003 into two separate releases**:

```
Release 1 (expand): add the new column / dual-write / new code tolerates old shape
  migrations/003_expand.sql:  ALTER TABLE notes ADD COLUMN content text;
                              UPDATE notes SET content = body;
  server.js reads/writes both body (old) and content (new) → deploy, observe for a week
Release 2 (contract): only after confirming you'll never roll back further
  migrations/004_contract.sql: ALTER TABLE notes DROP COLUMN body;
  server.js touches only content → deploy
```

**The rollback-safety matrix** (run each combination yourself and record what you observe):

| Combination | Old schema + new code | New schema (expand) + old code | New schema (contract) + old code |
|---|---|---|---|
| Outcome | ✅ Compatible (the whole point of expand) | ✅ Compatible (the whole point of dual-writing) | ❌ Crashes (which is why you only contract once you are certain you won't roll back to the pre-expand code) |

### 6.2 Big-table migration locks

**Steps**:
1. Populate a 500,000-row table: `INSERT INTO notes(title) SELECT 'row'||g FROM generate_series(1,500000) g;`
2. In a second database session, continuously `UPDATE` random rows to simulate live production writes.
3. Compare two ways of adding an index:

```sql
-- A: plain index (locks writes)
BEGIN; CREATE INDEX idx_slow ON notes(created_at); -- watch the writer: blocked
-- B: concurrent index (does not block writes)
CREATE INDEX CONCURRENTLY idx_fast ON notes(created_at); -- writes continue
-- companion: SET lock_timeout='3s' makes lock waits fail fast instead of queueing forever
```

**Observe**: Under approach A, concurrent writes stall in a queue (visible via `SELECT * FROM pg_stat_activity WHERE wait_event_type='Lock'`). Under approach B, writes continue uninterrupted (the trade-off: index creation takes longer and cannot run inside a transaction block).

**Verdict**: Adopt the production migration trio—`lock_timeout`, `CONCURRENTLY`, and off-peak execution. And whenever you find yourself wondering *"Will this migration lock the table?"*, **rehearse it on a restored copy of the database first** (see the next section).

### 6.3 Migration dry-runs

```bash
# 1. restore a scratch database from the newest backup (Intermediate Ch.6's procedure)
# 2. dry-run then real-run against the scratch DB
DATABASE_URL=postgres://drill:drill@127.0.0.1:55432/drill node dist/migrate.js --dry-run
DATABASE_URL=postgres://drill:drill@127.0.0.1:55432/drill node dist/migrate.js
# failure? → the migration is broken, and the production database was never touched
```

Wiring "rehearse against a freshly restored scratch database before touching production" into `deploy.sh` (toggled via `MIGRATE_DRYRUN=true`) is standard practice on many mature engineering teams.

### 6.4 The measured RPO/RTO table (the drilled-backups deliverable)

Fill in every row of this table on your lab machine (the numbers are specific to your setup; the template is universal):

| Metric | Measured value | How to measure |
|---|---|---|
| Backup size (DB / storage) | ___ KB | `du -h` |
| Backup duration | ___ s | `time backup.sh manual` |
| Restore duration (into an empty DB) | ___ s | `time pg_restore` (Intermediate Ch. 6) |
| Full-machine rebuild RTO (zero to live traffic) | ___ min | Time the full disaster recovery drill in Appendix A/B |
| RPO (`daily` backup scheme) | Worst case 24h | Defined by the backup schedule |
| RPO (with hourly archive / WAL shipping) | Worst case 1h | See Chapter 9's upgrade triggers |
| Off-site copy lag | ___ | Interval of your `rsync` or `rclone` cron job |

**The lesson of GitLab's famous 2017 database incident** wasn't "they had no backups"—it was that **nobody had regularly verified a restore**. The moment every cell in this table is filled with real measurements, your backups truly exist.

---

## Chapter 7: The Crash-Consistency Lab

In this chapter, you play a QA engineer with malicious intent. Every experiment has the same acceptance bar: **the system must either recover automatically or land in an explicitly recoverable state—never leaving half-built debris behind, and never corrupting the live service.**

### 7.1 kill -9 mid-deploy

Send `SIGKILL` to `deploy.sh` at five distinct moments in the pipeline: during the build, right after backup, mid-migration, after migration but before the symlink switch, and during the health check.

```bash
# [server] while a deploy runs, find deploy.sh's PID
ps aux | grep '[d]eploy.sh'
sudo kill -9 <pid>
```

**Expected-outcome table** (verify every row hands-on):

| Moment killed | Residue left on disk | Outcome when re-running deploy |
|---|---|---|
| During build | `.partial/` directory | ✅ Automatically wiped and rebuilt cleanly |
| After backup | One extra backup file (harmless) | ✅ Proceeds normally |
| Mid-migration | Failed migration rolled back cleanly by Postgres transaction | ✅ Re-runs migration and continues |
| Post-migration, pre-switch | DB schema is new, running code is still old (safe under expand) | ✅ Skips already-applied migration idempotently and finishes the switch |
| During health check | `current` symlink flipped, but post-switch verification incomplete | ✅ Idempotency and health checks converge on a healthy state |

### 7.2 Reboot mid-everything

Trigger a deployment and run `sudo reboot` right in the middle of it (catching it mid-migration is the most exciting test). Once the machine comes back up, inspect the state: the Postgres container restarts, systemd units report `active`, the `flock` lock file (stored on `/run`, an in-memory `tmpfs`) has vanished cleanly with the reboot, and `/srv/demo-app/current` still points to a consistent release. Spot any `.partial` debris? Trigger one fresh deploy and watch the pipeline clean it up and converge.

### 7.3 Disk nearly full

```bash
sudo fallocate -l $(( ($(df --output=avail -BM / | tail -1 | tr -dc 0-9) - 300))M /tmp/bigfile
# do the arithmetic in -BM (MB): subtracting from -BG's whole-GB figure goes negative on most machines
# leave ~300MB; trigger a deploy → preflight refuses (needs 1GiB); rollback.sh still works (needs no space)
sudo rm /tmp/bigfile
```

### 7.4 The deploy freeze

```bash
sudo touch /opt/demo-app/freeze
# push a commit → deploy job log: FAILED step=freeze
sudo rm /opt/demo-app/freeze
# both refusals are visible in audit.log
```

### 7.5 Script drift detection

**Hypothesis**: Someone edits `deploy.sh` in the Git repository but forgets to re-run `install.sh` on the server. Production silently keeps running the stale script, and **nothing alerts you to the drift**.

```bash
# verify: add a comment line in the repo, push, don't reinstall → behavior unchanged (old script) → drift confirmed
# fix: reconcile in one pipeline — hash the INSTALLED files in /opt, then verify the REPO copies by name
# (note: the manifest must be checked against the repo directory; verifying /opt against itself always passes)
cd ~/demo-app-bootstrap/deploy && \
sudo sh -c 'cd /opt/demo-app/bin && sha256sum app.conf deploy-entry deploy.sh healthcheck.sh \
  check-config.sh migrate-wrapper.sh backup.sh rollback.sh audit.sh' \
  | sha256sum -c - || echo "DRIFT: installed scripts differ from repo — run install.sh"
```

**Verdict**: Drift detection is desired-state reconciliation in miniature: you must always be able to compare "the scripts that *should* be installed" against "the scripts that *are* installed." Whenever you update `install.sh`, remember to update the checksum list alongside it—the installer itself is part of the state being reconciled.

---

## Chapter 8: Observability and Reconciliation

### 8.1 Desired-state reconciliation

`# file: /opt/demo-app/bin/reconcile.sh` (run via cron, or piggybacked onto `poll.sh`):

```bash
#!/usr/bin/env bash
# three-way reconciliation: GitHub main's expectation vs live reality vs installed-script fingerprints
set -euo pipefail
. /opt/demo-app/bin/app.conf
REPO="yourname/demo-app"
LIVE=$(basename "$(readlink "$SRV_ROOT/current")")
LATEST=$(curl -fsS "https://api.github.com/repos/$REPO/commits/main" | jq -r .sha)
DRIFT_SCRIPTS=$( cd "${REPO_DEPLOY_DIR:-$HOME/demo-app-bootstrap}/deploy" 2>/dev/null && \
  sudo sh -c 'cd /opt/demo-app/bin && sha256sum app.conf deploy-entry deploy.sh healthcheck.sh \
    check-config.sh migrate-wrapper.sh backup.sh rollback.sh audit.sh' 2>/dev/null \
  | sha256sum -c - 2>/dev/null | grep -cv OK || echo unknown )
# note: when running from root's cron, export REPO_DEPLOY_DIR to the repo location first
printf 'live=%s\nlatest=%s\nscripts_drift=%s\n' "${LIVE:0:12}" "${LATEST:0:12}" "$DRIFT_SCRIPTS"
[ "$LIVE" = "$LATEST" ] || echo "⚠️  live is behind main"
[ "$DRIFT_SCRIPTS" = "0" ] || echo "⚠️  installed deploy scripts differ from repo"
```

### 8.2 Failure notifications

The minimum viable alerting setup is a single webhook call—or even a local collector file that you actually check every day:

```bash
# deploy.sh's die() already appends to audit.log; add:
curl -fsS -m 3 "$NOTIFY_WEBHOOK" -d "deploy failed: sha=$SHA step=$step" >/dev/null 2>&1 || true
# NOTIFY_WEBHOOK → Slack/Lark/Telegram incoming webhook, or a local file service
```

> Notice the trailing `|| true`: a broken notification webhook must never cause a deployment or rollback to fail. Notifications are a side channel, not part of the critical path.

### 8.3 Change control for the deploy system itself

Deployment scripts, `sudoers` rules, and CI workflows are high-privilege files capable of altering production behavior. Guard them accordingly:

1. **Enforce review with CODEOWNERS** (`.github/CODEOWNERS` in the repository):

```
/deploy/            @your-team/ops
.github/workflows/  @your-team/ops
```

2. **Add a deploy-system self-check to CI** (inside the `check` job of `ci.yml`):

```yaml
- run: sudo apt-get install -y shellcheck && shellcheck deploy/*.sh
- run: bash -n deploy/deploy-entry
- name: sudoers syntax check
  run: sudo visudo -cf deploy/demo-app.sudoers
```

3. **Tamper-evident audit logs** (closing the residual gap from Section 5.3): `audit.sh` already forwards entries to `syslog` via `logger`. Configure `rsyslog` or `journald` to ship those logs over the network to **a separate host** that the `deploy` user has no access to.

---

## Chapter 9: The Upgrade Decision Records (ADRs)

Each row below pairs a one-line architectural recommendation with a concrete, quantifiable trigger. **If you haven't hit the trigger, don't adopt the complexity**—that is what "simplicity first" looks like in day-to-day engineering.

| Decision | Upgrade trigger (adopt when any one is met) | What to use until then |
|---|---|---|
| **CI-built artifacts** | Server RAM ≤2GB / ≥2 servers / compliance requires artifact archival | Server-side build (v1 as-is) |
| **Pull-based deploys** | ≥2 machines / compliance forbids inbound SSH / brute-force log noise becomes unmanageable | Push-SSH + fail2ban + forced command |
| **Blue-green switching** | External SLA commitments / real users noticing the restart window | Atomic symlink switch + off-peak deploys |
| **Short-lived certs / OIDC** | Deploy keys shared across >3 consumers / any suspected leak / multi-team CI | Static key + audit log + rehearsed key-rotation runbook |
| **Daily → hourly backups / WAL archiving** | A 24h RPO is unacceptable (financial transactions or high-frequency user data) | Daily scheduled backup + pre-deploy backup |
| **Off-site backups to object storage** (`rclone` cron → S3/R2) | **Immediately** (storage cost is near zero; protects against datacenter-level loss) | Periodic `rsync` to a laptop (bare minimum) |
| **Ansible** | You have copy-pasted the same manual setup commands across >5 machines | This course's `install.sh` bootstrap script |
| **Terraform** | >3 distinct cloud resource types that change frequently | Manual provisioning documented in the repo |
| **Docker images + registry** | The natural next step once you already combine CI-built artifacts with multi-machine distribution | Tarball artifacts |
| **Kubernetes** | >10 machines / >15 services / dedicated platform engineering staff / genuine need for frequent elastic autoscaling | Single-machine systemd + this deployment pipeline |

> Read the fine print on the Kubernetes row carefully: the problems Kubernetes is built to solve—multi-node scheduling, cross-machine self-healing, dynamic bin-packing—**do not exist** when you run 2 services on 3 machines. Meanwhile, the problems Kubernetes introduces—cluster upgrades, certificate lifecycles, overlay networking, IAM plumbing—start on day one. Let the pain arrive first; bring in the tool second.

---

## Chapter 10: The Scenario Matrix Workbook

This chapter brings together the complete failure and security scenario matrix across all three books. Legend: ✅ = already verified in the Beginner or Intermediate book; 🧪 = hands-on exercise for this chapter (with hints included); ⭐ = Layer-2 scenarios that require live public infrastructure or real GitHub Actions runners (with verification procedures documented).

### A: Permissions & Trust

| Scenario | Status / exercise hint |
|---|---|
| Forced-command abuse matrix | ✅ Intermediate 3.5 |
| `deploy` privilege escalation attempts (editing keys/scripts, reading `.env`, running non-whitelisted `sudo`) | ✅ Intermediate 3.5 & Ch. 4; bonus check: try running `sudo -u deploy vi /opt/demo-app/bin/deploy.sh` |
| Malicious build (`postinstall` privilege escalation or secret exfiltration) | 🧪 Add `"postinstall": "cat /home/deploy/.ssh/id_ed25519"` to `package.json` → push → check whether the build log prints the private key (it will! → residual risk; fix = build in CI or pass `pnpm install --ignore-scripts`) |
| TOCTOU window + `sudoers` glob boundaries | ✅ Advanced 5.2 / 5.3 |
| Host-key mismatch must abort the deploy immediately | 🧪 Flip one character in the `DEPLOY_KNOWN_HOSTS` GitHub Secret → the next deploy must fail immediately with `REMOTE HOST IDENTIFICATION HAS CHANGED` |
| No secrets leaked in logs | 🧪 `grep -r PASSWORD /var/log/demo-app/` must return nothing (even after intentionally broken builds) |
| The `sshd` lockout recovery drill | See Appendix B |

### B: Provenance, Concurrency, Crash Consistency

| Scenario | Status |
|---|---|
| Force-pushed (dangling) SHA refused | ✅ Intermediate 3.5 (tested with the all-zeros SHA) |
| Skip-older-commit / idempotency | ✅ Intermediate 9.8 |
| Division of labor between server `flock` and workflow `concurrency` | ✅ Intermediate 7.1 / 9.8 |
| Queueing behavior across three rapid pushes | ⭐ Observe on real GitHub Actions: intermediate queued runs are superseded by the newest push (a UI-vs-reality quirk to understand); runner timeout while the server finishes in the background (✅ verified in Intermediate 9.8) |
| SSH session disconnects mid-deploy, server still completes | ✅ Intermediate 9.8 |
| `kill -9` at five pipeline stages | ✅ Advanced 7.1 |
| Full machine reboot mid-deploy | ✅ Advanced 7.2 |

### C: Build & Toolchain

Broken builds and lockfile/Node version mismatches ✅ (Intermediate Ch. 9); offline deploy and rollback ✅ (Advanced 3.3); build-time load and OOM behavior ✅ (Advanced 3.1); low-disk preflight refusal ✅ (Advanced 7.3); malicious `postinstall` scripts 🧪 (covered by the malicious-build exercise under Permissions & Trust above).

### D: Data & Migrations

End-to-end backup and restore drill ✅; backup scope and retention policy ✅ (Intermediate Ch. 6); failed migration aborts before traffic switch ✅ (Intermediate 9.4); the rollback-safety matrix ✅ (Advanced 6.1); big-table index locks ✅ (Advanced 6.2); concurrent migration locking ✅ (Intermediate 7.4); migration dry-runs against a scratch DB ✅ (Advanced 6.3).

### E: Switching, Health, Rollback

Downtime window quantified to the millisecond ✅ (Advanced 2.1); false-positive health checks caught ✅ (Intermediate 9.6); partial systemd unit failure → 🧪 run `systemctl stop demo-app-worker` and then invoke `healthcheck.sh` → verify it fails with `unit:demo-app-worker=inactive`; release migrates cleanly but crashes on boot → automatic rollback ✅ (Intermediate 9.5); rollback target is *also* unhealthy → 🧪 deliberately break both the new and previous releases (for example, by removing a required variable from `runtime.env` that the old release also needs) and confirm the pipeline reports that human intervention is required rather than claiming success; missing configuration caught before switching traffic ✅ (Intermediate 9.7); timed rollback execution ✅ (recorded in your runbook); deploy freeze switch ✅ (Advanced 7.4).

### F: Bootstrap, Operations, Portability

Timed first deploy from a bare server ✅ (Intermediate 2.3—record your elapsed minutes); script drift detection ✅ (Advanced 7.5); full recovery after host reboot ✅ (Advanced 7.2); audit logging, failure notifications, and reconciliation ✅ (Advanced Ch. 8); release retention policy 🧪 deploy 7 times in a row → `ls releases` should list 5 directories, and the previously live release must never be pruned; `CODEOWNERS` + deploy-script CI checks ✅ (Advanced 8.3).

### The hypothesis verdicts

| Initial hypothesis | Final verdict | Evidence location | Remediation / hardening |
|---|---|---|---|
| TOCTOU (builder and runner are separate users) | **Confirmed** | Advanced 5.2 | Drop write access (`chown root` read-only) right after build, or build in CI |
| Naive backup scope and retention gaps | **Confirmed** | Intermediate Ch. 6 | Back up both DB and storage; combine count-based and age-based retention |
| Naive health checks produce false positives | **Confirmed** | Intermediate 9.6 | Assert live Git SHA + worker heartbeat freshness + soak window |
| `systemctl restart` leaves a downtime window | **Confirmed** | Advanced 2.1 | Dual-slot blue-green switching (Advanced 2.2) |
| CI concurrency and runner timeout edge cases | **Partially confirmed** | ⭐ Three-rapid-pushes drill / Intermediate 9.8 | Detach with `setsid` + document where CI status can diverge from server state |
| Missing config discovered only after switching traffic | **Confirmed → Fixed** | Intermediate 9.7 | Pre-switch `check-config` validation |
| Building on production degrades live traffic | **Confirmed** | Advanced 3.1 / 3.3 | Follow the build-location decision table (Chapter 9) |
| Cannot roll back quickly by re-running a full deploy | **Confirmed → Fixed** | Intermediate 7.2 | Dedicated `rollback.sh` script |
| Missing logs, audit trail, and emergency kill switch | **Confirmed → Fixed** | Intermediate 7.6 & Ch. 10 | `audit.log`, log rotation, and `/opt/demo-app/freeze` |
| Inbound SSH exposure attracts constant attacks | **Confirmed** | Advanced 4.1 | `fail2ban` / short-lived certificates / pull-based deployment |
| Drift between repo scripts and `/opt` goes unnoticed | **Confirmed → Fixed** | Advanced 7.5 | Checksum reconciliation (`reconcile.sh`) |

---

## Chapter 11: The Portability Proof — a Second Stack (Go)

> **Goal**: Prove with working code that this deployment architecture is **genuinely** language-agnostic rather than merely claiming to be (one of this course's core success criteria). Time required: ~30 minutes.

**[local]** `# file: ~/Projects/demo-go/main.go` (40 lines, zero external dependencies):

```go
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"
)

var version = "dev" // injected at build time via -ldflags "-X main.version=$GIT_SHA"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--check-config" {
		missing := []string{}
		for _, k := range []string{"APP_ENV", "PORT"} {
			if os.Getenv(k) == "" {
				missing = append(missing, k)
			}
		}
		if len(missing) > 0 {
			fmt.Println("missing:", missing)
			os.Exit(3)
		}
		fmt.Println("check-config: OK")
		return
	}
	http.HandleFunc("/version", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"gitSha": version})
	})
	http.HandleFunc("/health/ready", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "at": time.Now().Unix()})
	})
	fmt.Println("demo-go listening")
	http.ListenAndServe("127.0.0.1:"+os.Getenv("PORT"), nil)
}
```

The complete adaptation diff (nothing else changes):

| File | Required change | Lines changed |
|---|---|---|
| `deploy/app.conf` | Set `BUILD_CMD="go build -ldflags \"-X main.version=$GIT_SHA\" -o dist/app ."` and `MIGRATE_CMD="true"`; update unit names and health URLs | ~5 |
| `deploy/demo-go-web.service` | Set `ExecStart=/srv/demo-app/current/dist/app` (drop the worker unit, which was specific to `demo-app`) | 1 |
| `deploy/demo-app.sudoers` | Update the whitelisted systemd unit names | ~6 |
| `deploy/check-config.sh` | Change `node ... --check-config` to `./dist/app --check-config` | 1 |
| `deploy/migrate-wrapper.sh` | Same (or simply `exit 0` for a stateless service) | 1 |
| systemd units | Reduce from 2 units to 1 | — |

**Total diff: ~15 changed lines across 6 files.** Meanwhile, `install.sh`, `deploy-entry`, `deploy.sh`, `healthcheck.sh` (with the single worker-heartbeat line commented out), `rollback.sh`, `backup.sh`, and the GitHub Actions workflow all carry over untouched. Copy this table into `docs/experiments.md`—that is concrete proof of a portable deployment architecture.

---

## Appendix A: The One-Page Runbook (Final)

Add these advanced operational procedures to your Intermediate runbook:

```text
═══ Zero-downtime switch (blue-green) ══════════════════════
/opt/demo-app/bin/switch-slot.sh <sha>   # 30s soak, then stops the old slot
Emergency flip-back: manually point nginx's upstream at the old port + reload
                      + systemctl start the old slot
═══ Reconciliation (glance daily) ══════════════════════════
/opt/demo-app/bin/reconcile.sh           # live vs main vs script fingerprints
═══ Disaster: the machine is gone ══════════════════════════
1. Provision a same-size replacement; start the clock (measured RTO)
2. Beginner chapters 1–3 (hardening + docker + node) + install.sh
3. Data: the restore-drill procedure with the newest premigrate/daily backup
4. Bring the service up; trigger a deploy to align with main;
   update GitHub's DEPLOY_KNOWN_HOSTS (new fingerprint!)
5. Stop the clock; log the RTO into the table (advanced 6.4)
═══ Lockout recovery (drilled in Appendix B) ═══════════════
Provider console VNC → mount/fix → restore sshd_config → sshd -t → reload
```

## Appendix B: The Lockout Drill

**On your lab machine**, deliberately break `sshd` and practice recovering out-of-band (rehearse it once in calm weather so you never panic during an outage):

```bash
sudo cp /etc/ssh/sshd_config /tmp/sshd_config.bak
echo "Port 2222" | sudo tee -a /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart ssh     # syntactically "valid" — but 2222 isn't in ufw
# new terminal: ssh → timeout (locked out!)
# recover via the provider's VNC console:
#   sudo cp /tmp/sshd_config.bak /etc/ssh/sshd_config && sudo sshd -t && sudo systemctl restart ssh
```

**The standing rule**: Whenever you touch `sshd`, `sudoers`, or `ufw`, follow the five-step anti-lockout sequence without exception: **back up the file first → validate syntax with `sshd -t` or `visudo -cf` → `reload` (never `restart`) → keep your existing SSH session open → verify access in a brand-new terminal session**. Those five steps are the entire "never lock yourself out of a server" playbook.

## Appendix C: The "Layer 2 Unverified" List

Nearly every mechanism in this course has been verified end-to-end on a live VPS wired to GitHub Actions. The four items below depend on external conditions or multi-node setups; use the documented methods to verify them in your own environment:

| Item | Why it isn't verified by default | How to verify |
|---|---|---|
| Exact queue-replacement behavior across concurrent deploys | Requires consecutive live GitHub Actions runs | Push 3 commits in rapid succession and watch the Actions tab |
| Multi-machine blue-green / rolling deploys | The standard lab uses a single machine | Spin up a second lab VPS and repeat the slot experiment across both hosts |
| Fully automated short-lived certificate issuance in CI | Requires a production CA private-key custody setup | Store a dedicated CA key in Actions Secrets or integrate cloud OIDC |
| Continuous WAL archiving with RPO = 1h | Requires an external object-storage bucket | Configure Postgres `archive_command` to ship WAL segments to S3/R2 |

### Simulating CI → SSH deploys on a local VM (closes the loop from Beginner Appendix B)

If you are running the course inside a local VM, you can play the role of the GitHub Actions runner directly from your host machine (the only differences from real GitHub Actions: there is no `needs: check` gating job, and cloud queue/cancel behavior cannot be reproduced locally):

```bash
# pin the host key (this stands in for DEPLOY_KNOWN_HOSTS in the real chain)
ssh-keyscan -t ed25519 <VM_IP> > ~/.ssh/demo_vm_known_hosts
# trigger a deploy with the CI's private key (structurally identical to the workflow's ssh line)
ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/demo_vm_known_hosts \
    -i ~/.ssh/demo_deploy_key "deploy@<VM_IP>" "deploy <40-hex-sha>"
```

---

## Wrapping Up: Cleanup and Cost Checklist

Once you have finished your experiments, clean up the lab environment (and tally up the true cost of the course):

```bash
# server side: freeze switches and timers vanish with the machine — nothing to clean separately
# local side: remove the CI private key you no longer need
rm ~/.ssh/demo_deploy_key ~/.ssh/demo_deploy_key.pub
# GitHub side: repo Settings → Deploy keys — delete the two lab keys;
#              Settings → Secrets — delete DEPLOY_HOST / DEPLOY_SSH_KEY / DEPLOY_KNOWN_HOSTS
# machines: destroy the hourly-billed lab box NOW; snapshot the teaching VPS (optional), then destroy it
```

**Cost summary**: The hourly-billed lab box (1 vCPU, 1GB RAM) typically costs **<$1** for the entire book; the monthly teaching VPS plus a domain name runs around **$5–10**. Before destroying your servers, pull a copy of `audit.log` and your completed `docs/experiments.md` into your repository—together, they are your graduation certificate from this course.

---

*Congratulations on finishing the course! For your next reading list, pick up the Amazon Builders' Library (especially the articles on deployments and rollbacks), The Twelve-Factor App, and Chapter 8 of the Google SRE Book (Release Engineering). Page after page, you will recognize at massive scale the exact principles you just built and tested with your own hands.*
