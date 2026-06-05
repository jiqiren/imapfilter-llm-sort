-- OpenAI-compatible email classifier for imapfilter.
--
-- Dependencies (install once):
--   brew install luarocks
--   luarocks --lua-version 5.5 install luasocket
--   luarocks --lua-version 5.5 install luasec
--   luarocks --lua-version 5.5 install dkjson
--
-- Usage from your imapfilter config:
--
--   local classifier = require_classifier({
--     api_key = os.getenv("OPENAI_API_KEY"),
--     categories = { { name = "coupon", ... }, ... },
--   })
--
--   local category = classifier:classify_email({
--     from = from,
--     subject = subject,
--     body = body,
--   })

local https = require("ssl.https")
local ltn12 = require("ltn12")
local http = require("socket.http")
local dkjson = require("dkjson")

local OpenAIEmailClassifier = {}
OpenAIEmailClassifier.__index = OpenAIEmailClassifier

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function truncate(value, max_len)
  value = tostring(value or "")
  max_len = max_len or 12000

  if #value <= max_len then
    return value
  end

  return value:sub(1, max_len) .. "\n\n[truncated]"
end

local function build_prompt(email, config)
  local t = config.truncation or {}
  local from = truncate(email.from, t.from or 1000)
  local subject = truncate(email.subject, t.subject or 1000)
  local body = truncate(email.body, t.body or 12000)

  local lines = {
    "Classify this individual email into exactly one destination mailbox.",
    "",
    'Return only a compact JSON object with this exact shape:',
    '{"category":"category_name|","confidence":0.0,"reason":"short reason"}',
    "",
    "Categories:",
  }

  local category_names = {}
  for _, cat in ipairs(config.categories or {}) do
    table.insert(lines, "- " .. cat.name .. ": " .. (cat.description or cat.name))
    table.insert(category_names, cat.name)
  end

  table.insert(lines, "")
  table.insert(
    lines,
    '- empty string: use "" when uncertain, personal mail, transactional '
    .. "receipts, security alerts, bills, banking, shipping, calendar, "
    .. "work, family, or anything that does not clearly match the "
    .. #(config.categories or {}) .. " defined categories."
  )
  table.insert(lines, "")
  table.insert(lines, "Conservative rule: when in doubt, category must be empty string.")
  table.insert(lines, "")
  table.insert(lines, "Email:")
  table.insert(lines, "From: " .. from)
  table.insert(lines, "Subject: " .. subject)
  table.insert(lines, "Body:")
  table.insert(lines, body)

  return table.concat(lines, "\n")
end

local function build_payload(config, prompt)
  local system_prompt = config.system_prompt
    or "You sort emails into existing IMAP mailboxes. "
    .. "You are conservative and return valid JSON only."

  if config.style == "chat" then
    return dkjson.encode({
      model = config.model,
      messages = {
        { role = "system", content = system_prompt },
        { role = "user", content = prompt },
      },
      temperature = 0,
      response_format = { type = "json_object" },
    })
  end

  return dkjson.encode({
    model = config.model,
    input = {
      { role = "system", content = system_prompt },
      { role = "user", content = prompt },
    },
    temperature = 0,
    text = { format = { type = "json_object" } },
  })
end

local function normalize_category(category, valid_names)
  category = trim(category or "")

  if category == "" then
    return ""
  end

  for _, name in ipairs(valid_names) do
    if category == name then
      return name
    end
  end

  return ""
end

local function parse_response(raw, valid_names)
  if not raw or raw == "" then
    return ""
  end

  local ok, parsed = pcall(dkjson.decode, raw)
  if not ok or not parsed then
    return ""
  end

  local body = parsed
  if type(body) ~= "table" then
    return ""
  end

  local function extract_text_from_choices(obj)
    local choices = obj.choices
    if type(choices) == "table" and #choices > 0 then
      local message = choices[1].message
      if type(message) == "table" then
        return message.content
      end
    end
    return nil
  end

  local function extract_text_from_output(obj)
    local output = obj.output
    if type(output) ~= "table" then
      return nil
    end
    for _, item in ipairs(output) do
      if type(item) == "table" and item.type == "message" then
        local content = item.content
        if type(content) == "table" and #content > 0 then
          return content[1].text
        end
      end
    end
    return nil
  end

  local function strip_markdown_fences(text)
    if not text then return nil end
    text = text:gsub("^```[%w]*%s*\n", "")
    text = text:gsub("\n```%s*$", "")
    return text
  end

  local text = body.output_text or body.text or body.content
    or extract_text_from_choices(body)
    or extract_text_from_output(body)

  if text and type(text) == "string" then
    text = strip_markdown_fences(text)
    local ok2, nested = pcall(dkjson.decode, text)
    if ok2 and type(nested) == "table" and nested.category then
      return normalize_category(nested.category, valid_names)
    end
  end

  if body.category then
    return normalize_category(body.category, valid_names)
  end

  return ""
end

function OpenAIEmailClassifier.new(options)
  options = options or {}

  local self = {
    api_key = options.api_key,
    url = options.url,
    model = options.model,
    style = options.style or "responses",
    timeout = tonumber(options.timeout_seconds) or 600,
    debug = options.debug or false,
    categories = options.categories or {},
    system_prompt = options.system_prompt,
    truncation = options.truncation or { from = 1000, subject = 1000, body = 12000 },
  }

  return setmetatable(self, OpenAIEmailClassifier)
end

function OpenAIEmailClassifier:classify_email(email)
  if not self.api_key or self.api_key == "" then
    error("OPENAI_API_KEY is required for email classification")
  end

  local prompt = build_prompt(email or {}, {
    categories = self.categories,
    truncation = self.truncation,
  })
  local payload = build_payload({
    model = self.model,
    style = self.style,
    system_prompt = self.system_prompt,
  }, prompt)

  http.TIMEOUT = self.timeout

  if self.debug then
    io.stderr:write(string.format(
      "OpenAI classifier: calling %s (%s, %d bytes)\n",
      self.url, self.model, #payload
    ))
  end

  local response_body = {}
  local request_params = {
    url = self.url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. self.api_key,
      ["Content-Length"] = #payload,
    },
    source = ltn12.source.string(payload),
    sink = ltn12.sink.table(response_body),
  }

  local use_tls = self.url:sub(1, 8) == "https://"
  if use_tls then
    request_params.protocol = "tlsv1_2"
  end

  local request_fn = use_tls and https.request or http.request
  local ok, code, headers, status_line = request_fn(request_params)

  if self.debug then
    io.stderr:write("OpenAI classifier: ok=" .. tostring(ok) .. " code=" .. tostring(code) .. " status=" .. tostring(status_line) .. "\n")
  end

  if not ok then
    if self.debug then
      io.stderr:write("OpenAI classifier: request failed: " .. tostring(code) .. "\n")
    end
    return ""
  end

  local raw = table.concat(response_body)

  if self.debug then
    io.stderr:write("OpenAI classifier response:\n" .. raw .. "\n")
  end

  local code_num = tonumber(code)

  if not code_num or code_num < 200 or code_num >= 300 then
    if self.debug then
      io.stderr:write("OpenAI classifier HTTP error: " .. tostring(code) .. "\n")
    end
    return ""
  end

  local valid_names = {}
  for _, cat in ipairs(self.categories) do
    table.insert(valid_names, cat.name)
  end

  return parse_response(raw, valid_names)
end

return OpenAIEmailClassifier
