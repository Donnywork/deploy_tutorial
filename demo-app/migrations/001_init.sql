-- 001_init.sql — 初始结构(初级册就会用到)

CREATE TABLE IF NOT EXISTS notes (
  id         bigserial PRIMARY KEY,
  title      text        NOT NULL,
  body       text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS jobs (
  id          bigserial PRIMARY KEY,
  kind        text        NOT NULL,
  payload     jsonb       NOT NULL DEFAULT '{}',
  status      text        NOT NULL DEFAULT 'pending', -- pending|running|done|error
  attempts    int         NOT NULL DEFAULT 0,
  result      jsonb,
  error       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  started_at  timestamptz,
  finished_at timestamptz
);

CREATE TABLE IF NOT EXISTS worker_status (
  id        int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  last_beat timestamptz NOT NULL DEFAULT now(),
  state     text        NOT NULL DEFAULT 'starting'
);
INSERT INTO worker_status (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS healthcheck_pings (
  id bigserial PRIMARY KEY,
  at timestamptz NOT NULL DEFAULT now()
);
