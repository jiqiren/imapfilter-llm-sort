local sqlite3 = require("dromozoa.sqlite3")

local ClassifierCache = {}
ClassifierCache.__index = ClassifierCache

local SCHEMA = [[
  CREATE TABLE IF NOT EXISTS classifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    config_hash TEXT NOT NULL,
    message_id TEXT NOT NULL,
    model TEXT NOT NULL,
    status TEXT NOT NULL,
    failure_reason TEXT,
    tokens_in INTEGER DEFAULT 0,
    tokens_out INTEGER DEFAULT 0,
    classified_destination TEXT NOT NULL DEFAULT '',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(config_hash, message_id, model)
  )
]]

local function migrate_old_schema(db)
  -- Check if old schema exists (no 'status' column)
  local pragma = db:prepare("PRAGMA table_info(classifications)")
  if not pragma then
    return
  end

  local has_status = false
  while pragma:step() == 100 do
    local col_name = pragma:column(1)
    if col_name == "status" then
      has_status = true
      break
    end
  end
  pragma:finalize()

  if has_status then
    return
  end

  -- SQLite supports ALTER TABLE ADD COLUMN with DEFAULT since 3.30.0
  local ok, err = pcall(db.exec, db, "ALTER TABLE classifications ADD COLUMN status TEXT NOT NULL DEFAULT 'done'")
  if not ok then error("classifier cache: migration failed (status): " .. tostring(err)) end

  ok, err = pcall(db.exec, db, "ALTER TABLE classifications ADD COLUMN failure_reason TEXT")
  if not ok then error("classifier cache: migration failed (failure_reason): " .. tostring(err)) end

  ok, err = pcall(db.exec, db, "ALTER TABLE classifications ADD COLUMN updated_at TEXT DEFAULT CURRENT_TIMESTAMP")
  if not ok then error("classifier cache: migration failed (updated_at): " .. tostring(err)) end
end

function ClassifierCache.new(options)
  options = options or {}
  local path = options.path

  if not path or path == "" then
    error("classifier cache: path is required")
  end

  local db = sqlite3.open(path)

  local ok, err = pcall(db.exec, db, SCHEMA)
  if not ok then
    db:close()
    error("classifier cache: failed to create schema: " .. tostring(err))
  end

  -- Migrate old schema if present
  migrate_old_schema(db)

  local self = {
    _db = db,
    _path = path,
  }

  return setmetatable(self, ClassifierCache)
end

function ClassifierCache:lookup(config_hash, message_id, model)
  local stmt = self._db:prepare([[
    SELECT classified_destination, tokens_in, tokens_out
    FROM classifications
    WHERE config_hash = ? AND message_id = ? AND model = ? AND status = 'done'
  ]])

  if not stmt then
    return nil
  end

  stmt:bind_text(1, config_hash)
  stmt:bind_text(2, message_id)
  stmt:bind_text(3, model)

  local rc = stmt:step()
  if rc ~= 100 then
    stmt:finalize()
    return nil
  end

  local destination = stmt:column(1)
  local tokens_in = stmt:column(2)
  local tokens_out = stmt:column(3)

  stmt:finalize()

  return {
    destination = destination or "",
    tokens_in = tonumber(tokens_in) or 0,
    tokens_out = tonumber(tokens_out) or 0,
  }
end

function ClassifierCache:mark_sorting(config_hash, message_id, model)
  local stmt = self._db:prepare([[
    INSERT OR IGNORE INTO classifications
      (config_hash, message_id, model, status, failure_reason, tokens_in, tokens_out, classified_destination)
    VALUES (?, ?, ?, 'sorting', NULL, 0, 0, '')
  ]])

  if not stmt then
    return false
  end

  stmt:bind_text(1, config_hash)
  stmt:bind_text(2, message_id)
  stmt:bind_text(3, model)

  stmt:step()
  stmt:finalize()

  return true
end

function ClassifierCache:update_done(config_hash, message_id, model, tokens_in, tokens_out, destination)
  local stmt = self._db:prepare([[
    UPDATE classifications
    SET status = 'done',
        failure_reason = NULL,
        tokens_in = ?,
        tokens_out = ?,
        classified_destination = ?,
        updated_at = CURRENT_TIMESTAMP
    WHERE config_hash = ? AND message_id = ? AND model = ?
  ]])

  if not stmt then
    return false
  end

  stmt:bind_int64(1, tokens_in or 0)
  stmt:bind_int64(2, tokens_out or 0)
  stmt:bind_text(3, destination or "")
  stmt:bind_text(4, config_hash)
  stmt:bind_text(5, message_id)
  stmt:bind_text(6, model)

  stmt:step()
  stmt:finalize()

  return true
end

function ClassifierCache:mark_failed(config_hash, message_id, model, reason)
  local stmt = self._db:prepare([[
    UPDATE classifications
    SET status = 'failed',
        failure_reason = ?,
        updated_at = CURRENT_TIMESTAMP
    WHERE config_hash = ? AND message_id = ? AND model = ?
  ]])

  if not stmt then
    return false
  end

  stmt:bind_text(1, reason or "")
  stmt:bind_text(2, config_hash)
  stmt:bind_text(3, message_id)
  stmt:bind_text(4, model)

  stmt:step()
  stmt:finalize()

  return true
end

function ClassifierCache:get_stale_ids(status)
  local stmt = self._db:prepare([[
    SELECT message_id FROM classifications WHERE status = ?
  ]])

  if not stmt then
    return {}
  end

  local ids = {}
  while stmt:step() == 100 do
    local msg_id = stmt:column(1)
    if msg_id then
      table.insert(ids, msg_id)
    end
  end
  stmt:finalize()

  return ids
end

function ClassifierCache:close()
  if self._db then
    self._db:close()
    self._db = nil
  end
end

return ClassifierCache
