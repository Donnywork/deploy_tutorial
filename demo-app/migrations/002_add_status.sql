-- 002_add_status.sql — 向后兼容(additive)迁移的标准样子(P2 的 expand 阶段):
-- 只加列、给默认值,旧代码完全不受影响;新代码可以开始读它。
-- 高级册第 6 章会演示配套的 contract 阶段(删旧列)为什么要等一轮部署之后才能做。

ALTER TABLE notes ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active';

CREATE INDEX IF NOT EXISTS notes_created_at_idx ON notes (created_at);
