# Refactoring Plan: Generalize + Remove Shell Dependency

## Goal

Make `imapfilter-openai-classifier.lua` general-purpose (configurable categories,
prompts, API endpoints) and eliminate the `curl` shell invocation in favor of
native Lua HTTPS via `luasec` + `luasocket`.

## Architecture Change

```
Before:  Lua → shell_quote(payload) → io.popen("curl ...") → OpenAI API
After:   Lua → dkjson.encode(table) → ssl.https.request()  → OpenAI API
```

imapfilter 2.8.5 links against Lua 5.5.0 and OpenSSL3 — both already installed
via Homebrew. We leverage them directly instead of shelling out.

## Dependencies to Add

| Package    | Purpose                  | Install                                    |
|------------|--------------------------|--------------------------------------------|
| luarocks   | Lua package manager      | `brew install luarocks`                    |
| luasocket  | TCP sockets              | `luarocks --lua-version 5.5 install luasocket` |
| luasec     | TLS via OpenSSL          | `luarocks --lua-version 5.5 install luasec`     |
| dkjson     | JSON encode/decode       | `luarocks --lua-version 5.5 install dkjson`    |

imapfilter loads Lua 5.5's `package.cpath` (`/opt/homebrew/lib/lua/5.5/?.so`),
so modules installed for 5.5 are automatically available via `require`.

## File Changes

### 1. New: `~/.config/imapfilter-llm-sort/config.lua`

Single source of truth. Returns a table with all configuration:

- `api.*` — URL, key, model, style ("responses"|"chat"), timeout
- `categories[]` — array of `{ name, mailbox, description }` objects
- `system_prompt` — system-level prompt sent to the LLM
- `truncation.*` — max lengths for from/subject/body
- `imap.*` — server, username, password, SSL mode, lookback days
- `debug` — boolean flag for verbose output

All values fall back to environment variables, so the config file can be minimal
for users who prefer env vars.

### 2. Rewrite: `imapfilter-openai-classifier.lua`

Implemented as a reusable Lua module returning a table with a `.new(options)` constructor
and a `:classify_email(email)` method.

| Removed                          | Replaced By                                     |
|----------------------------------|-------------------------------------------------|
| `shell_quote()`                  | Not needed — no shell commands                  |
| `json_escape()`                  | `dkjson.encode()`                               |
| `build_responses_payload()`      | `build_payload()` using `dkjson.encode()`       |
| `build_chat_payload()`           | `build_payload()` using `dkjson.encode()`       |
| `extract_json_object()`          | `dkjson.decode()`                               |
| `decode_json_string_value()`     | `dkjson.decode()`                               |
| `io.popen("curl ...")`           | `ssl.https.request()`                           |
| `pipe_from()` fallback           | `ssl.https.request()`                           |
| `normalize_category()` hardcoded | Accepts `valid_categories` table from config    |

New/modified functions:

- `build_payload()` — builds a Lua table (system/user messages, temperature,
  response_format) and encodes with `dkjson.encode()`. Supports both
  "responses" and "chat" API styles.
- `http_post(url, headers, body, timeout)` — wraps `ssl.https.request` with
  `ltn12` sinks/sources. Handles connection errors, timeouts, and non-2xx
  status codes gracefully (returns `nil, error`).
- `classify_email()` — streamlined: build prompt → build payload → HTTP POST →
  decode JSON → normalize category.

The module constructor accepts an optional `config` table or reads from the
default config path.

### 3. Rewrite: `imapfilter-example.lua`

- Loads config from `~/.config/imapfilter-llm-sort/config.lua`
- Reads IMAP account details from `config.imap`
- Dynamically builds `destinations` and `moves` tables from `config.categories`
- Uses `config.imap.lookback_days` for message selection
- Instantiates the classifier with `config.api` settings

### 4. Update: `README.md`

- Document luarocks dependency installation
- Document config file location and format
- Show examples of custom category definitions
- Keep existing usage examples updated for the new API
