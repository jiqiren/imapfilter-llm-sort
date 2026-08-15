#!/bin/zsh

set -e

typeset -r SCRIPT_NAME="$0"

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Run imapfilter-llm-sort in a loop.

Options:
  -s, --sleep SECONDS    Seconds between runs (default: 300, i.e. 5 minutes)
  -S, --imap-server HOST IMAP server hostname (default: imap.example.com)
  -u, --imap-user USER   IMAP username (default: user@example.com)
  -U, --openai-url URL   OpenAI-compatible API URL (default: http://127.0.0.1:1234/v1/responses)
  -m, --model MODEL      Model name (default: google/gemma-4-12b)
  -A, --api-style STYLE  API style: "responses" or "chat" (default: responses)
  -k, --api-key KEY      API key (default: nope)
  -D, --delay SECONDS    Seconds between API calls (default: 0)
  -f, --folder FOLDER    IMAP folder to process (default: INBOX). Use ALL for all folders
  -M, --max-msgs N       Maximum messages to process per run (0 = no limit)
  -n, --dry-run          Classify and log without moving messages
  -d, --debug            Enable debug output
  -h, --help             Show this help message

Environment variables are also respected (OPENAI_URL, OPENAI_API_STYLE,
OPENAI_MODEL, OPENAI_API_KEY, OPENAI_CLASSIFIER_DEBUG, IMAP_SERVER, IMAP_USER).
Command-line options take precedence.
EOF
  exit 0
}

zmodload zsh/zutil
zparseopts -D -E -F -- \
  {s,-sleep}:=SLEEP \
  {S,-imap-server}:=IMAP_SERVER_OPT \
  {u,-imap-user}:=IMAP_USER_OPT \
  {U,-openai-url}:=OPENAI_URL_OPT \
  {m,-model}:=MODEL_OPT \
  {A,-api-style}:=API_STYLE_OPT \
  {k,-api-key}:=API_KEY_OPT \
  {D,-delay}:=DELAY_OPT \
  {f,-folder}:=FOLDER_OPT \
  {M,-max-msgs}:=MAX_MSGS_OPT \
  {n,-dry-run}=DRY_RUN_OPT \
  {d,-debug}=DEBUG_OPT \
  {h,-help}=HELP_OPT \
  || usage

[[ -n $HELP_OPT ]] && usage

export OPENAI_URL="${OPENAI_URL_OPT[-1]:-${OPENAI_URL:-http://127.0.0.1:1234/v1/responses}}"
export OPENAI_MODEL="${MODEL_OPT[-1]:-${OPENAI_MODEL:-google/gemma-4-12b}}"
export OPENAI_API_STYLE="${API_STYLE_OPT[-1]:-${OPENAI_API_STYLE:-responses}}"
export OPENAI_API_KEY="${API_KEY_OPT[-1]:-${OPENAI_API_KEY:-nope}}"
export OPENAI_DELAY_BETWEEN_CALLS="${DELAY_OPT[-1]:-${OPENAI_DELAY_BETWEEN_CALLS:-0}}"
if [[ -n $DEBUG_OPT ]]; then
  export OPENAI_CLASSIFIER_DEBUG=1
else
  export OPENAI_CLASSIFIER_DEBUG="${OPENAI_CLASSIFIER_DEBUG:-0}"
fi
export IMAP_SERVER="${IMAP_SERVER_OPT[-1]:-${IMAP_SERVER:-imap.example.com}}"
export IMAP_USER="${IMAP_USER_OPT[-1]:-${IMAP_USER:-user@example.com}}"
export IMAP_FOLDER="${FOLDER_OPT[-1]:-${IMAP_FOLDER:-INBOX}}"
export IMAP_MAX_MSGS="${MAX_MSGS_OPT[-1]:-${IMAP_MAX_MSGS:-0}}"
if [[ -n $DRY_RUN_OPT ]]; then
  export OPENAI_CLASSIFIER_DRY_RUN=1
else
  export OPENAI_CLASSIFIER_DRY_RUN="${OPENAI_CLASSIFIER_DRY_RUN:-0}"
fi
#export IMAP_PASSWORD="$(security find-generic-password -a ${USER} -s gmailsecret -w)"

SLEEP_SECONDS="${SLEEP[-1]:-300}"

export IMAPFILTERCFG="${0:A:h}/imapfilter-sort.lua"

if [[ ! -f $IMAPFILTERCFG ]]; then
  echo "no ${IMAPFILTERCFG} to filter mail... exiting!" >&2
  exit 1
fi

# Signal handler: forward SIGINT/SIGTERM to child process and wait for clean exit
# Prevents SQLite DB corruption from abrupt termination
typeset running_pid=""

forward_signal() {
  if [[ -n $running_pid ]] then
    kill "$running_pid" 2>/dev/null
    wait "$running_pid" 2>/dev/null
  fi
  exit 0
}

trap forward_signal INT TERM

# Print a live countdown (M:SS) to stderr, updating once per second.
countdown() {
  local remaining=$1
  while (( remaining > 0 )); do
    printf '\rnext run in %d:%02d   ' $(( remaining / 60 )) $(( remaining % 60 )) >&2
    sleep 1
    remaining=$(( remaining - 1 ))
  done
  printf '\n' >&2
}

while true; do
  imapfilter -c "${IMAPFILTERCFG}" &
  running_pid=$!
  if ! wait "$running_pid"; then
    rc=$?
    running_pid=""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] imapfilter exited with code $rc — retrying after sleep" >&2
  else
    running_pid=""
  fi

  countdown "${SLEEP_SECONDS}"
done
