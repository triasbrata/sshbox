-- jeansh-telemetry's D1 database. Run once, with:
--   wrangler d1 execute jeansh-telemetry --remote --file schema.sql

-- One row per install per day. The primary key is what makes a second ping
-- from the same install on the same day cost nothing: INSERT OR IGNORE.
-- Nothing in here says who anybody is: install is a random UUID the app made
-- for itself, and os is a kernel or OS version string.
CREATE TABLE IF NOT EXISTS pings (
  day      TEXT NOT NULL,
  install  TEXT NOT NULL,
  version  TEXT,
  build    TEXT,
  platform TEXT,
  os       TEXT,
  PRIMARY KEY (day, install)
);

CREATE INDEX IF NOT EXISTS pings_by_day ON pings (day);

-- Today's allowance for one install id or one IP. One row per bucket, rolled
-- over when the day in it is not today's.
CREATE TABLE IF NOT EXISTS quota (
  bucket TEXT PRIMARY KEY,
  day    TEXT NOT NULL,
  n      INTEGER NOT NULL
);

-- Switches, read at every request. `issues_off` set to 1 turns the anonymous
-- bug relay off without a deploy:
--   wrangler d1 execute jeansh-telemetry --remote \
--     --command "INSERT INTO flags (name, on_) VALUES ('issues_off', 1)
--                ON CONFLICT (name) DO UPDATE SET on_ = 1"
-- and 0 turns it back on.
CREATE TABLE IF NOT EXISTS flags (
  name TEXT PRIMARY KEY,
  on_  INTEGER NOT NULL DEFAULT 0
);
