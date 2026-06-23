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
  models = config.api.model,
  style = config.api.style,
  timeout_seconds = config.api.timeout_seconds,
  delay_between_calls = config.api.delay_between_calls,
  dry_run = config.api.dry_run,
  debug = config.api.debug,
  categories = config.categories,
  system_prompt = config.system_prompt,
  truncation = config.truncation,
})

local ClassifierCache = dofile(
  os.getenv("HOME") .. "/proj/imapfilter-llm-sort/imapfilter-classifier-cache.lua"
)

local dry_run = config.api.dry_run == true or config.api.dry_run == "1"
local cache_path = (config.sqlite and config.sqlite.path)
  or os.getenv("HOME") .. "/.config/imapfilter-llm-sort/classifications.db"
local cache = ClassifierCache.new({ path = cache_path })

if config.api.debug then
  io.stderr:write("Cache: " .. cache_path .. "\n")
end

if dry_run then
  io.stderr:write("DRY RUN — messages will be classified but NOT moved\n")
end

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
  local message_id = fetch_first(mailbox, uid, "Message-Id")

  io.stderr:write(string.format("  %s\n", message_id))

  -- Cache-first: check with Message-Id only, avoid fetching body on cache hit
  local cached = classifier:check_cache(message_id, cache)
  if cached then
    return cached.destination, cached.tokens_in, cached.tokens_out
  end

  -- Cache miss — fetch From/Subject/body for classification
  local from = fetch_first(mailbox, uid, "From")
  local subject = fetch_first(mailbox, uid, "Subject")
  local body = mailbox[uid]:fetch_body() or ""

  io.stderr:write(string.format("  %s\n  %s\n", from, subject))

  local email = { from = from, subject = subject, body = body }

  return classifier:classify_email(email, message_id, cache, cached)
end

local inbox = account.INBOX

-- Determine which folder(s) to process
local folder = os.getenv("IMAP_FOLDER") or (config.imap and config.imap.folder) or "INBOX"
folder = folder:upper()

local function get_recent_set(mailbox)
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
  local recent = mailbox:is_newer(lookback_days)
  if next_day_days and next_day_days > 0 then
    recent = recent - mailbox:is_newer(next_day_days)
  end
  return recent
end

-- Build list of mailboxes to process
local mailboxes_to_process = {}
if folder == "ALL" then
  local all_mailboxes = account:ls()
  for _, mb_name in ipairs(all_mailboxes) do
    -- Skip special/system folders
    if mb_name ~= "[Gmail]" and mb_name ~= "[Gmail]/All Mail" then
      local mb = account[mb_name]
      if mb then
        table.insert(mailboxes_to_process, { name = mb_name, mailbox = mb })
      end
    end
  end
else
  local mb_name = folder == "INBOX" and "INBOX" or folder
  local mb = account[mb_name]
  if mb then
    table.insert(mailboxes_to_process, { name = mb_name, mailbox = mb })
  else
    io.stderr:write(string.format("Warning: folder '%s' not found, processing INBOX\n", folder))
    table.insert(mailboxes_to_process, { name = "INBOX", mailbox = inbox })
  end
end

-- Retry stale rows from a previous run (only for INBOX — can't know folder for ALL)
-- Skip in dry-run mode (stale retry involves actual moves)
if not dry_run and folder == "INBOX" then
  local stale_ids = cache:get_stale_ids_for_config(classifier.config_hash, "sorting")
  if #stale_ids > 0 then
    io.stderr:write(string.format("Retrying %d stale message(s) from previous run...\n", #stale_ids))
    for _, msg_id in ipairs(stale_ids) do
      local found = inbox:contains({ uid = msg_id })
      if #found > 0 then
        local uid = found[1][2]
        local category, _, _ = classify(inbox, uid)
        if moves[category] ~= nil then
          io.stderr:write(string.format("  Stale retry: %s → %s\n", msg_id, category))
          if not dry_run then
            inbox:move_messages(destinations[category], { found[1] })
          end
        else
          io.stderr:write(string.format("  Stale retry: %s → INBOX (no match)\n", msg_id))
        end
      else
        io.stderr:write(string.format("  Stale cleanup: %s (no longer in INBOX)\n", msg_id))
        cache:delete_row(classifier.config_hash, msg_id)
      end
    end
    io.stderr:write("Stale retry complete.\n")
  end
end

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
local max_msgs = tonumber(config.imap and config.imap.max_msgs) or 0
local processed = 0

for _, mb_info in ipairs(mailboxes_to_process) do
  -- Stop processing more mailboxes if we've hit the cap
  if max_msgs > 0 and processed >= max_msgs then
    io.stderr:write(string.format("Max messages reached (%d), stopping.\n", max_msgs))
    break
  end
  local mailbox = mb_info.mailbox
  local mb_name = mb_info.name
  local recent = get_recent_set(mailbox)

  io.stderr:write(string.format("imapfilter-llm-sort: processing %d messages in %s\n", #recent, mb_name))

  local n = 0
  for i = #recent, 1, -1 do
    -- Safety valve: cap total messages processed across all folders
    if max_msgs > 0 and processed >= max_msgs then
      io.stderr:write(string.format("Max messages reached (%d), stopping.\n", max_msgs))
      break
    end
    n = n + 1
    processed = processed + 1
    local uid = recent[i][2]
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
      if not dry_run then
        mailbox:move_messages(destinations[category], { recent[i] })
      end
      moved = moved + 1
    end
  end
end

local total_elapsed = socket.gettime() - start_time
io.stderr:write(string.format(
  "Summary: %d classified, %d moved, %.1fs total\n",
  classified, moved, total_elapsed
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
