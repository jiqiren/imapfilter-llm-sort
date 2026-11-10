# imapfilter LLM Email Sorting

Classifies recent INBOX messages using an OpenAI-compatible LLM, then moves
them into IMAP mailboxes by category. Runs as an imapfilter config script.
Unknown categories leave messages in INBOX (conservative by design).

## Files

- `imapfilter-openai-classifier.lua`: reusable classifier module.
- `imapfilter-classifier-cache.lua`: SQLite result cache (skips API for repeat messages).
- `imapfilter-sort.lua`: imapfilter config entry point.
- `macos-loop.zsh`: infinite loop runner with CLI argument parsing.
- `config.example.lua`: reference config — copy to `~/.config/imapfilter-llm-sort/config.lua`.

## Setup

Everything is installed with Homebrew except the five Lua rocks, which have no
formulae and must come from LuaRocks. The brew `luarocks` formula targets the
same Lua 5.5 that imapfilter embeds, so the two stay in sync.

### 1. Install brew packages

```sh
brew install imapfilter luarocks lua
```

- **`imapfilter`** — the host program. This repo is an imapfilter config script,
  not a standalone binary. Formula 2.8.6; links `lua`, `openssl@4`, `pcre2`.
- **`luarocks`** — needed only to install the Lua rocks in step 2. Bottled; its
  only dependency is `lua`, and it reports `lua_version 5.5`.
- **`lua`** — brew's `luarocks` depends on it, but it is listed explicitly so
  `luarocks` is guaranteed to build rocks against Lua 5.5.1 — the same
  `liblua.5.5.dylib` that imapfilter links against.

imapfilter pulls in `openssl@4` and `pcre2` on its own; no other brew packages
are required. The CLT compiler (`cc` / `c++`) is used to build the rocks —
install it with `xcode-select --install` if `cc` is missing.

### 2. Install Lua rocks

None of the seven Lua modules this project needs exist as Homebrew formulae, so
they come from LuaRocks. Order matters only in that `luasec` depends on
`luasocket`:

```sh
luarocks install dkjson
luarocks install luasocket
luarocks install luasec
luarocks install md5
luarocks install dromozoa-sqlite3
```

`--lua-version 5.5` is unnecessary: brew's `luarocks` already resolves to 5.5
(verify with `luarocks config lua_version`). Add it only if you have several Lua
versions installed. Rocks install into `/opt/homebrew/lib/luarocks/rocks-5.5/`,
which is already on imapfilter's `package.path`/`package.cpath`.

`luasocket` also supplies `ltn12`, so five rocks cover all seven `require()`s:

| `require()` name | Rock | Homebrew formula? | Used for |
|---|---|---|---|
| `socket`, `socket.http` | `luasocket` | no — luarocks only | plain-HTTP requests (local endpoints), timeouts |
| `ltn12` | `luasocket` | no — luarocks only | request body source / response sink |
| `ssl.https` | `luasec` | no — luarocks only | HTTPS requests to the LLM API |
| `dkjson` | `dkjson` | no — luarocks only | encoding payloads, decoding API responses |
| `md5` | `md5` | no — luarocks only | config hash for the cache key |
| `dromozoa.sqlite3` | `dromozoa-sqlite3` | no — luarocks only | SQLite classification cache |

All five build cleanly with just the packages above. `luasec` auto-detects
OpenSSL in the Homebrew prefix, `md5` bundles its own MD5 implementation, and
`dromozoa-sqlite3` links the system `libsqlite3` — so no `openssl`, `sqlite`, or
`pkg-config` formula is needed.

If a C rock fails to configure, point it at the keg explicitly:

```sh
luarocks install luasec OPENSSL_DIR="$(brew --prefix openssl@4)"
```

### 3. Verify the modules load

imapfilter embeds its own Lua 5.5, so check the modules resolve for *that*
interpreter — a bare `lua -e` check can pass while imapfilter still fails, and
vice versa. All seven modules must load:

