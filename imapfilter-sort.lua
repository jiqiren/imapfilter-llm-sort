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

local socket = require("socket")

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
  local from = fetch_first(mailbox, uid, "From")
  local subject = fetch_first(mailbox, uid, "Subject")
  local body = mailbox[uid]:fetch_body() or ""

  io.stderr:write(string.format("  %s\n  %s\n", from, subject))

  local email = { from = from, subject = subject, body = body }

  return classifier:classify_email(email)
end

local inbox = account.INBOX
local lookback_days = config.imap.lookback_days or 1
local next_day_days = nil
if config.imap.lookback_day and config.imap.lookback_day ~= "" then
  local y, m, d = config.imap.lookback_day:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if y then
    local target = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
    local next_day = target + 86400
    local now = os.time()
    lookback_days = math.max(1, math.ceil((now - target) / 86400))
    next_day_days = math.max(0, math.ceil((now - next_day) / 86400))
  end
end
local recent = inbox:is_newer(lookback_days)
if next_day_days and next_day_days > 0 then
  recent = recent - inbox:is_newer(next_day_days)
end

io.stderr:write("imapfilter-llm-sort: processing " .. #recent .. " messages\n")

local total_time = 0
local min_time = math.huge
local max_time = 0
local total_input = 0
local total_output = 0
local min_input = math.huge
local max_input = 0
local min_output = math.huge
local max_output = 0
local classified = 0
local moved = 0
local start_time = socket.gettime()

local n = 0
for i = #recent, 1, -1 do
  n = n + 1
  local mailbox, uid = table.unpack(recent[i])
  local t0 = socket.gettime()
  local category, input_tokens, output_tokens = classify(mailbox, uid)
  local elapsed = socket.gettime() - t0

  total_time = total_time + elapsed
  total_input = total_input + input_tokens
  total_output = total_output + output_tokens

  if elapsed > 0 then
    if elapsed < min_time then min_time = elapsed end
    if elapsed > max_time then max_time = elapsed end
  end
  if input_tokens > 0 then
    if input_tokens < min_input then min_input = input_tokens end
    if input_tokens > max_input then max_input = input_tokens end
  end
  if output_tokens > 0 then
    if output_tokens < min_output then min_output = output_tokens end
    if output_tokens > max_output then max_output = output_tokens end
  end

  local label = category ~= "" and category or "INBOX"
  io.stderr:write(string.format(
    "  [%d/%d] %.1fs in:%d out:%d → %s\n",
    n, #recent, elapsed, input_tokens, output_tokens, label
  ))

  if moves[category] ~= nil then
    classified = classified + 1
    mailbox:move_messages(destinations[category], { recent[i] })
    moved = moved + 1
  end
end

local total_elapsed = socket.gettime() - start_time
io.stderr:write(string.format(
  "Summary: %d msgs, %d classified, %d moved, %.1fs total\n",
  #recent, classified, moved, total_elapsed
))
if classified > 0 then
  local avg_time = total_time / classified
  local avg_input = total_input / classified
  local avg_output = total_output / classified
  if min_time == math.huge then min_time = 0 end
  if min_input == math.huge then min_input = 0 end
  if min_output == math.huge then min_output = 0 end
  io.stderr:write(string.format(
    "Classify time (s): min=%.1f max=%.1f avg=%.1f\n",
    min_time, max_time, avg_time
  ))
  io.stderr:write(string.format(
    "Input tokens:     min=%d max=%d avg=%.0f total=%d\n",
    min_input, max_input, avg_input, total_input
  ))
  io.stderr:write(string.format(
    "Output tokens:    min=%d max=%d avg=%.0f total=%d\n",
    min_output, max_output, avg_output, total_output
  ))
end
