# AGENTS.md — imapfilter-llm-sort

## Project Overview

An LLM-powered email classifier for imapfilter. Scans recent INBOX messages,
sends them to an OpenAI-compatible API for categorization, and moves messages
into destination IMAP mailboxes based on the LLM's classification.

## Tech Stack

- **Runtime:** imapfilter 2.8.5 (Homebrew), Lua 5.5.0
- **HTTPS:** luasocket + luasec (via luarocks, Lua 5.5)
- **JSON:** dkjson (via luarocks, Lua 5.5)
- **System deps:** OpenSSL3, Lua 5.5 (both installed via Homebrew, linked by imapfilter)

## Files

```
imapfilter-llm-sort/
├── imapfilter-openai-classifier.lua   # Reusable classifier module
├── imapfilter-example.lua             # Example imapfilter config
├── README.md                          # User-facing docs
├── plan.md                            # This refactoring plan
└── AGENTS.md                          # This file
```

User configuration lives at `~/.config/imapfilter-llm-sort/config.lua`.

## Build / Install

```bash
brew install luarocks
luarocks --lua-version 5.5 install luasocket
luarocks --lua-version 5.5 install luasec
luarocks --lua-version 5.5 install dkjson
```

## Lint / Verify

No linting tool is configured yet. To verify the Lua syntax:

```bash
lua -e 'dofile("imapfilter-openai-classifier.lua")'   # must not error
lua -e 'dofile("imapfilter-example.lua")'             # will error on IMAP connect (expected)
```

To run a full integration test, the real imapfilter binary must be used:

```bash
OPENAI_API_KEY=... IMAP_PASSWORD=... OPENAI_CLASSIFIER_DEBUG=1 \
  imapfilter -c imapfilter-example.lua
```

## Conventions

- **Module style:** Table with `__index` metatable (OOP-ish), constructor via
  `.new(options)`, methods via `:methodName()`.
- **Error handling:** HTTP failures return empty string (`""`) for category so
  messages stay in INBOX (conservative). Connection errors log to stderr when
  debug mode is on.
- **Config:** All hardcoded values must be configurable via either the config
  file or environment variables. The only exception is internal defaults
  (e.g., temperature=0 for deterministic output).
- **No shell commands:** All external communication uses native Lua libraries
  (ssl.https, dkjson). No `io.popen`, `pipe_from`, or `pipe_to` for HTTP.
- **JSON:** Always use `dkjson.encode()` and `dkjson.decode()`. Never build
  JSON by string concatenation.

## Architecture

```
~/.config/imapfilter-llm-sort/config.lua  ──▶  imapfilter-example.lua
                                                     │
                                          dofile()    │
                                                     ▼
                                        imapfilter-openai-classifier.lua
                                                     │
                                          ssl.https   │
                                                     ▼
                                             OpenAI-compatible API
```

The classifier module is stateless between calls. Configuration is loaded once
at startup and passed to the module constructor.

## Key Design Decisions

1. **Conservative classification:** The LLM prompt instructs the model to return
   empty string when uncertain. Unknown categories default to `""` (leave in
   INBOX). This is intentional to prevent misfiling.

2. **Temperature=0:** Always request `temperature: 0` for deterministic,
   reproducible results.

3. **JSON response format:** Both API styles (Responses and Chat Completions)
   are told to return JSON objects. The `response_format` / `text.format`
   field enforces this on supporting servers.

4. **User message only (no system prompt in payload):** The system-level
   instructions are embedded in the user message for maximum compatibility
   with local/proxy servers that may not support system messages.