```sh
printf '%s\n' \
  'for _,m in ipairs({"socket","socket.http","ltn12","ssl.https","dkjson","md5","dromozoa.sqlite3"}) do' \
  '  local ok,err=pcall(require,m)' \
  '  io.stderr:write(string.format("%-18s %s\n",m,ok and "OK"' \
  '    or "FAIL: "..tostring(err):gsub("%s+"," "):gsub(" no file[^;]*","")))' \
  'end' > /tmp/modcheck.lua
imapfilter -c /tmp/modcheck.lua
```

Expected output:

```
socket             OK
socket.http        OK
ltn12              OK
ssl.https          OK
dkjson             OK
md5                OK
dromozoa.sqlite3   OK
```

A `FAIL` usually means the rocks went to a different Lua tree — check
`luarocks config lua_version` and `luarocks config rocks_trees`.

### 4. Configure

Copy and edit the config file:

```sh
mkdir -p ~/.config/imapfilter-llm-sort
cp config.example.lua ~/.config/imapfilter-llm-sort/config.lua
```

Edit `~/.config/imapfilter-llm-sort/config.lua`:
- Set `imap.server`, `imap.username`, `imap.ssl`.
- Confirm destination mailboxes exist with the names listed in `categories[].mailbox`.
- Adjust `categories[]` to define your own sorting rules (name, mailbox, LLM description).
- `imapfilter-sort.lua` loads the two Lua modules from a hardcoded path:
  `$HOME/proj/imapfilter-llm-sort/`. If you cloned the repo anywhere else, edit
  both `dofile()` paths (the classifier and the cache module) to match.

All config values can be set via environment variables; the config file falls
back to them automatically.

## Model escalation

You can configure multiple models as a comma-separated list. The classifier tries
them in order and escalates on transient failures:

- `OPENAI_MODEL="qwen/qwen3-4b-2507,google/gemma-4-12b"` — try `qwen/qwen3-4b-2507` first, fall back to `google/gemma-4-12b`
- `-m qwen/qwen3-4b-2507,google/gemma-4-12b` in `macos-loop.zsh`

**Escalation rules:**
- API timeout (`api_timeout`) or HTTP errors (`http_error`) → escalate to next model
- Parse errors (`parse_error`) or IMAP failures → do NOT escalate (message stays in INBOX)

This lets you use a fast/cheap model first and fall back to a more capable one when
the first model times out or returns an HTTP error.

## Cache behavior

Messages are marked `status='sorting'` in the cache during classification, then
updated to `done` or `failed` when complete. The SQLite cache is never trimmed
automatically — entries accumulate indefinitely. For manual inspection or cleanup:

```sh
sqlite3 ~/.config/imapfilter-llm-sort/classifications.db
```

## Dry-run mode

Set `OPENAI_CLASSIFIER_DRY_RUN=1` or use `-n` / `--dry-run` in `macos-loop.zsh` to
classify messages and log what would happen without actually moving them. This is
useful for testing new categories or model configurations before committing to
changes. In dry-run mode, the cache is read but never written to.

## Environment variables

All are optional if set in `config.lua`, but both `OPENAI_API_KEY`
(auth for the LLM endpoint) and `IMAP_PASSWORD` (auth to your mail server)
must be available at runtime — via env var or config file.

