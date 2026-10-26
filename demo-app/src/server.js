// server.js — demo-app 的 web 单元。
//
// 部署教学点:
// - /health/live  vs /health/ready 的分层:进程活着 ≠ 依赖可用。
// - /version 返回构建时注入的 SHA:部署后健康检查要**断言**新版本真的在线,
//   而不是"端口通了就行"。
// - 只监听 127.0.0.1:由 Nginx 反代对外,应用端口永远不暴露公网。
// - SIGTERM 优雅退出:systemd restart 时先停止接新请求、处理完在途请求再退出。
import express from 'express'
import { writeFile, readdir, mkdir } from 'node:fs/promises'
import path from 'node:path'
import { query, pool } from './db.js'
import { checkConfig, getVersion } from './config.js'

const { ok: configOk, missing } = checkConfig()
if (!configOk) {
  console.error(`FATAL: missing required env: ${missing.join(', ')} (hint: run with --check-config during deploy)`)
  process.exit(3)
}

const PORT = Number(process.env.PORT || 3000)
const STORAGE_DIR = process.env.STORAGE_DIR
const VERSION = getVersion()
const app = express()
app.use(express.json({ limit: '256kb' }))

// Express 4 不捕获 async handler 的 rejected promise —— 不包装的话,
// 任何一个路由里的 await 抛错(DB 抖动、坏输入)都会让整个进程崩溃
// (Node 默认 unhandled-rejection=throw),与 /health/ready 的降级理念相悖。
const wrap = (fn) => (req, res, next) => fn(req, res, next).catch(next)

app.get('/', (_req, res) => {
  res.type('html').send(
    `<h1>demo-app</h1><p>version: <code>${VERSION}</code></p>` +
      `<ul><li><a href="/health/ready">/health/ready</a></li><li><a href="/version">/version</a></li>` +
      `<li><a href="/api/notes">/api/notes</a></li></ul>`
  )
})

app.get('/version', (_req, res) => res.json({ gitSha: VERSION }))

app.get('/health/live', (_req, res) => res.json({ ok: true }))

// 真实读写一次数据库:ready 不只是"进程在",而是"依赖可用且可写"。
app.get('/health/ready', async (_req, res) => {
  try {
    const ping = await query('INSERT INTO healthcheck_pings DEFAULT VALUES RETURNING id')
    const n = await query('SELECT count(*)::int AS n FROM notes')
    res.json({ ok: true, db: true, lastPingId: ping.rows[0].id, notes: n.rows[0].n })
  } catch (err) {
    res.status(503).json({ ok: false, db: false, error: String(err.message || err) })
  }
})

app.get('/api/notes', wrap(async (_req, res) => {
  const r = await query('SELECT id, title, created_at FROM notes ORDER BY id DESC LIMIT 50')
  res.json(r.rows)
}))

app.post('/api/notes', wrap(async (req, res) => {
  const title = typeof req.body?.title === 'string' ? req.body.title.trim() : ''
  if (!title) return res.status(400).json({ error: 'title is required' })
  // note 与 job 在同一事务里:job 插入失败时笔记一起回滚,客户端重试不会产生重复笔记
  const client = await pool.connect()
  try {
    await client.query('BEGIN')
    const note = await client.query(
      'INSERT INTO notes (title, body) VALUES ($1, $2) RETURNING id, title, created_at',
      [title, typeof req.body?.body === 'string' ? req.body.body : null]
    )
    // 入队一个任务:worker 会异步处理(演示 web 与 worker 的协作)
    const job = await client.query(
      `INSERT INTO jobs (kind, payload)
       VALUES ('shout', jsonb_build_object('noteId', $1::bigint, 'title', $2::text))
       RETURNING id`,
      [note.rows[0].id, title]
    )
    await client.query('COMMIT')
    res.status(201).json({ note: note.rows[0], jobId: job.rows[0].id })
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {})
    throw err
  } finally {
    client.release()
  }
}))

app.get('/api/jobs/:id', wrap(async (req, res) => {
  const id = Number(req.params.id)
  if (!Number.isInteger(id) || id < 1) return res.status(400).json({ error: 'id must be a positive integer' })
  const r = await query('SELECT id, kind, status, attempts, result, error FROM jobs WHERE id = $1', [id])
  if (r.rows.length === 0) return res.status(404).json({ error: 'not found' })
  res.json(r.rows[0])
}))

// 文件存储:验证"备份范围必须包含文件存储,而不只是数据库"
const SAFE_NAME = /^[A-Za-z0-9._-]+$/
app.post('/api/files', wrap(async (req, res) => {
  const name = typeof req.body?.name === 'string' ? req.body.name : ''
  const content = typeof req.body?.content === 'string' ? req.body.content : ''
  if (!SAFE_NAME.test(name) || name === '.' || name === '..') {
    return res.status(400).json({ error: 'name must match [A-Za-z0-9._-] and not be . or ..' })
  }
  await mkdir(STORAGE_DIR, { recursive: true })
  await writeFile(path.join(STORAGE_DIR, name), content, 'utf8')
  res.status(201).json({ stored: name, bytes: content.length })
}))

app.get('/api/files', wrap(async (_req, res) => {
  try {
    const files = await readdir(STORAGE_DIR)
    res.json({ files })
  } catch {
    res.json({ files: [] })
  }
}))

// 统一错误出口:任何未处理的路由错误 → 500 JSON,进程不死(与 /health/ready 的降级一致)
app.use((err, _req, res, _next) => {
  console.error('web:', err.message)
  res.status(500).json({ error: 'internal error' })
})

const server = app.listen(PORT, '127.0.0.1', () => {
  console.log(`demo-app web listening on 127.0.0.1:${PORT} (version ${VERSION})`)
})

// 优雅退出:stop accepting → finish in-flight → close pool → exit 0
function shutdown(signal) {
  console.log(`web: received ${signal}, draining...`)
  server.close(async () => {
    await pool.end().catch(() => {})
    console.log('web: drained, bye')
    process.exit(0)
  })
  // 兜底:10s 内没排干就强制退出(早于 systemd 的 TimeoutStopSec=15 触发)
  setTimeout(() => process.exit(0), 10_000).unref()
}
process.on('SIGTERM', () => shutdown('SIGTERM'))
process.on('SIGINT', () => shutdown('SIGINT'))
