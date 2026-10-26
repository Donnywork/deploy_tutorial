// smoke.test.js — 不依赖数据库的最小测试,CI 里跑(node --test)。
// 教学点:CI 至少要验证"构建产物可加载 + 配置预检逻辑正确"。
import test from 'node:test'
import assert from 'node:assert/strict'
import { checkConfig } from '../src/config.js'

test('checkConfig passes when all required env are present', () => {
  const r = checkConfig({ DATABASE_URL: 'x', APP_ENV: 'ci', STORAGE_DIR: '/tmp' })
  assert.equal(r.ok, true)
  assert.deepEqual(r.missing, [])
})

test('checkConfig reports missing variables', () => {
  const r = checkConfig({ APP_ENV: 'ci' })
  assert.equal(r.ok, false)
  assert.ok(r.missing.includes('DATABASE_URL'))
  assert.ok(r.missing.includes('STORAGE_DIR'))
})
