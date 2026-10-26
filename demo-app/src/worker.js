// worker.js — demo-app 的 worker 单元。
//
// 部署教学点:
// - web 和 worker 是**两个 systemd 单元**:健康检查必须覆盖全部单元,
//   否则"web 正常但 worker 崩溃循环"会被漏检。
// - 心跳表 worker_status:健康检查据此判断 worker 真的在干活。
// - SIGTERM 优雅退出:systemd restart 时处理完手头任务再走。
// - 至少一次 + 幂等:任务可能被重复执行(比如 worker 中途被杀后重新入队),
//   处理逻辑必须幂等(这里通过 UPDATE ... WHERE status='running' 守卫)。
import { query, pool } from './db.js'
import { checkConfig } from './config.js'

const { ok: configOk, missing } = checkConfig()
if (!configOk) {
  console.error(`FATAL: missing required env: ${missing.join(', ')}`)
  process.exit(3)
}

const POLL_MS = Number(process.env.WORKER_POLL_MS || 1000)
const STALE_AFTER_S = Number(process.env.WORKER_STALE_AFTER_S || 60)

let stopping = false
let heartbeatTimer = null

async function heartbeat(state) {
  await query(
    `INSERT INTO worker_status (id, last_beat, state) VALUES (1, now(), $1)
     ON CONFLICT (id) DO UPDATE SET last_beat = now(), state = $1`,
    [state]
  )
}

/** 把"卡死的 running 任务"重新入队(worker 被 kill -9 后的恢复路径) */
async function requeueStale() {
  const r = await query(
    `UPDATE jobs SET status = 'pending', attempts = attempts + 1
     WHERE status = 'running' AND started_at < now() - make_interval(secs => $1)
     RETURNING id`,
    [STALE_AFTER_S]
  )
  if (r.rowCount > 0) console.log(`worker: requeued ${r.rowCount} stale job(s)`)
}

/** 认领一个 pending 任务(FOR UPDATE SKIP LOCKED:多 worker 安全) */
async function claimJob() {
  const r = await query(
    `UPDATE jobs SET status = 'running', started_at = now()
     WHERE id = (
       SELECT id FROM jobs WHERE status = 'pending'
       ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED
     )
     RETURNING id, kind, payload`
  )
  return r.rows[0] || null
}

/** 任务处理:必须幂等。shout = 把笔记标题"喊"成大写并统计长度。 */
async function processJob(job) {
  if (job.kind !== 'shout') throw new Error(`unknown kind: ${job.kind}`)
  const result = { shouted: String(job.payload.title || '').toUpperCase(), length: String(job.payload.title || '').length }
  // WHERE status='running' 守卫:同一任务不会被写两次结果(幂等)
  await query(
    `UPDATE jobs SET status = 'done', result = $1, finished_at = now()
     WHERE id = $2 AND status = 'running'`,
    [JSON.stringify(result), job.id]
  )
  console.log(`worker: job ${job.id} done -> ${result.shouted}`)
}

async function loop() {
  await heartbeat('running')
  await requeueStale()
  const job = await claimJob()
  if (job) {
    try {
      await processJob(job)
    } catch (err) {
      console.error(`worker: job ${job.id} failed:`, err.message)
      await query(
        `UPDATE jobs SET status = 'error', error = $1, finished_at = now() WHERE id = $2`,
        [String(err.message || err), job.id]
      )
    }
  }
}

async function main() {
  console.log('worker: started')
  heartbeatTimer = setInterval(() => {
    if (!stopping) heartbeat('running').catch((e) => infraFail(e))
  }, 5000)
  heartbeatTimer.unref()
  while (!stopping) {
    await loop()
    await new Promise((r) => setTimeout(r, POLL_MS))
  }
  await heartbeat('stopped').catch((e) => console.error('worker: final heartbeat failed:', e.message))
  await pool.end().catch(() => {})
  console.log('worker: graceful exit')
  process.exit(0)
}

function infraFail(err) {
  // 基础设施错误(连不上库等):干脆地退出,让 systemd 拉起;
  // 崩溃循环会被健康检查的心跳超时抓出来(而不是被自动重启掩盖)。
  console.error('worker: infra failure:', err.message)
  process.exit(1)
}

process.on('SIGTERM', () => { console.log('worker: SIGTERM, finishing current job...'); stopping = true })
process.on('SIGINT', () => { stopping = true })

main().catch((err) => {
  console.error('worker: fatal:', err)
  process.exit(1)
})