| Variable | Config key | Default | Description |
|---|---|---|---|
| `OPENAI_API_KEY` | `api.key` | — (required) | API key for the LLM endpoint |
| `OPENAI_URL` | `api.url` | `https://api.openai.com/v1/responses` | API endpoint URL |
| `OPENAI_MODEL` | `api.model` | `qwen/qwen3-4b-2507,google/gemma-4-12b` | Model name to request |
| `OPENAI_API_STYLE` | `api.style` | `responses` | API protocol: `"responses"` or `"chat"` |
| `OPENAI_RESPONSE_FORMAT` | `api.response_format` | `json_object` | Structured output: `"json_object"`, `"json_schema"`, or `"none"` |
| `OPENAI_TIMEOUT_SECONDS` | `api.timeout_seconds` | `600` | HTTP request timeout in seconds |
| `OPENAI_CLASSIFIER_DEBUG` | `api.debug` | (off) | Set to `1` to log raw API responses to stderr |
| `OPENAI_CLASSIFIER_DRY_RUN` | `api.dry_run` | (off) | Set to `1` to classify without moving messages |
| `OPENAI_CLASSIFIER_CONFIG` | — | `~/.config/imapfilter-llm-sort/config.lua` | Override config file path |
| `OPENAI_CLASSIFIER_CACHE` | `sqlite.path` | `~/.config/imapfilter-llm-sort/classifications.db` | SQLite cache database path |
| `OPENAI_DELAY_BETWEEN_CALLS` | `api.delay_between_calls` | `0` | Seconds to wait between API calls (prevents rate limit hits) |
| `OPENAI_RATE_LIMIT_MAX_RETRIES` | `api.rate_limit_max_retries` | `3` | Max retries on HTTP 429 with exponential backoff |
| `OPENAI_RATE_LIMIT_INITIAL_DELAY` | `api.rate_limit_initial_delay` | `5` | Initial backoff delay in seconds; doubles each retry |
| `IMAP_SERVER` | `imap.server` | `imap.example.com` | IMAP server hostname |
| `IMAP_USER` | `imap.username` | `you@example.com` | IMAP username / email |
| `IMAP_PASSWORD` | `imap.password` | — (required) | IMAP password or app password |
| `IMAP_SSL` | `imap.ssl` | `tls1.2` | SSL/TLS version string |
| `IMAP_FOLDER` | `imap.folder` | `INBOX` | Folder to process (`INBOX`, `ALL`, or specific name) |
| `IMAP_LOOKBACK_DAYS` | `imap.lookback_days` | `1` | Process messages from the last N days |
| `IMAP_LOOKBACK_DAY` | `imap.lookback_day` | — | Process messages from a single date (`YYYY-MM-DD`) |
| `IMAP_MAX_MSGS` | `imap.max_msgs` | `0` | Max messages per run (`0` = no limit, safety valve for `ALL`) |

`IMAP_LOOKBACK_DAY` takes precedence over `IMAP_LOOKBACK_DAYS` when set.

## Run

### OpenAI Responses API (default)

```sh
export OPENAI_API_KEY="..."
export IMAP_PASSWORD="..."
imapfilter -c imapfilter-sort.lua
```

### OpenAI-compatible Chat Completions endpoint

```sh
export OPENAI_API_KEY="..."
export IMAP_PASSWORD="..."
export OPENAI_API_STYLE="chat"
export OPENAI_URL="http://localhost:1234/v1/chat/completions"
export OPENAI_MODEL="your-model"
imapfilter -c imapfilter-sort.lua
```

### Apple `fm serve` (local)

`fm serve` exposes an OpenAI-compatible chat endpoint on
`http://localhost:8000/v1/chat/completions` but rejects `json_object`
structured output. Use `json_schema` instead:

```sh
export OPENAI_API_STYLE="chat"
export OPENAI_URL="http://localhost:8000/v1/chat/completions"
export OPENAI_MODEL="apple-fm"
export OPENAI_RESPONSE_FORMAT="json_schema"
imapfilter -c imapfilter-sort.lua
```

