# AGENTS.md — imapfilter-llm-sort

## What this project does

Classifies recent INBOX messages using an OpenAI-compatible LLM, then moves them
into IMAP mailboxes by category. Runs as an imapfilter config script. Unknown
categories leave messages in INBOX (conservative by design).

## Files

```
imapfilter-llm-sort/
├── imapfilter-openai-classifier.lua   # Core module (ssl.https + dkjson)
├── imapfilter-classifier-cache.lua    # SQLite cache (dromozoa-sqlite3 + md5)
├── imapfilter-sort.lua                 # imapfilter entry point
├── config.example.lua                 # Reference config (copy to ~/.config/...)
├── macos-loop.zsh                     # Infinite loop runner with CLI arg parsing
├── README.md                          # User docs
├── plan.md                            # Project plan / todo
└── AGENTS.md                          # This file
```

User config lives at `~/.config/imapfilter-llm-sort/config.lua`.

## Verify

```bash
# All 7 required modules must load under imapfilter's own Lua 5.5 —
# see README "Setup / Verify the modules load" for a ready-made snippet.
imapfilter -c /tmp/modcheck.lua

# Module smoke test (classifier .new + cache round-trip) also via imapfilter.
zsh -n macos-loop.zsh                                 # must pass syntax check
```

Note: `lua -e 'dofile(...)'` is misleading here — prefer running checks through
`imapfilter -c`, since imapfilter embeds its own Lua 5.5 and has its own
`package.path`/`cpath`.

Integration test requires imapfilter:
```bash
OPENAI_API_KEY=... IMAP_PASSWORD=... OPENAI_CLASSIFIER_DEBUG=1 \
  imapfilter -c imapfilter-sort.lua
```

## Conventions

- **Module pattern:** OOP via `__index` metatable. Constructor: `.new(options)`. Methods: `:methodName()`.
- **Error handling:** HTTP/parse failures return `""` (message stays in INBOX).
- **JSON:** Always use `dkjson.encode()` / `dkjson.decode()`. Never string concat.
- **No shell:** All HTTP via `ssl.https.request()`. No `io.popen`, `pipe_from`, `pipe_to`.
- **Config:** Nothing hardcoded. Values come from config file or env vars.
- **SQLite:** Uses `dromozoa-sqlite3`. Columns are 1-indexed (column 0 is always nil/reserved).
- **Cache-first fetch:** `classify()` fetches `Message-Id` only, then calls `classifier:check_cache()`. From/Subject/body are fetched only on cache miss to avoid unnecessary IMAP traffic.

## Architecture

```
config.lua ──▶ imapfilter-sort.lua ──dofile()──▶ imapfilter-openai-classifier.lua
                  │      │                                        │
                  │      │                              ssl.https.request()
                  │      │                                        │
                  │      ▼                                        ▼
                  │  imapfilter-classifier-cache.lua    OpenAI-compatible API
                  │      │
                  │      ▼
                  │  SQLite (classifications.db)
                  │
                  ▼
              IMAP server
```

The classifier module is stateless between `:classify_email()` calls. The cache
module stores past results indexed by config hash + Message-Id + model.

## Data flow per message

1. Fetch `Message-Id` from IMAP
2. Check SQLite cache via `classifier:check_cache()` for (config_hash, Message-Id, model) — return cached result on hit
3. On cache miss, fetch `From`, `Subject`, body from IMAP
4. Truncate fields to configurable limits
5. Build prompt from category descriptions in config
6. POST to LLM API (`/v1/responses` or `/v1/chat/completions`)
7. Parse JSON response with `dkjson.decode()`
8. Normalize category against `config.categories[].name` — mismatch → `""`
9. Store result in SQLite cache (config_hash, Message-Id, model, tokens, destination)

## API styles

| Style | Endpoint | Payload key |
|-------|----------|-------------|
| `"responses"` | `/v1/responses` | `input` array, `text.format.json_object` |
| `"chat"` | `/v1/chat/completions` | `messages` array, `response_format.json_object` |

Temperature is always 0. Both styles include a configurable system prompt.

## Dependencies

Brew (everything except the Lua rocks):

```bash
brew install imapfilter luarocks lua
```

- `imapfilter` 2.8.6 — host program; links `lua`, `openssl@4`, `pcre2`.
- `luarocks` 3.13.0 — only needed to install rocks; depends on `lua`, reports
  `lua_version 5.5`, so `--lua-version 5.5` is not required.
- `lua` 5.5.1 — matches the `liblua.5.5.dylib` imapfilter links.

Rocks (no brew formulae exist for any of these):

```bash
luarocks install dkjson            # pure Lua
luarocks install luasocket         # provides socket, socket.http, ltn12 (C)
luarocks install luasec            # provides ssl.https (C; auto-finds OpenSSL in brew prefix)
luarocks install md5               # (C; bundles own MD5, no OpenSSL needed)
luarocks install dromozoa-sqlite3  # (C++; links system libsqlite3)
```

All five build with just the brew packages above plus the CLT compiler — no
`openssl`/`sqlite`/`pkg-config` formula and no `OPENSSL_DIR` override needed.
Rocks land in `/opt/homebrew/lib/luarocks/rocks-5.5/`, already on imapfilter's
search path. See README "Setup" for the full require()-to-rock table.
