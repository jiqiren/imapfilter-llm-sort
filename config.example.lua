-- User configuration for imapfilter-llm-sort.
--
-- Copy or symlink this file to ~/.config/imapfilter-llm-sort/config.lua
-- All values fall back to environment variables, so most can be omitted.
--
-- For looped execution, use macos-loop.zsh (run `macos-loop.zsh -h` for flags):
--   -s SECONDS   Sleep between runs (default: 300)
--   -m MODEL     Model name or comma-separated list for escalation
--   -U URL       OpenAI-compatible API URL
--   -S HOST      IMAP server hostname
--   -u USER      IMAP username
--   -k KEY       API key
--   -d           Enable debug output
--   -f FOLDER    IMAP folder to process (default: INBOX). Use ALL for all folders
--   -n           Dry-run: classify and log without moving messages
--   --delay SECS  Seconds between API calls (default: 0, i.e. no delay)

return {
  api = {
    -- OpenAI-compatible endpoint. Set OPENAI_URL to override.
    url = os.getenv("OPENAI_URL") or "https://api.openai.com/v1/responses",

    -- API key. REQUIRED unless your endpoint ignores auth.
    key = os.getenv("OPENAI_API_KEY"),

    -- Model name or comma-separated list of models for escalation.
    -- When multiple models are listed, the classifier tries them in order.
    -- On API timeout or HTTP error, it escalates to the next model.
    -- On parse errors or IMAP failures, it does NOT escalate (conservative).
    -- Set OPENAI_MODEL to override (e.g. "qwen/qwen3-4b-2507,google/gemma-4-12b").
    -- Use -m flag in macos-loop.zsh for the same.
    model = os.getenv("OPENAI_MODEL") or "qwen/qwen3-4b-2507,google/gemma-4-12b",

    -- API style: "responses" (OpenAI /v1/responses) or "chat" (/v1/chat/completions).
    style = os.getenv("OPENAI_API_STYLE") or "responses",

    -- HTTP timeout in seconds.
    timeout_seconds = tonumber(os.getenv("OPENAI_TIMEOUT_SECONDS")) or 600,

    -- Seconds to wait between API calls (0 = no delay).
    -- Prevents rate limit hits when processing large batches.
    -- Set OPENAI_DELAY_BETWEEN_CALLS to override (e.g. "2" for 2 seconds).
    -- Use --delay flag in macos-loop.zsh for the same.
    delay_between_calls = tonumber(os.getenv("OPENAI_DELAY_BETWEEN_CALLS")) or 0,

    -- When the API returns HTTP 429 (rate limited), retry with exponential
    -- backoff before escalating to the next model or giving up.
    -- Set OPENAI_RATE_LIMIT_MAX_RETRIES to override (default: 3).
    rate_limit_max_retries = tonumber(os.getenv("OPENAI_RATE_LIMIT_MAX_RETRIES")) or 3,

    -- Initial backoff delay in seconds for rate limit retries.
    -- Each subsequent retry doubles this delay (5s, 10s, 20s, ...).
    -- Set OPENAI_RATE_LIMIT_INITIAL_DELAY to override (default: 5).
    rate_limit_initial_delay = tonumber(os.getenv("OPENAI_RATE_LIMIT_INITIAL_DELAY")) or 5,

    -- Verbose logging to stderr.
    debug = os.getenv("OPENAI_CLASSIFIER_DEBUG") == "1",

    -- Dry-run mode: classify messages and log what would happen,
    -- but do NOT move messages or write to the cache.
    -- Set OPENAI_CLASSIFIER_DRY_RUN=1 to enable.
    -- Use -n flag in macos-loop.zsh for the same.
    dry_run = os.getenv("OPENAI_CLASSIFIER_DRY_RUN") == "1",
  },

  -- Classification categories. Each entry maps a category name (returned by the
  -- LLM) to an IMAP mailbox. Messages that don't match any category stay in INBOX.
  categories = {
    {
      name = "coupon",
      mailbox = "coupon",
      description = "offers, coupons, solicitations, deals, sales, promotions, "
        .. "product marketing, restaurant/retail/app offers, or list mail "
        .. "primarily trying to get the user to buy something. "
        .. "Examples: Starbucks, Subway, Levi's, stores, restaurants, brands, marketplaces.",
    },
    {
      name = "NewsL",
      mailbox = "NewsL",
      description = "newsletters, magazines, newspapers, Substack, library notices, "
        .. "digests, editorial updates, publication roundups, reading lists, and "
        .. "informational list mail.",
    },
    {
      name = "Board",
      mailbox = "Board",
      description = "automated notifications from social, community, marketplace, "
        .. "real estate, reputation, career, or account-based services. "
        .. "Examples: Facebook, Yelp, Instagram, Zillow, LinkedIn, Nextdoor, Reddit, "
        .. "social network alerts, connection/profile/comment/follow/review notifications.",
    },
    {
      name = "Finacial",
      mailbox = "Finance",
      description = "automated emails from banks, brokers, IRA, 401k, HSA, checking,"
        .. "savings accounts, loans, etc. could be a transaction for a loan, trading, or funding"
        .. "an account. Examples: Statements, payment recieved, account alert, low balance,"
        .. "payment due, withdrawls, deposits, dividend notifications etc.",
    },
    {
      name = "Money",
      mailbox = "Money",
      description = "Investment opportunities, mailing lists focusing on stocks, bonds, real "
        .. "estate, crypto, or privately traded companies or funds. this can include invitations"
        .. "to events, webinars, calls, email subscriptions, and other educational products or"
        .. "activities to invest and grow wealth.",
    },
    {
      name = "Travel",
      mailbox = "Travel",
      description = "this is basically the same as coupon except anything that has to do with travel."
        .. "For example: Airline, hotel, car rental, cruise, train, hostel, camping, and safari."
        .. "NOT for actual booking, payment, or reservation acknowlegement.",
    },
  },

  -- System-level instructions sent to the LLM.
  system_prompt = "You sort emails into existing IMAP mailboxes. "
    .. "You are conservative and return valid JSON only.",

  -- Maximum character counts for email fields in the prompt.
  -- Longer values are truncated to avoid overly large API payloads.
  truncation = {
    from = 1000,
    subject = 1000,
    body = 12000,
  },

  -- IMAP account settings. Used by the example config.
  imap = {
    server = os.getenv("IMAP_SERVER") or "imap.example.com",
    username = os.getenv("IMAP_USER") or "you@example.com",
    password = os.getenv("IMAP_PASSWORD"),
    ssl = os.getenv("IMAP_SSL") or "tls1.2",

    -- Which folder to process. Default: "INBOX".
    -- Use "ALL" to process every folder (skips [Gmail] system folders).
    -- Use any folder name like "Work" or "Archive" to process a specific folder.
    -- Set IMAP_FOLDER env var or use -f flag in macos-loop.zsh to override.
    folder = os.getenv("IMAP_FOLDER") or "INBOX",

    -- How many days back to look for messages.
    lookback_days = tonumber(os.getenv("IMAP_LOOKBACK_DAYS")) or 1,

    -- Alternatively, a specific date (e.g. "2026-06-01"). Only messages from
    -- that single day are processed. Takes precedence over lookback_days.
    lookback_day = os.getenv("IMAP_LOOKBACK_DAY"),

    -- Maximum messages to process per run (0 = no limit). Safety valve for
    -- ALL folder mode to avoid runaway API costs.
    -- Set IMAP_MAX_MSGS to override (e.g. "50").
    -- Use -M flag in macos-loop.zsh for the same.
    max_msgs = tonumber(os.getenv("IMAP_MAX_MSGS")) or 0,
  },

  -- Optional SQLite cache for classification results.
  -- Skips API calls for emails already classified with the same config.
  -- Cache key includes config_hash + Message-Id + model, so changing the
  -- model or categories will re-classify messages.
  -- Stale rows (status='sorting') from a crashed run are retried at startup.
  sqlite = {
    path = os.getenv("OPENAI_CLASSIFIER_CACHE") or nil,
  },
}
