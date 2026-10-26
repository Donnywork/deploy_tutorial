// db.js — 一个共享的 pg 连接池。
// 部署教学点:连接串来自环境变量 DATABASE_URL,绝不写死在代码里(12-factor III)。
import pg from 'pg'

export const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: 5,
})

/** 便捷查询封装 */
export const query = (text, params) => pool.query(text, params)
