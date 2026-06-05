# AGENTS.md — imapfilter-llm-sort

## What this project does

Classifies recent INBOX messages using an OpenAI-compatible LLM, then moves them
into IMAP mailboxes by category. Runs as an imapfilter config script. Unknown
categories leave messages in INBOX (conservative by design).

## Files

```
imapfilter-llm-sort/
├── imapfilter-openai-classifier.lua   # Core module (ssl.https + dkjson)
├── imapfilter-sort.lua                 # imapfilter entry point
├── config.example.lua                 # Reference config (copy to ~/.config/...)
├── README.md                          # User docs
├── plan.md                            # Project plan / todo
└── AGENTS.md                          # This file
```

User config lives at `~/.config/imapfilter-llm-sort/config.lua`.

## Verify

```bash
lua -e 'dofile("imapfilter-openai-classifier.lua")'   # must not error
lua -e 'dofile("imapfilter-sort.lua")'             # errors on IMAP connect (expected)
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

## Architecture

```
config.lua ──▶ imapfilter-sort.lua ──dofile()──▶ imapfilter-openai-classifier.lua
                                                               │
                                                    ssl.https.request()
                                                               │
                                                               ▼
                                                      OpenAI-compatible API
```

The classifier module is stateless between `:classify_email()` calls.

## Data flow per message

1. Fetch `From`, `Subject`, body from IMAP
2. Truncate fields to configurable limits
3. Build prompt from category descriptions in config
4. POST to LLM API (`/v1/responses` or `/v1/chat/completions`)
5. Parse JSON response with `dkjson.decode()`
6. Normalize category against `config.categories[].name` — mismatch → `""`

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
```

Runtime: imapfilter 2.8.5 links Lua 5.5.0 + OpenSSL3 (both Homebrew).
