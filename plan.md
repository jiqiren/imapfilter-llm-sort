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

## Planned

### Status Tracking + Model Escalation

- [ ] 1. Update schema in `imapfilter-classifier-cache.lua` — add `status`, `failure_reason`, `updated_at` columns; write migration (rename old → create new → copy as `done` → drop old)
- [ ] 2. Add `cache:mark_sorting(hash, msg_id, model)` — `INSERT OR IGNORE` with `status='sorting'`
- [ ] 3. Add `cache:update_done(hash, msg_id, model, tokens_in, tokens_out, destination)` — `UPDATE` to `status='done'`, set tokens/dest/updated_at
- [ ] 4. Add `cache:mark_failed(hash, msg_id, model, reason)` — `UPDATE` to `status='failed'`, set failure_reason/updated_at
- [ ] 5. Add `cache:get_stale_ids(status)` — `SELECT message_id FROM classifications WHERE status=?`
- [ ] 6. Update `cache:lookup()` — add `AND status = 'done'` to WHERE clause
- [ ] 7. Update `OpenAIEmailClassifier.new()` — accept `models` chain (comma-separated string → list of model names)
- [ ] 8. Implement `classify_email()` model chain loop — try each model in order; escalate on `api_timeout`/`http_error`; no escalate on `parse_error`/IMAP failures
- [ ] 9. Update `imapfilter-sort.lua` — parse comma-separated models from config/env, pass chain to classifier
- [ ] 10. Update `imapfilter-sort.lua` — stale-row retry at startup (query `status='sorting'`, search INBOX, re-process through normal flow, delete if not found)
- [ ] 11. Update `imapfilter-sort.lua` — restructure `classify()` to call `mark_sorting` before body fetch, handle failure reasons
- [ ] 12. Add `--folder` flag to `macos-loop.zsh` — support `INBOX`, `ALL`, or specific folder name
- [ ] 13. Add `-m` flag to `macos-loop.zsh` — set `OPENAI_MODEL` (comma-separated)
- [ ] 14. Update `config.example.lua` — show `model` as comma-separated list, document new flags
- [ ] 15. Run verification checks (`lua -e 'dofile(...)'` for each module, `zsh -n macos-loop.zsh`)
