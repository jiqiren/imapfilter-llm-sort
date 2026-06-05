-- Example imapfilter config fragment.
--
-- Fill in the account details, mailbox names, and path to the classifier.
-- Run with:
--   OPENAI_API_KEY=... IMAP_PASSWORD=... imapfilter -c imapfilter-sort.lua
--
-- Configuration is loaded from ~/.config/imapfilter-llm-sort/config.lua
-- Override the path with OPENAI_CLASSIFIER_CONFIG.

local config_path = os.getenv("OPENAI_CLASSIFIER_CONFIG")
  or os.getenv("HOME") .. "/.config/imapfilter-llm-sort/config.lua"

local config = dofile(config_path)

local OpenAIEmailClassifier = dofile(
  os.getenv("HOME") .. "/proj/imapfilter-llm-sort/imapfilter-openai-classifier.lua"
)

local account = IMAP {
  server = config.imap.server,
  username = config.imap.username,
  password = config.imap.password,
  ssl = config.imap.ssl,
}

local classifier = OpenAIEmailClassifier.new({
  api_key = config.api.key,
  url = config.api.url,
  model = config.api.model,
  style = config.api.style,
  timeout_seconds = config.api.timeout_seconds,
  debug = config.api.debug,
  categories = config.categories,
  system_prompt = config.system_prompt,
  truncation = config.truncation,
})

local destinations = {}
for _, cat in ipairs(config.categories) do
  destinations[cat.name] = account[cat.mailbox]
end

local function fetch_first(mailbox, uid, field)
  local values = mailbox[uid]:fetch_field(field)

  if type(values) == "table" then
    return values[1] or ""
  end

  return values or ""
end

local moves = {}
for _, cat in ipairs(config.categories) do
  moves[cat.name] = Set {}
end

local function classify(mailbox, uid)
  local email = {
    from = fetch_first(mailbox, uid, "From"),
    subject = fetch_first(mailbox, uid, "Subject"),
    body = mailbox[uid]:fetch_body() or "",
  }

  return classifier:classify_email(email)
end

local inbox = account.INBOX
local recent = inbox:is_newer(config.imap.lookback_days)

for _, message in ipairs(recent) do
  local mailbox, uid = table.unpack(message)
  local category = classify(mailbox, uid)

  if moves[category] ~= nil then
    table.insert(moves[category], message)
  end
end

for category, messages in pairs(moves) do
  if #messages > 0 then
    messages:move_messages(destinations[category])
  end
end
