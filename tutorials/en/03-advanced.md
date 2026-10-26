# Advanced: Experiments, Measurements, and Upgrade Decisions

> **What you'll learn**: answer four real architecture questions with experiments — where to build, how to trigger deploys, how to switch traffic, how to manage credentials; turn backups from "should work" into "a drilled record with RPO/RTO numbers"; manufacture deployment incidents on yourself (kill -9, power loss, OOM) and watch the system recover; and leave with an honest decision table for "when is Kubernetes actually worth it".
>
> **Prerequisites**: intermediate book completed (v1 pipeline live), and a willingness to break your own lab server. **Strongly recommended**: spin up a fresh hourly-billed VPS for this book's experiments and destroy it afterwards (total cost usually <$1). Do not run Chapters 2/3/7 on a machine serving real users.
>
> **Principles**: build once, deploy everywhere; rollback safety; drilled backups; contained blast radius; short-lived credentials; reconcilable desired state; simplicity first — including knowing when **not** to adopt a tool.

**Method**: every section is one experiment, always in this format:

```
Hypothesis: we believe X (usually the reference design or an industry "best practice")
Steps:     how to run the experiment (commands)
Observe:   what to watch, how to record
Verdict:   X holds / fails; under what conditions a switch is worth it (upgrade trigger)
```

> The iron rule of this format: **every conclusion needs evidence (commands, logs, exit codes), not assertions.** After each experiment, leave yourself one line of evidence in your notes.

---

## Chapter 1: The Measurement Toolbox

Architecture debates without numbers are just arguing. Four handy tools:

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

> macOS note: `date +%s%3N` is a GNU extension; BSD date prints a literal `N`. To measure from a Mac, `brew install coreutils` and use `gdate` in the script.

### 1.2 Latency and throughput

```bash
# hey (brew install hey, or grab a release)
hey -z 60s -c 10 https://deploy-demo.example.com/health/ready
# watch three numbers: average latency, p99, errors. Run before AND after each comparative experiment
```

### 1.3 RPO / RTO

- **RPO** (how much data loss is tolerable) = backup interval + replication lag. Current scheme: daily dailies + per-deploy premigrates → worst case 24h.
- **RTO** (how much downtime is tolerable) = detection time + recovery time. Chapter 6 measures "rebuild a machine from backup" end to end.

### 1.4 The experiment log template

Five lines per experiment, kept in `docs/experiments.md` in your repo:

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

**Hypothesis**: the intermediate book's "atomic switch + restart" still has an observable downtime window (tens to hundreds of ms).

**Steps**:
1. [local] start `measure-downtime.sh`;
2. [server] trigger a deployment (change an inconsequential string, push);
3. Ctrl-C after it finishes; analyze `/tmp/downtime.tsv`.

**Observe**: a run of `000`s — and between them, gaps in the `200`s. Typical numbers: **200–1500ms** (depending on how long systemd waits for graceful stop and how fast the new process boots). **Record the truth; do not claim zero downtime.** In-flight requests tell their own story: graceful shutdown completes most of them, but connections being established at that instant fail.

**Verdict**: v1's window = stop-old + start-new + time-to-healthy. Killing it means keeping **old and new alive simultaneously** — that's blue-green.

### 2.2 Minimal blue-green: two slots + an Nginx switch

Single-machine blue-green needs no orchestrator: two slots, Nginx remembering "who's on stage", one switch script.

**Layout** (on the lab machine):

```
/srv/demo-app/
├── releases/<sha>/          # unchanged
├── blue  → releases/<shaA>  # slot symlinks
├── green → releases/<shaB>
└── current → blue           # "who is on stage"
```

App config: blue on `PORT=3010`, green on `3020` (via `runtime.env.blue/green`). Nginx:

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

