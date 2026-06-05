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

Most values can also be set via environment variables (`IMAP_SERVER`,
`IMAP_USER`, `IMAP_PASSWORD`, `IMAP_SSL`, `IMAP_LOOKBACK_DAYS`).

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
