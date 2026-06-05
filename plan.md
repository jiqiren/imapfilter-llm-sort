# plan.md

## Done
- [x] Native Lua HTTPS (`luasec` + `luasocket`) — no shell
- [x] `dkjson` encode/decode — no regex JSON
- [x] Configurable categories via `config.lua`
- [x] Configurable prompts from category descriptions
- [x] Configurable IMAP settings
- [x] Responses API + Chat Completions API
- [x] Auto-detect `http://` vs `https://` from URL
- [x] `config.example.lua` in repo
- [x] Immediate moves (not bulk at end)
- [x] Per-message + summary stats (time, tokens)
- [x] `AGENTS.md`, `README.md` updated

## Planned: SQLite classification cache

Track every classification attempt in a SQLite DB. Skip API calls for
messages that already have a cached result (config hash + Message-Id + model).

### Dependencies (proven working with Lua 5.5)

```bash
luarocks --lua-version 5.5 install dromozoa-sqlite3
luarocks --lua-version 5.5 install md5
```

- `dromozoa-sqlite3`: 1-indexed columns (column 0 is always nil/reserved).
  `prepare()` + `bind_text()` / `bind_int64()` + `step()` + `column(i)`.
  `step()` returns 100 = SQLITE_ROW, 101 = SQLITE_DONE.
- `md5`: `require("md5").sumhexa(string)` returns hex digest.
- `dkjson`: already installed. Used to serialize config fields for hashing.

### DB path
Default: `~/.config/imapfilter-llm-sort/classifications.db`
Configurable via `config.sqlite.path` (same pattern as `config.api.*`).

### Steps

#### 1. Create `imapfilter-classifier-cache.lua`

New module (same pattern as `imapfilter-openai-classifier.lua`):
- `ClassifierCache.new(options)` — options: `path` (string, required)
  - Opens/creates SQLite DB at `path`.
  - Runs `CREATE TABLE IF NOT EXISTS classifications (...)` on init.
- `ClassifierCache:lookup(config_hash, message_id, model)` → `nil` or `{ destination, tokens_in, tokens_out }`
  - Returns nil if no match. Returns values if found.
- `ClassifierCache:store(config_hash, message_id, model, tokens_in, tokens_out, destination)`
  - INSERT OR IGNORE (safe against races/dupes).
- `ClassifierCache:close()` — close the DB handle. Call on script exit.

Schema:
```
config_hash TEXT NOT NULL    -- md5 hex of config JSON
message_id TEXT NOT NULL     -- Message-Id header
model TEXT NOT NULL          -- API model name
tokens_in INTEGER DEFAULT 0
tokens_out INTEGER DEFAULT 0
classified_destination TEXT NOT NULL  -- "" means "unknown/inbox"
created_at TEXT DEFAULT CURRENT_TIMESTAMP
UNIQUE(config_hash, message_id, model)
```

#### 2. Modify `imapfilter-openai-classifier.lua`

- Add `self.config_hash` to constructor:
  - Compute `dkjson.encode({ categories, model, system_prompt, truncation })`
  - Hash it: `md5.sumhexa(encoded_config)`.
  - Store on `self`.

- New param on `classify_email`: `message_id` (string, required)
  - Passed through from sort script.

- New param on `classify_email`: `cache` (ClassifierCache instance or nil)
  - If `cache` is not nil, call `cache:lookup(config_hash, message_id, model)`.
  - On cache hit: log (if debug), return `(destination, tokens_in, tokens_out)` immediately.
  - On cache miss: continue to API call.
  - After successful API call: call `cache:store(...)` with results.
  - Store even errors? Yes — store result `""` too (avoid retrying failed same-email calls).

#### 3. Modify `imapfilter-sort.lua`

- At top, require `imapfilter-classifier-cache.lua` (dofile or the module path).
- Open cache:
  ```
  local cache_path = (config.sqlite and config.sqlite.path)
    or os.getenv("HOME") .. "/.config/imapfilter-llm-sort/classifications.db"
  local cache = Cache.new({ path = cache_path })
  ```
- When calling `classify`:
  - Fetch `Message-Id` in `fetch_first` call.
  - Pass `message_id` to `classifier:classify_email()`.
  - Pass `cache` instance to `classifier:classify_email()`.
  - On cache hit: elapsed time will be near-zero. Stats should note this.

#### 4. Update `config.example.lua`

Add optional `sqlite` section:
```
sqlite = {
  path = os.getenv("OPENAI_CLASSIFIER_CACHE") or nil,
},
```

#### 5. Update AGENTS.md

- Add `dromozoa-sqlite3` and `md5` to Dependencies section.
- Add `imapfilter-classifier-cache.lua` to Files table.
- Update Architecture diagram to show cache layer.
- Convention: 1-indexed columns in dromozoa-sqlite3.

### Edge cases

- **config_hash mismatch after changing config**: Old entries simply won't match
  because the hash includes categories/model/system_prompt/truncation. No cleanup needed.
- **DB locked**: `dromozoa-sqlite3` uses default SQLite busy handling.
  Single-threaded imapfilter means no concurrent access — should not lock in practice.
- **Missing Message-Id**: If a message has no Message-Id header, we cannot cache it.
  Fall back to API call without caching. This is rare but valid per RFC 5322.
- **Disk full / permission denied**: `create_table` and `store` use pcall internally;
  fail silently with debug log. Cache should never block classification.
