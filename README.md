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

### 1. Install imapfilter

```sh
brew install imapfilter
```

### 2. Install Lua dependencies

```sh
brew install luarocks
luarocks --lua-version 5.5 install luasocket
luarocks --lua-version 5.5 install luasec
luarocks --lua-version 5.5 install dkjson
luarocks --lua-version 5.5 install dromozoa-sqlite3
luarocks --lua-version 5.5 install md5
```

### 3. Configure

Copy and edit the config file:

```sh
mkdir -p ~/.config/imapfilter-llm-sort
cp config.example.lua ~/.config/imapfilter-llm-sort/config.lua
```

Edit `~/.config/imapfilter-llm-sort/config.lua`:
- Set `imap.server`, `imap.username`, `imap.ssl`.
- Confirm destination mailboxes exist with the names listed in `categories[].mailbox`.
- Adjust `categories[]` to define your own sorting rules (name, mailbox, LLM description).
- Update the path in `imapfilter-sort.lua` if you cloned the repo elsewhere.

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

## Crash recovery

If imapfilter crashes mid-classification, messages marked as `status='sorting'` in
the cache are retried at the start of the next run. Messages no longer in INBOX
are cleaned up automatically.

## Dry-run mode

Set `OPENAI_CLASSIFIER_DRY_RUN=1` or use `-n` / `--dry-run` in `macos-loop.zsh` to
classify messages and log what would happen without actually moving them. This is
useful for testing new categories or model configurations before committing to
changes. In dry-run mode, the cache is read but never written to.

## Environment variables

All are optional if set in `config.lua`, but `OPENAI_API_KEY` and
`IMAP_PASSWORD` are required at runtime (at least one of those two must be set
in the environment).

| Variable | Config key | Default | Description |
|---|---|---|---|
| `OPENAI_API_KEY` | `api.key` | — (required) | API key for the LLM endpoint |
| `OPENAI_URL` | `api.url` | `https://api.openai.com/v1/responses` | API endpoint URL |
| `OPENAI_MODEL` | `api.model` | `qwen/qwen3-4b-2507,google/gemma-4-12b` | Model name to request |
| `OPENAI_API_STYLE` | `api.style` | `responses` | API protocol: `"responses"` or `"chat"` |
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
- `-m, --model MODEL` — model name
- `-k, --api-key KEY` — API key
- `-d, --debug` — enable debug output (`OPENAI_CLASSIFIER_DEBUG=1`)
- `-n, --dry-run` — classify and log without moving messages
- `-h, --help` — print usage

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

**What's cached:** the config hash (deterministic MD5 of categories, model,
system prompt, truncation), Message-Id, model name, token counts, and the
classified destination (including `""` for unknown).

**Cache invalidation:** changing categories, model, system prompt, or
truncation settings produces a new config hash — old entries are ignored
but not deleted. Run `sqlite3 ~/.config/imapfilter-llm-sort/classifications.db` for
manual inspection or cleanup.

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
