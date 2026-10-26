// config.js — 配置的单一事实来源 + `--check-config` 预检入口。
//
// 部署教学点(H6/P3):"新版本需要的配置缺失"必须在**切换前**被发现,
// 而不是切换后进程起不来才靠回滚兜底。部署脚本会在切换前以 service
// 用户身份运行 `node dist/config.js --check-config`,缺变量就拒绝部署。
import { readFileSync, realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

/** 部署必须存在的环境变量(缺一个就拒绝切换) */
export const REQUIRED_ENV = ['DATABASE_URL', 'APP_ENV', 'STORAGE_DIR']

/**
 * 校验环境配置。
 * @returns {{ ok: boolean, missing: string[] }}
 */
export function checkConfig(env = process.env) {
  const missing = REQUIRED_ENV.filter((k) => !env[k])
  return { ok: missing.length === 0, missing }
}

/** 构建时注入的版本(dist/version.json),dev 模式下返回 "dev"。 */
export function getVersion() {
  try {
    const v = JSON.parse(readFileSync(path.join(__dirname, 'version.json'), 'utf8'))
    return v.gitSha || 'dev'
  } catch {
    return 'dev'
  }
}

// ---- CLI: node config.js --check-config ----
// 用 realpath 比较:经 current 软链调用(如 node /srv/demo-app/current/dist/config.js)
// 时 endsWith 会静默失配 —— 而失配的后果是"预检假装通过(exit 0)",不可接受。
const isDirectRun = (() => {
  try {
    return Boolean(process.argv[1]) &&
      realpathSync(path.resolve(process.argv[1])) === fileURLToPath(import.meta.url)
  } catch {
    return false
  }
})()
if (isDirectRun && process.argv.includes('--check-config')) {
  const { ok, missing } = checkConfig()
  if (ok) {
    console.log('check-config: OK')
    process.exit(0)
  }
  console.error(`check-config: FAIL — missing required env: ${missing.join(', ')}`)
  process.exit(3)
}
