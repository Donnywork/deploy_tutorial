// migrate.js — 极简 SQL 迁移器(教学用,生产可换 knex/drizzle/flyway,理念相同)。
//
// 部署教学点:
// - advisory lock:两个迁移器并发跑时,第二个会在锁上排队(P2/场景 D6)。
// - schema_migrations 表记录已应用的迁移;跳过已应用的(幂等)。
// - "数据库里有、代码里没有"的迁移会告警:说明代码回滚到了更旧版本(P2 回滚安全信号)。
// - 迁移失败:当前文件整体 ROLLBACK,退出码非 0;部署脚本据此**不切换代码**(场景 D3)。
// - --dry-run 是真正的只读预检:不取锁、不建表、不写库(高级册场景 D7:副本库预演)。
import { readdirSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import pg from 'pg'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
// dist/migrate.js 和 src/migrate.js 的上一级都是仓库根 → migrations/ 固定在根目录
const MIGRATIONS_DIR = path.join(__dirname, '..', 'migrations')
const ADVISORY_LOCK_KEY = 918273645 // 任意固定整数,全项目唯一即可
const DRY_RUN = process.argv.includes('--dry-run')

if (!process.env.DATABASE_URL) {
  console.error('migrate: FATAL — DATABASE_URL is not set')
  process.exit(3)
}

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL })
const client = await pool.connect()

try {
  let applied = new Set()

  if (DRY_RUN) {
    // 只读:表不存在(全新副本库)就当作"一个都没应用"
    try {
      applied = new Set((await client.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name))
    } catch {
      applied = new Set()
    }
  } else {
    console.log(`migrate: acquiring advisory lock ${ADVISORY_LOCK_KEY} ...`)
    await client.query('SELECT pg_advisory_lock($1)', [ADVISORY_LOCK_KEY])

    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        name text PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )
    `)
    applied = new Set((await client.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name))
  }

  const files = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()

  // 代码比数据库旧?(数据库里有代码里没有的迁移)
  const dbAhead = [...applied].filter((f) => !files.includes(f))
  if (dbAhead.length > 0) {
    console.warn(`migrate: WARNING — DB has migrations not present in code: ${dbAhead.join(', ')} (did you roll back code?)`)
  }

  let ran = 0
  for (const file of files) {
    if (applied.has(file)) continue
    if (DRY_RUN) {
      console.log(`migrate: [dry-run] would apply ${file}`)
      ran++
      continue
    }
    const sql = readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8')
    console.log(`migrate: applying ${file}`)
    await client.query('BEGIN')
    try {
      await client.query(sql)
      await client.query('INSERT INTO schema_migrations (name) VALUES ($1)', [file])
      await client.query('COMMIT')
      ran++
    } catch (err) {
      await client.query('ROLLBACK')
      // 用 throw 而不是 process.exit:让下面的 catch/finally 走完(释放锁、关连接)
      throw new Error(`FAILED at ${file}: ${err.message} (this file was rolled back; nothing was switched on the server side)`)
    }
  }
  console.log(ran === 0 ? 'migrate: up to date, nothing to apply' : `migrate: applied ${ran} file(s), done`)
} catch (err) {
  console.error(`migrate: ${err.message}`)
  process.exitCode = 1
} finally {
  if (!DRY_RUN) {
    await client.query('SELECT pg_advisory_unlock($1)', [ADVISORY_LOCK_KEY]).catch(() => {})
  }
  client.release()
  await pool.end()
}
