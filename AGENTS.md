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
lua -e 'dofile("imapfilter-openai-classifier.lua")'   # must not error
lua -e 'dofile("imapfilter-classifier-cache.lua")'     # must not error
lua -e 'dofile("imapfilter-sort.lua")'             # errors on IMAP connect (expected)
zsh -n macos-loop.zsh                                 # must pass syntax check
```

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

```bash
brew install luarocks
luarocks --lua-version 5.5 install luasocket
luarocks --lua-version 5.5 install luasec
luarocks --lua-version 5.5 install dkjson
luarocks --lua-version 5.5 install dromozoa-sqlite3
luarocks --lua-version 5.5 install md5
```

Runtime: imapfilter 2.8.5 links Lua 5.5.0 + OpenSSL3 (both Homebrew).