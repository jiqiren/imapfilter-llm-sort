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

-- Target columns in canonical order. Any DB missing or differing from this set
-- will be migrated via a safe table recreation (rename → create → copy → drop).
local TARGET_COLUMNS = {
  "id", "config_hash", "message_id", "model", "status", "failure_reason",
  "tokens_in", "tokens_out", "classified_destination", "created_at", "updated_at",
}

-- Default expression to use when a target column is missing from the old table.
-- Used to build the INSERT ... SELECT during migration.
local COLUMN_DEFAULTS = {
  id                     = "id",
  config_hash            = "config_hash",
  message_id             = "message_id",
  model                  = "model",
  status                 = "'done'",
  failure_reason         = "NULL",
  tokens_in              = "tokens_in",
  tokens_out             = "tokens_out",
  classified_destination = "''",
  created_at             = "created_at",
  updated_at             = "CURRENT_TIMESTAMP",
}

local function get_table_columns(db, name)
  -- PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
  -- dromozoa-sqlite3 columns are 1-indexed (column 0 is reserved/nil)
  -- So: column(1)=cid, column(2)=name, column(3)=type, etc.
  local pragma = db:prepare("PRAGMA table_info(" .. name .. ")")
  if not pragma then
    return {}
  end
  local cols = {}
  while pragma:step() == 100 do
    local col_name = pragma:column(2)
    if col_name then
      table.insert(cols, col_name)
    end
  end
  pragma:finalize()
  return cols
end

local function schema_matches(db)
  local existing = get_table_columns(db, "classifications")
  local existing_set = {}
  for _, c in ipairs(existing) do
    existing_set[c] = true
  end
  for _, c in ipairs(TARGET_COLUMNS) do
    if not existing_set[c] then
      return false
    end
  end
  return true
end

local function migrate_schema(db)
  -- Table doesn't exist yet — CREATE TABLE IF NOT EXISTS handled it
  if not schema_matches(db) then
    local old_cols = get_table_columns(db, "classifications")
    local old_set = {}
    for _, c in ipairs(old_cols) do
      old_set[c] = true
    end

    -- Build SELECT expressions: use old column name if present, else default
    local select_exprs = {}
    for _, c in ipairs(TARGET_COLUMNS) do
      if old_set[c] then
        table.insert(select_exprs, c)
      else
        table.insert(select_exprs, COLUMN_DEFAULTS[c])
      end
    end

    local old_name = "classifications_old"
    local col_list = table.concat(TARGET_COLUMNS, ", ")
    local select_list = table.concat(select_exprs, ", ")

    -- Wrap in a transaction for crash safety
    local ok, err = pcall(db.exec, db, "BEGIN")
    if not ok then
      error("classifier cache: migration failed (BEGIN): " .. tostring(err))
    end

    ok, err = pcall(db.exec, db, "DROP TABLE IF EXISTS " .. old_name)
    if not ok then
      pcall(db.exec, db, "ROLLBACK")
      error("classifier cache: migration failed (drop old): " .. tostring(err))
    end

    ok, err = pcall(db.exec, db, "ALTER TABLE classifications RENAME TO " .. old_name)
    if not ok then
      pcall(db.exec, db, "ROLLBACK")
      error("classifier cache: migration failed (rename): " .. tostring(err))
    end

    ok, err = pcall(db.exec, db, SCHEMA)
    if not ok then
      pcall(db.exec, db, "ROLLBACK")
      error("classifier cache: migration failed (create): " .. tostring(err))
    end

    local migrate_sql = "INSERT INTO classifications (" .. col_list .. ") "
      .. "SELECT " .. select_list .. " FROM " .. old_name
    ok, err = pcall(db.exec, db, migrate_sql)
    if not ok then
      pcall(db.exec, db, "ROLLBACK")
      error("classifier cache: migration failed (copy data): " .. tostring(err))
    end

    ok, err = pcall(db.exec, db, "DROP TABLE " .. old_name)
    if not ok then
      pcall(db.exec, db, "ROLLBACK")
      error("classifier cache: migration failed (drop old): " .. tostring(err))
    end

    ok, err = pcall(db.exec, db, "COMMIT")
    if not ok then
      error("classifier cache: migration failed (COMMIT): " .. tostring(err))
    end
  end
end

function ClassifierCache.new(options)
  options = options or {}
  local path = options.path

  if not path or path == "" then
    error("classifier cache: path is required")
  end

  local db = sqlite3.open(path)

  -- Enable WAL mode for better crash resilience (important for loop runner)
  local ok, err = pcall(db.exec, db, "PRAGMA journal_mode=WAL")
  if not ok then
    db:close()
    error("classifier cache: failed to enable WAL mode: " .. tostring(err))
  end

  local ok, err = pcall(db.exec, db, SCHEMA)
  if not ok then
    db:close()
    error("classifier cache: failed to create schema: " .. tostring(err))
  end

  -- Migrate schema if columns don't match the target layout
  migrate_schema(db)

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

function ClassifierCache:close()
  if self._db then
    self._db:close()
    self._db = nil
  end
end

return ClassifierCache