The `json_schema` format is derived from your `categories`: a `category` field
whose enum is every `categories[].name` plus `""` (the "uncertain / leave in
INBOX" option), along with `confidence` and `reason`. All three properties are
required and additional properties are rejected.

`fm serve` may return responses as server-sent events even when `stream` is
false. The classifier detects SSE streams and reassembles the deltas before
parsing, so no extra configuration is needed.

### Debug mode

```sh
export OPENAI_CLASSIFIER_DEBUG=1
```

Writes raw API responses and HTTP status codes to stderr.

## Continuous / loop mode

`macos-loop.zsh` runs the classifier in a loop with a configurable sleep
interval. It exports all needed environment variables and has CLI options to
override defaults:

```sh
./macos-loop.zsh \
  -S imap.fastmail.com \
  -u me@fastmail.com \
  -U https://api.openai.com/v1/responses \
  -m qwen/qwen3-4b-2507 \
  -k sk-abc123 \
  -s 600 \
  -d
```

Options:
- `-s, --sleep SECONDS` — seconds between runs (default: 300, i.e. 5 minutes)
- `-S, --imap-server HOST` — IMAP server hostname
- `-u, --imap-user USER` — IMAP username
- `-U, --openai-url URL` — OpenAI-compatible API endpoint
- `-A, --api-style STYLE` — API protocol: `"responses"` or `"chat"` (default: `responses`)
- `-R, --response-format FORMAT` — structured output: `"json_object"`, `"json_schema"`, or `"none"` (default: `json_object`) — use `json_schema` for Apple `fm serve`
- `-m, --model MODEL` — model name
- `-k, --api-key KEY` — API key
- `-D, --delay SECONDS` — seconds between API calls (default: 0)
- `-f, --folder FOLDER` — IMAP folder to process (`INBOX`, specific name, or `ALL`; default: `INBOX`)
- `-M, --max-msgs N` — max messages per run (0 = no limit; safety valve for `ALL`)
- `-d, --debug` — enable debug output (`OPENAI_CLASSIFIER_DEBUG=1`)
- `-n, --dry-run` — classify and log without moving messages
- `-h, --help` — print usage

Note: `macos-loop.zsh`'s own defaults differ from `config.example.lua` — it
defaults to `http://127.0.0.1:1234/v1/responses` with model
`google/gemma-4-12b`. Pass explicit flags unless you set the env vars or want
those local defaults.

CLI options override environment variables. `IMAP_PASSWORD` should still be set
in the environment since it's not accepted as a CLI flag.

The `-m` flag accepts a comma-separated list for model escalation
(e.g. `-m qwen/qwen3-4b-2507,google/gemma-4-12b`).

## Classification cache

A SQLite database records every classification result. On subsequent runs,
messages with the same Message-Id, model, and config are returned immediately
without hitting the API — saving time and tokens.

The cache is stored at `~/.config/imapfilter-llm-sort/classifications.db` by
default. Override with `OPENAI_CLASSIFIER_CACHE` or `config.sqlite.path`.

**What's cached:** the config hash (deterministic MD5 of categories, system
prompt, and truncation settings — **not** the model), Message-Id, model name,
token counts, and the classified destination (including `""` for unknown).

**Cache invalidation:** changing categories, system prompt, or truncation
settings produces a new config hash — old entries are ignored but not
deleted. The model is **not** part of the config hash; instead each entry is
keyed by `config_hash + Message-Id + model`, so switching models simply looks
up (and stores) different rows rather than invalidating anything.
Run `sqlite3 ~/.config/imapfilter-llm-sort/classifications.db` for manual
inspection or cleanup.

When `OPENAI_CLASSIFIER_DEBUG=1`, cache hits, misses, and stores are logged
to stderr.

## Customizing categories

Edit the `categories` array in your config. Each entry needs:

```lua
{ name = "category_name", mailbox = "IMAP_mailbox_name",
  description = "LLM prompt description of what belongs here" }
```

The LLM returns one of the `name` values, and messages are moved to the
corresponding `mailbox`. Unknown/mismatched categories stay in INBOX.

## Notes

The classifier is intentionally conservative. If the model returns anything
other than a recognized category name, the message is left in `INBOX`.
Temperature is always 0 for deterministic results.
