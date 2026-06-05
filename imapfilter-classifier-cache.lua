local sqlite3 = require("dromozoa.sqlite3")

local ClassifierCache = {}
ClassifierCache.__index = ClassifierCache

local SCHEMA = [[
  CREATE TABLE IF NOT EXISTS classifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    config_hash TEXT NOT NULL,
    message_id TEXT NOT NULL,
    model TEXT NOT NULL,
    tokens_in INTEGER DEFAULT 0,
    tokens_out INTEGER DEFAULT 0,
    classified_destination TEXT NOT NULL,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(config_hash, message_id, model)
  )
]]

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
    WHERE config_hash = ? AND message_id = ? AND model = ?
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

function ClassifierCache:store(config_hash, message_id, model, tokens_in, tokens_out, destination)
  local stmt = self._db:prepare([[
    INSERT OR IGNORE INTO classifications
      (config_hash, message_id, model, tokens_in, tokens_out, classified_destination)
    VALUES (?, ?, ?, ?, ?, ?)
  ]])

  if not stmt then
    return false
  end

  stmt:bind_text(1, config_hash)
  stmt:bind_text(2, message_id)
  stmt:bind_text(3, model)
  stmt:bind_int64(4, tokens_in or 0)
  stmt:bind_int64(5, tokens_out or 0)
  stmt:bind_text(6, destination or "")

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