(The full templating — a `demo-app-web@.service` unit template, both `runtime.env` variants, and wiring into `deploy.sh` by replacing its steps 12/13 with this script — is left as the chapter's exercise. Every idea comes from the intermediate book; the only change is "one current" becoming "two slots".)

### 2.3 Measure and conclude

**Steps**: repeat 2.1's measurement with the blue-green path.

**Observe**: **not a single 000**. Nginx's `reload` swaps upstreams smoothly; old connections finish on old workers. Window ≈ **0ms** (honest caveats: the DB migration still happens before the flip; long connections/WebSockets need extra design; during the 30s of dual-running workers, either side may claim a job — and `FOR UPDATE SKIP LOCKED` from the intermediate book happens to make that safe).

**Verdict and upgrade triggers**:

| Option | Downtime | Cost | Worth it when |
|---|---|---|---|
| v1 restart switch | ~0.2–1.5s | low | internal tools, low traffic, users tolerate "refresh during release" |
| single-machine blue-green | ≈0ms | +slot management, 2× process memory | public services, real SLAs, memory fits two copies |
| multi-machine rolling / K8s | ≈0ms | full orchestration | too many machines to herd manually (Chapter 9) |

---

## Chapter 3: Experiment — Where to Build

**Hypothesis**: building on the production machine (a) degrades the live service, (b) breaks deploys without internet, (c) produces non-reproducible artifacts. CI-built artifacts fix all three, at the cost of artifact distribution infrastructure.

### 3.1 Baseline: the cost of building in place

**Steps**:
1. [server] keep resources tight — that 1GB lab machine is perfect.
2. [local] run `hey -z 120s -c 10` while triggering a deployment.
3. Record `hey`'s p99 and error count during the deploy; `free -m` for memory; if OOM struck, `journalctl -k | grep -i oom` for evidence.

**Observe** (typical on 1GB): during `pnpm install` + build, p99 climbs visibly (2–5×); under memory pressure the build process may get OOM-killed → **the deploy fails while the live service keeps serving** (thanks to `.partial` isolation) — record that too; it's a point in v1's favor.

### 3.2 The CI-artifact variant

Add a `package` job to the workflow (the essential changes):

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

On the server, replace deploy.sh steps 6–8 with "download the artifact + verify sha256 + untar" (via `gh run download` or an object-storage URL). **The point: build once, deploy everywhere — what CI tested, packaged, and what runs in production are the same bytes.**

### 3.3 The three comparisons

| # | Experiment | Server-build (v1) | CI-artifact |
|---|---|---|---|
| 1 | load test during deploy (as 3.1) | p99 degrades | **no degradation** (the server only untars) |
| 2 | deploy with internet cut | `git fetch` fails immediately; **but rollback.sh still works** (it never touches the network) | once the artifact has arrived, unpacking needs no network — but the transfer channel itself does. **Common ground: rollback is always offline-capable** |
| 3 | reproducibility | build the same SHA twice, `sha256` **differs** (`dist/version.json` contains `buildTime`!) | same; fix by dropping `buildTime` or pinning `SOURCE_DATE_EPOCH` — afterwards identical checksums |

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
| impact on live | yes (worse on smaller machines) | none |
| network dependency | fetch + package registry | only the transfer channel |
| rollback speed | instant from releases/ | identical (the releases layout is unchanged) |
| infrastructure | zero | artifact storage + download credentials |
| **switch when** | — | machines ≤2GB / multiple servers needing the same artifact / compliance (artifact archival) / flaky package registry |

For a single-machine demo-app: **not switching is also a defensible call** (simplicity first). Having run both experiments, it's your data-backed decision — not folklore.

---

## Chapter 4: Experiment — Push (SSH) or Pull (Poll)

**Hypothesis**: Push-SSH requires an inbound port 22, permanently exposed to scans and brute force; a Pull model (the server polls GitHub) can shrink the inbound surface to zero, at the cost of latency and failure visibility.

### 4.1 First, look at what port 22 sees

```bash
sudo journalctl -u ssh --since today | grep -c "Invalid user"   # today's brute-force attempts
# a lab machine open for days usually shows hundreds to tens of thousands
sudo apt install -y fail2ban && sudo systemctl enable --now fail2ban   # the minimum mitigation
```

### 4.2 The pull prototype (30 core lines)

**The reuse trick**: pull is not a new deploy system — it's a **different caller**. `deploy.sh` changes by zero characters.

`# file: /opt/demo-app/bin/poll.sh` (root-owned; run by a systemd timer every 60s):

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

Once enabled: `sudo ufw delete allow OpenSSH` (or restrict to your IP range) — **inbound surface zero**. That's the entire security payoff of pull.

### 4.3 The comparison

| Dimension | Push-SSH | Pull |
|---|---|---|
| inbound exposure | port 22 (mitigated by forced command + fail2ban) | **zero** (only 80/443) |
| deploy latency | seconds after push | ≤ polling interval (60s) |
| failure visibility | the Actions page goes red | DIY (logs/alerting, Chapter 8) |
| audit | initiated by CI, clear chain | server-initiated, actor=poller |
| external dependency | Actions healthy + server reachable | server can egress to GitHub |

**Upgrade triggers**: ≥2 machines (push-everything-at-once), a "no inbound at all" compliance requirement, or brute-force noise annoying enough to matter → pull. Single machine + wanting instant feedback in the Actions UI → push. **Coexistence is also legitimate** (pull as a reconciliation backstop — Chapter 8).

---

## Chapter 5: Trust and Credentials — Key Lifetimes and Trust Boundaries

### 5.1 The blast radius of static keys → short-lived SSH certificates

**Hypothesis**: the CI private key is long-lived and static; if leaked, the exposure is "trigger a deploy of any main SHA". Short-lived certificates compress the key's validity from "forever" to "minutes".

**Minimal demo** (proof of concept; production can wait):

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

**Observe**: 5 minutes later, the same key is refused (`Permission denied`). The blast radius shrinks from "forever" to "any legitimate SHA within 5 minutes" — provided `force-command` is present too: **validity governs how long, the forced command governs what**. Either alone is insufficient (a short-lived cert without force-command is still a full-shell pass).

**Verdict**: for a single small project, static key + forced command + audit already keeps the radius tiny (simplicity first: running a CA costs more than it saves); **multi-machine / multi-team / compliance** is where certificates (or OIDC-issued dynamic credentials) start paying. Triggers: keys shared into >3 CI repos, or any suspected leak, ever.

### 5.2 TOCTOU — the builder and the runner are different people

**Hypothesis**: releases are built by the deploy user and executed by the app user. Between "build finished" and "service restarted", can the deploy user (or an attacker holding that identity) tamper with the code about to run?

**Steps** (lab machine):
1. Start a deploy and, before its health check passes, simulate tampering: `sudo -u deploy sh -c 'echo "process.exit(99)" >> /srv/demo-app/releases/<sha>/dist/server.js'`
2. Watch the outcome: the health check fails → rollback. The tampering **never reached production**, but note: **this release is now poisoned, and v1 has no mechanism to notice that release contents no longer match the SHA.**
3. The fix: after building, `chown -R root:root` the release and make it read-only (deploy hands off write access the moment the build ends); have the migration wrapper verify ownership before `runuser`. Apply the hardening, rerun 1–2: tampering dies on EPERM.

**Verdict**: the suspicion is **confirmed** (the window exists in v1); the fix = "drop privileges immediately after building". Related residual risk: `pnpm install` postinstall scripts execute as deploy, which opens the malicious-build door — a package could read the deploy key inside repo.git. Minimal mitigation: keep the key read-only and easy to rotate; the real fix is CI-built artifacts (Chapter 3 — the server never runs a package manager at all).

### 5.3 Boundary inputs against the sudoers glob

Use the intermediate book's sudoers as the target range:

```bash
sudo -u deploy sudo /opt/demo-app/bin/migrate-wrapper.sh "abc...40-hex... extra arg"
# inside the script: exactly one sha argument required → the second layer catches it
sudo -u deploy sudo /opt/demo-app/bin/migrate-wrapper.sh "../../../../etc/passwd"
# layer one: sudoers' [0-9a-f]* refuses outright (leading / not in the class — never reaches the script);
# layer two: had the glob been bypassed (e.g. arguments with spaces), the in-script case refuses again
```

**Verdict**: the glob stops wild paths; the in-script validation stops the "glob spans spaces" bypass — defense in depth isn't a slogan, it's two independent checks that each fired. Residual: audit.sh's `*` can still be spammed by deploy — Chapter 8.

---

## Chapter 6: Data, Advanced — expand/contract, Big-Table Locks, Measured RPO/RTO

### 6.1 The correct shape of a destructive migration

**Hypothesis**: a contract operation like "drop the `notes.body` column", deployed in one shot, breaks rollback (the old code still SELECTs the column). A two-phase release keeps every rollback safe.

**The wrong way, live** (lab machine — study the accident before learning the cure):

```bash
# drop the column + deploy → then manually rollback.sh to the old code
# old code SELECTs body → ERROR: column "body" of relation "notes" does not exist → 500s
# you have just manufactured the textbook "rollback-unsafe" case
```

**The right way — split 003 into two releases**:

```
Release 1 (expand): add the new column / dual-write / new code tolerates old shape
  migrations/003_expand.sql:  ALTER TABLE notes ADD COLUMN content text;
                              UPDATE notes SET content = body;
  server.js reads/writes both body (old) and content (new) → deploy, observe for a week
Release 2 (contract): only after confirming you'll never roll back further
  migrations/004_contract.sql: ALTER TABLE notes DROP COLUMN body;
  server.js touches only content → deploy
```

**The rollback-safety matrix** (do it yourself; fill in what you observe):

| Combination | Old schema + new code | New schema (expand) + old code | New schema (contract) + old code |
|---|---|---|---|
| Result | ✅ compatible (the point of expand) | ✅ compatible (the point of dual-write) | ❌ crashes (hence: confirm no further rollback before contracting) |

### 6.2 Big-table migration locks

**Steps**:
1. Create a 500k-row table: `INSERT INTO notes(title) SELECT 'row'||g FROM generate_series(1,500000) g;`
2. From another connection, continuously UPDATE random rows (simulating live writes).
3. Compare two ways of creating an index:

```sql
-- A: plain index (locks writes)
BEGIN; CREATE INDEX idx_slow ON notes(created_at); -- watch the writer: blocked
-- B: concurrent index (does not block writes)
CREATE INDEX CONCURRENTLY idx_fast ON notes(created_at); -- writes continue
-- companion: SET lock_timeout='3s' makes lock waits fail fast instead of queueing forever
```

**Observe**: with A, the writer queues (`SELECT * FROM pg_stat_activity WHERE wait_event_type='Lock'` shows it); with B, writes flow (trade-offs: slower build, not allowed inside a transaction).

**Verdict**: the production migration trio — `lock_timeout`, `CONCURRENTLY`, off-peak execution; and any time you're unsure "does this migration lock?", **dry-run it on a replica first** (next item).

### 6.3 Migration dry-runs

```bash
# 1. restore a scratch database from the newest backup (Intermediate Ch.6's procedure)
# 2. dry-run then real-run against the scratch DB
DATABASE_URL=postgres://drill:drill@127.0.0.1:55432/drill node dist/migrate.js --dry-run
DATABASE_URL=postgres://drill:drill@127.0.0.1:55432/drill node dist/migrate.js
# failure? → the migration is broken, and the production database was never touched
```

Wiring "rehearse on a restored copy before every migration" into deploy.sh (enabled when `MIGRATE_DRYRUN=true`) is standard practice at many larger teams.

### 6.4 The measured RPO/RTO table (the drilled-backups deliverable)

Complete this table on your lab machine (the numbers are yours; the format is universal):

| Item | Value | How measured |
|---|---|---|
| Backup size (DB/storage) | ___ KB | `du -h` |
| Backup duration | ___ s | `time backup.sh manual` |
| Restore duration (empty DB) | ___ s | `time pg_restore` (Intermediate Ch.6) |
| Full-machine rebuild RTO (zero to live) | ___ min | the disaster drill in Appendix B, timed |
| RPO (daily scheme) | worst case 24h | by definition |
| RPO (with hourly archive/WAL) | worst case 1h | Chapter 9's upgrade trigger |
| Off-site copy lag | ___ | the rsync cron's interval |

**GitLab's 2017 lesson** wasn't "no backups" — it was **never-verified restores**. The moment this table is filled in, your backups can be said to exist.

---

## Chapter 7: The Crash-Consistency Lab

In this chapter you are a QA engineer with malicious intent. Every experiment's acceptance bar is the same sentence: **recover automatically, or land in an explicitly recoverable state; never leave debris, never corrupt production.**

### 7.1 kill -9 mid-deploy

For each of five moments: during build / after backup / mid-migration / post-migration pre-switch / during health check.

```bash
# [server] while a deploy runs, find deploy.sh's PID
ps aux | grep '[d]eploy.sh'
sudo kill -9 <pid>
```

**Expected-outcome table** (verify cell by cell):

| Moment | Residue | Re-run outcome |
|---|---|---|
| during build | `.partial/` | ✅ auto-cleaned and rebuilt |
| after backup | one extra backup (harmless) | ✅ continues |
| mid-migration | the failed migration fully rolled back (transactional) | ✅ |
| post-migration pre-switch | DB new, code old (safe during expand) | ✅ |
| during health check | current flipped but unconfirmed | ✅ idempotency/health checks converge |

### 7.2 Reboot mid-everything

Deploy running, then `sudo reboot` (mid-migration is the most exciting moment). After boot: Postgres back, units active, the flock lock (in /run, tmpfs) evaporated, `/srv/demo-app/current` pointing at a consistent state. Debris anywhere? Trigger one deploy and watch it converge.

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

**Hypothesis**: you changed deploy.sh in the repo but forgot to reinstall; the server keeps running the old script, and **nothing notices**.

```bash
# verify: add a comment line in the repo, push, don't reinstall → behavior unchanged (old script) → drift confirmed
# fix: reconcile in one pipeline — hash the INSTALLED files in /opt, then verify the REPO copies by name
# (note: the manifest must be checked against the repo directory; verifying /opt against itself always passes)
cd ~/demo-app-bootstrap/deploy && \
sudo sh -c 'cd /opt/demo-app/bin && sha256sum app.conf deploy-entry deploy.sh healthcheck.sh \
  check-config.sh migrate-wrapper.sh backup.sh rollback.sh audit.sh' \
  | sha256sum -c - || echo "DRIFT: installed scripts differ from repo — run install.sh"
```

**Verdict**: drift detection is desired-state reconciliation in miniature ("the scripts that should be installed" vs "the scripts that are installed" must be comparable). When upgrading install.sh, update the fingerprint file with it (it's part of what gets reconciled).

---

## Chapter 8: Observability and Reconciliation

### 8.1 Desired-state reconciliation

`# file: /opt/demo-app/bin/reconcile.sh` (cron, or piggybacked on poll):

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

Minimum viable: a webhook (or even a local file collector you actually look at):

```bash
# deploy.sh's die() already appends to audit.log; add:
curl -fsS -m 3 "$NOTIFY_WEBHOOK" -d "deploy failed: sha=$SHA step=$step" >/dev/null 2>&1 || true
# NOTIFY_WEBHOOK → Slack/Lark/Telegram incoming webhook, or a local file service
```

> Note the `|| true`: a failed notification must never fail the deployment itself (notifications are a side channel, not the path).

### 8.3 Change control for the deploy system itself

Deploy scripts, sudoers, and workflows are high-risk files that can change production behavior:

1. **CODEOWNERS** (`.github/CODEOWNERS` in the repo):

```
/deploy/            @your-team/ops
.github/workflows/  @your-team/ops
```

2. **A deploy-system self-check CI** (added to ci.yml's check job):

```yaml
- run: sudo apt-get install -y shellcheck && shellcheck deploy/*.sh
- run: bash -n deploy/deploy-entry
- name: sudoers syntax check
  run: sudo visudo -cf deploy/demo-app.sudoers
```

3. Tamper-proof audit (5.3's residual): audit already goes to syslog via `logger` — collect it on **another** machine, one the deploy user cannot touch.

---

## Chapter 9: The Upgrade Decision Records (ADRs)

One-line verdicts plus quantified triggers per decision. **If the trigger isn't met, don't adopt** (simplicity first, in practice).

| Decision | Trigger (any one) | Until then |
|---|---|---|
| **CI-built artifacts** | machines ≤2GB / ≥2 servers / compliance archival | server-side build (v1 as-is) |
| **Pull-based deploys** | ≥2 machines / "no inbound SSH" compliance / brute-force noise out of control | Push-SSH + fail2ban + forced command |
| **Blue-green** | a public SLA / users complained about the window | atomic switch + off-peak deploys |
| **Short-lived certs / OIDC** | keys for >3 consumers / any suspected leak / multi-team CI | static key + audit + a fast-rotation plan |
| **Daily → hourly backups / WAL archiving** | a 24h RPO is unacceptable (transactions/user data) | daily + pre-deploy |
| **Off-site backups to object storage** (rclone cron → S3/R2) | **immediately** (cost ≈ free; benefit = the fire scenario) | rsync to a laptop (the minimum) |
| **Ansible** | you've copy-pasted the same manual ops onto >5 machines | this course's install.sh |
| **Terraform** | >3 kinds of cloud resources, changing often | manual creation, well documented |
| **Docker images + registry** | the natural evolution of CI artifacts + multi-machine distribution | tarball artifacts |
| **Kubernetes** | >10 machines / >15 services / a dedicated platform person / genuinely frequent elastic scaling | single-machine systemd + this pipeline |

> Read the K8s row's fine print: the problems it solves (multi-machine orchestration, self-healing, elasticity) **do not exist** for your 3 machines and 2 services, while the problems it introduces (operating the cluster itself, credentials, the network model) start on day one. Let the pain arrive first; the tool second.

---

## Chapter 10: The Scenario Matrix Workbook

The full scenario matrix. ✅=done in the beginner/intermediate books; 🧪=exercise in this chapter (hints included); ⭐=layer-2 items needing real public infrastructure (with the method documented).

### A: Permissions & Trust

| Scenario | Status / hint |
|---|---|
| forced-command abuse matrix | ✅ intermediate 3.5 |
| deploy escalation (edit keys/scripts, read env, sudo off-whitelist) | ✅ intermediate 3.5/4; add: try `sudo -u deploy vi /opt/demo-app/bin/deploy.sh` |
| malicious build (postinstall privesc / secret exfil) | 🧪 add `"postinstall": "cat /home/deploy/.ssh/id_ed25519"` to package.json → push → check whether the build log leaks the key (it will! → residual risk; fix = CI builds or `pnpm install --ignore-scripts`) |
| TOCTOU + glob boundaries | ✅ advanced 5.2/5.3 |
| host-key mismatch must fail the deploy | 🧪 change one character in the GitHub Secret's host key → deploy instantly dies with `REMOTE HOST IDENTIFICATION HAS CHANGED` |
| no secrets in logs | 🧪 `grep -r PASSWORD /var/log/demo-app/` must come up empty (including failed builds) |
| the sshd lockout drill | Appendix B |

### B: Provenance, Concurrency, Crash Consistency

| Scenario | Status |
|---|---|
| force-pushed SHA refused | ✅ intermediate 3.5 (the all-zeros SHA) |
| skip-older / idempotency | ✅ intermediate 9.8 |
| flock + workflow concurrency, divided labor | ✅ intermediate 7.1/9.8 |
| three rapid pushes, queue behavior | ⭐ real Actions observation: older queued runs get replaced (a CI-status-vs-reality quirk); runner timeout while the server continues (✅ 9.8 already verified) |
| disconnect mid-deploy, server completes | ✅ intermediate 9.8 |
| kill -9 at five moments | ✅ advanced 7.1 |
| full reboot mid-deploy | ✅ advanced 7.2 |

### C: Build & Toolchain

Bad builds and toolchain mismatches ✅ (intermediate 9); offline deploy & rollback ✅ (advanced 3.3); build-time load/OOM ✅ (advanced 3.1); disk pressure ✅ (advanced 7.3); malicious postinstall scripts 🧪 (same drill as the malicious-build item in Permissions & Trust).

### D: Data & Migrations

Backup + restore drill ✅; backup scope & retention ✅ (intermediate 6); failed migration = no switch ✅ (intermediate 9.4); the rollback-safety matrix ✅ (advanced 6.1); big-table locks ✅ (advanced 6.2); concurrent migrators ✅ (intermediate 7.4); migration dry-runs ✅ (advanced 6.3).

### E: Switching, Health, Rollback

Downtime window quantified ✅ (advanced 2.1); false-positive health ✅ (intermediate 9.6); partial unit failure → 🧪 `systemctl stop demo-app-worker` then run healthcheck.sh → expect `unit:demo-app-worker=inactive`; a version that migrates fine but won't boot ✅ (intermediate 9.5); rollback target also unhealthy → 🧪 break both versions (e.g. make the old release depend on a missing runtime.env variable?), confirm the system reports "human needed" rather than success; missing config caught before the switch ✅ (intermediate 9.7); timed rollback ✅ (the runbook's number); deploy freeze ✅ (advanced 7.4).

### F: Bootstrap, Operations, Portability

First-deploy timing from an empty server ✅ (intermediate 2.3 — record your minutes); script drift ✅ (advanced 7.5); reboot recovery ✅ (advanced 7.2); audit/notify/reconcile ✅ (advanced 8); retention policy 🧪 deploy 7 times → `ls releases` shows 5, and the previous version was never deleted; CODEOWNERS + self-check CI ✅ (advanced 8.3).

### The hypothesis verdicts

| Hypothesis | Verdict | Evidence | Fix |
|---|---|---|---|
| TOCTOU (the builder and the runner are different people) | **confirmed** | advanced 5.2 | post-build privilege drop to root read-only / CI builds |
| backup scope & retention | **confirmed** | intermediate 6 | DB+storage; count+time retention |
| false-positive health | **confirmed** | intermediate 9.6 | assert SHA + heartbeat + soak |
| restart window | **confirmed** | advanced 2.1 | blue-green (2.2) |
| concurrency/timeout behavior | **partially confirmed** | ⭐ the three-rapid-pushes drill (above) / intermediate 9.8 | setsid detachment + honest reporting of state divergence |
| missing config found too late | **confirmed → fixed** | intermediate 9.7 | check-config preflight |
| build-on-prod costs | **confirmed** | advanced 3.1/3.3 | the build-location decision table (Chapter 9) |
| rollback impossible via redeploy | **confirmed → fixed** | intermediate 7.2 | rollback.sh |
| missing logs/audit/switch | **confirmed → fixed** | intermediate 7.6/10 | audit.log, log rotation, freeze |
| SSH exposure | **confirmed** | advanced 4.1 | fail2ban / short-lived certificates / pull-based deploys |
| script drift undetected | **confirmed → fixed** | advanced 7.5 | fingerprint reconciliation |

---

## Chapter 11: The Portability Proof — a Second Stack (Go)

> Goal: prove the template is **actually** portable, not merely claimed portable (one of this course's success criteria). 30 minutes.

**[local]** `# file: ~/Projects/demo-go/main.go` (40 lines, zero dependencies):

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

The adaptation diff (this is everything):

| File | Change | Lines |
|---|---|---|
| `deploy/app.conf` | `BUILD_CMD="go build -ldflags \"-X main.version=$GIT_SHA\" -o dist/app ."`; `MIGRATE_CMD="true"`; units/health URLs | ~5 |
| `deploy/demo-go-web.service` | `ExecStart=/srv/demo-app/current/dist/app` (the worker unit is demo-app-specific and simply goes away) | 1 |
| `deploy/demo-app.sudoers` | unit names | ~6 |
| `deploy/check-config.sh` | `node ... --check-config` → `./dist/app --check-config` | 1 |
| `deploy/migrate-wrapper.sh` | same (or just `exit 0`) | 1 |
| systemd units | 2 → 1 | — |

**Total: ~15 changed lines across 6 files.** `install.sh`, `deploy-entry`, `deploy.sh`, `healthcheck.sh` (one heartbeat line commented out — no worker to watch), `rollback.sh`, `backup.sh`, and the workflow: unchanged. Copy this table into `docs/experiments.md` — that is what "portable" looks like as evidence.

---

## Appendix A: The One-Page Runbook (Final)

Extends the intermediate runbook:

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

**On your lab machine**, deliberately break sshd and practice recovery (once drilled, panic never):

```bash
sudo cp /etc/ssh/sshd_config /tmp/sshd_config.bak
echo "Port 2222" | sudo tee -a /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart ssh     # syntactically "valid" — but 2222 isn't in ufw
# new terminal: ssh → timeout (locked out!)
# recover via the provider's VNC console:
#   sudo cp /tmp/sshd_config.bak /etc/ssh/sshd_config && sudo sshd -t && sudo systemctl restart ssh
```

**The standing rule**: for any sshd/sudoers/ufw change, follow the five steps — back up first → `sshd -t` / `visudo -cf` → **reload** (not restart) → keep the existing session open → verify with a **new** session. Those five steps are the whole don't-lock-yourself-out playbook.

## Appendix C: The "Layer 2 Unverified" List

This course verified almost everything on a real VPS + real Actions. These items depend on specific conditions; methods documented:

| Item | Why unverified | How to verify |
|---|---|---|
| The exact queue-replacement behavior of concurrent deploys | needs consecutive real Actions runs | push 3 commits rapidly; watch the Actions list |
| multi-machine blue-green / rolling | single machine | repeat the slot experiment on machine #2 |
| fully automated short-lived-cert issuance | needs a CA-key custody design | store the CA in Actions secrets, or use OIDC |
| WAL archiving with RPO=1h | needs archive storage | postgres `archive_command` + object storage |

### Simulating CI → SSH deploys on a local VM (closes the loop from Beginner Appendix B)

Play the GitHub Actions runner from your host machine (differences from the real thing: no CI conclusion gate (`needs: check`), and the queueing/cancel behavior can't be reproduced):

```bash
# pin the host key (this stands in for DEPLOY_KNOWN_HOSTS in the real chain)
ssh-keyscan -t ed25519 <VM_IP> > ~/.ssh/demo_vm_known_hosts
# trigger a deploy with the CI's private key (structurally identical to the workflow's ssh line)
ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/demo_vm_known_hosts \
    -i ~/.ssh/demo_deploy_key "deploy@<VM_IP>" "deploy <40-hex-sha>"
```

---

## Wrapping Up: Cleanup and Cost Checklist

Finish the experiments by cleaning the battlefield (and tallying the true cost of the course):

```bash
# server side: freeze switches and timers vanish with the machine — nothing to clean separately
# local side: remove the CI private key you no longer need
rm ~/.ssh/demo_deploy_key ~/.ssh/demo_deploy_key.pub
# GitHub side: repo Settings → Deploy keys — delete the two lab keys;
#              Settings → Secrets — delete DEPLOY_HOST / DEPLOY_SSH_KEY / DEPLOY_KNOWN_HOSTS
# machines: destroy the hourly-billed lab box NOW; snapshot the teaching VPS (optional), then destroy it
```

Cost reference: the lab box (1C1G, hourly) usually totals **<$1**; the teaching VPS (monthly) + domain ≈ **$5–10**. Pull a copy of `audit.log` and `docs/experiments.md` into the repo — that's your graduation certificate.

---

*Congratulations on finishing the course. Further reading: the Amazon Builders' Library (deployment & rollback chapters), the 12-Factor App, and Google SRE Book Chapter 8 (Release Engineering). They will keep confirming, at scale, what you touched with your own hands in these three books.*
