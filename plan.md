# plan.md

## Done

- [x] Native Lua HTTPS (`luasec` + `luasocket`) — no shell
- [x] `dkjson` encode/decode — no regex JSON
- [x] Configurable categories via `config.lua`
- [x] Configurable prompts from category descriptions
- [x] Configurable IMAP settings
- [x] Responses API + Chat Completions API
- [x] Auto-detect `http://` vs `https://` from URL
- [x] `config.example.lua` in repo
- [x] Immediate moves (not bulk at end)
- [x] Per-message + summary stats (time, tokens)
- [x] SQLite classification cache (`dromozoa-sqlite3` + `md5`)
- [x] Cache-first fetch: `Message-Id` only, then check cache before fetching body
- [x] `macos-loop.zsh` infinite loop runner with CLI arg parsing
- [x] `AGENTS.md`, `README.md` updated

## Notes

- `classify_email()` now handles the full flow: cache check → model chain loop → cache write (`mark_sorting`/`update_done`/`mark_failed`).
- `imapfilter-sort.lua` `classify()` fetches email fields and passes them to `classify_email()` along with the cache instance.

## Planned

### Status Tracking + Model Escalation

- [x] 1. Update schema in `imapfilter-classifier-cache.lua` — add `status`, `failure_reason`, `updated_at` columns; write migration (ALTER TABLE ADD COLUMN)
- [x] 2. Add `cache:mark_sorting(hash, msg_id, model)` — `INSERT OR IGNORE` with `status='sorting'`
- [x] 3. Add `cache:update_done(hash, msg_id, model, tokens_in, tokens_out, destination)` — `UPDATE` to `status='done'`, set tokens/dest/updated_at
- [x] 4. Add `cache:mark_failed(hash, msg_id, model, reason)` — `UPDATE` to `status='failed'`, set failure_reason/updated_at
- [x] 5. Add `cache:get_stale_ids(status)` — `SELECT message_id FROM classifications WHERE status=?`
- [x] 6. Update `cache:lookup()` — add `AND status = 'done'` to WHERE clause
- [x] 7. Update `OpenAIEmailClassifier.new()` — accept `models` chain (comma-separated string → list of model names)
- [x] 8. Implement `classify_email()` model chain loop — try each model in order; escalate on `api_timeout`/`http_error`; no escalate on `parse_error`/IMAP failures
- [x] 9. Update `imapfilter-sort.lua` — parse comma-separated models from config/env, pass chain to classifier
- [x] 10. Update `imapfilter-sort.lua` — stale-row retry at startup (query `status='sorting'`, search INBOX, re-process through normal flow, delete if not found)
- [x] 11. Update `imapfilter-sort.lua` — restructure `classify()` to call `mark_sorting` before body fetch, handle failure reasons (done as part of item 8)
- [x] 12. Add `--folder` flag to `macos-loop.zsh` — support `INBOX`, `ALL`, or specific folder name
- [x] 13. Add `-m` flag to `macos-loop.zsh` — set `OPENAI_MODEL` (comma-separated)
- [x] 14. Update `config.example.lua` — show `model` as comma-separated list, document new flags
- [x] 15. Run verification checks (`lua -e 'dofile(...)'` for each module, `zsh -n macos-loop.zsh`)
- [x] 16. Fix `classify()` in `imapfilter-sort.lua` — fetch From/Subject/body only on cache miss (currently always fetched, wastes IMAP traffic for cached messages)

### Documentation

- [x] 21. Update `README.md` — document model escalation (comma-separated models) and stale row retry on crash
- [x] 24. Update `README.md` — document `--dry-run` / `OPENAI_CLASSIFIER_DRY_RUN`
- [x] 25. Update `README.md` env var table — add missing vars (`OPENAI_DELAY_BETWEEN_CALLS`, `OPENAI_RATE_LIMIT_MAX_RETRIES`, `OPENAI_RATE_LIMIT_INITIAL_DELAY`, `IMAP_FOLDER`, `IMAP_MAX_MSGS`)

### Cache Maintenance

- [ ] 17. Add SQLite cache cleanup — at startup, for each cached row verify the corresponding email still exists on IMAP; `DELETE` rows whose email is gone entirely
- [ ] 18. Add `cache:vacuum()` — run `VACUUM` after rotation to reclaim disk space
- [x] 27. Call `cache:close()` at end of `imapfilter-sort.lua` — proper cleanup (important for loop runner)

### Reliability

- [x] 19. Add configurable delay between API calls — prevent rate limit hits when processing large batches
- [x] 20. Add `--dry-run` flag — classify and log moves without actually moving messages
- [x] 22. Add exponential backoff on HTTP 429 (rate limit) — retry with increasing delay instead of failing
- [x] 23. Add `--max-msgs N` flag — cap messages per run (safety valve for `ALL` folder)
- [x] 26. Apply `--max-msgs` cap to stale retry loop — stale retries also need a safety valve
- [x] 28. Add signal handler to `macos-loop.zsh` — forward SIGINT/SIGTERM to child `imapfilter` and wait for clean exit (prevents DB corruption on `Ctrl+C`)
- [x] 29. Enable SQLite WAL mode in `ClassifierCache.new()` — better crash resilience for loop runner

### Correctness

- [ ] 30. Add basic unit tests — at minimum test `normalize_category()`, `truncate()`, `build_prompt()`, and `parse_response()` with various API response shapes
