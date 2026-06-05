# imapfilter LLM Email Sorting

Classifies recent INBOX messages using an OpenAI-compatible LLM, then moves
them into IMAP mailboxes by category. Runs as an imapfilter config script.
Unknown categories leave messages in INBOX (conservative by design).

## Files

- `imapfilter-openai-classifier.lua`: reusable classifier module.
- `imapfilter-sort.lua`: imapfilter config entry point.
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

## Environment variables

All are optional if set in `config.lua`, but `OPENAI_API_KEY` and
`IMAP_PASSWORD` are required at runtime (at least one of those two must be set
in the environment).

| Variable | Config key | Default | Description |
|---|---|---|---|
| `OPENAI_API_KEY` | `api.key` | — (required) | API key for the LLM endpoint |
| `OPENAI_URL` | `api.url` | `https://api.openai.com/v1/responses` | API endpoint URL |
| `OPENAI_MODEL` | `api.model` | `gpt-4.1-mini` | Model name to request |
| `OPENAI_API_STYLE` | `api.style` | `responses` | API protocol: `"responses"` or `"chat"` |
| `OPENAI_TIMEOUT_SECONDS` | `api.timeout_seconds` | `600` | HTTP request timeout in seconds |
| `OPENAI_CLASSIFIER_DEBUG` | `api.debug` | (off) | Set to `1` to log raw API responses to stderr |
| `OPENAI_CLASSIFIER_CONFIG` | — | `~/.config/imapfilter-llm-sort/config.lua` | Override config file path |
| `IMAP_SERVER` | `imap.server` | `imap.example.com` | IMAP server hostname |
| `IMAP_USER` | `imap.username` | `you@example.com` | IMAP username / email |
| `IMAP_PASSWORD` | `imap.password` | — (required) | IMAP password or app password |
| `IMAP_SSL` | `imap.ssl` | `tls1.2` | SSL/TLS version string |
| `IMAP_LOOKBACK_DAYS` | `imap.lookback_days` | `1` | Process messages from the last N days |
| `IMAP_LOOKBACK_DAY` | `imap.lookback_day` | — | Process messages from a single date (`YYYY-MM-DD`) |

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
