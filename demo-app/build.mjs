// build.mjs — "构建" = 产出可运行的产物 + 注入版本。
//
// 部署教学点(P1/可复现性):部署的必须是"构建过的那份东西",
// /version 端点读取的 version.json 在这里注入 GIT_SHA。
// 高级册 D1 会讨论:构建应该在服务器上(参考设计)还是 CI 上(产物下发)。
//
// 注:buildTime 会让两次构建的字节不同(不可复现)。高级册第 3 章会
// 用实验演示这个问题,并给出修法(去掉 buildTime 或 SOURCE_DATE_EPOCH)。
import { cpSync, mkdirSync, rmSync, writeFileSync, readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'

const FILES = ['server.js', 'worker.js', 'db.js', 'config.js', 'migrate.js']

// 语法检查:保证"坏构建"(C1 场景)在构建阶段就失败,而不是上线后崩溃
for (const f of FILES) {
  const src = readFileSync(`src/${f}`, 'utf8')
  const r = spawnSync(process.execPath, ['--input-type=module', '--check'], { input: src })
  if (r.status !== 0) {
    console.error(`build: SYNTAX ERROR in src/${f}:`)
    process.stderr.write(r.stderr?.toString() ?? '(no details)\n')
    process.exit(1)
  }
}

rmSync('dist', { recursive: true, force: true })
mkdirSync('dist')
for (const f of FILES) cpSync(`src/${f}`, `dist/${f}`)

const version = {
  gitSha: process.env.GIT_SHA || null,
  buildTime: new Date().toISOString(),
}
writeFileSync('dist/version.json', JSON.stringify(version, null, 2) + '\n')

console.log(`build: dist/ ready (gitSha=${version.gitSha ?? 'null'})`)
