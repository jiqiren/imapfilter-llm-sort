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
  -U, --openai-url URL   OpenAI-compatible API URL (default: http://127.0.0.1:8080/v1/responses)
  -m, --model MODEL      Model name (default: google/gemma-4-12b)
  -k, --api-key KEY      API key (default: nope)
  -d, --debug            Enable debug output
  -h, --help             Show this help message

Environment variables are also respected (OPENAI_URL, OPENAI_MODEL,
OPENAI_API_KEY, OPENAI_CLASSIFIER_DEBUG, IMAP_SERVER, IMAP_USER).
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
  {k,-api-key}:=API_KEY_OPT \
  {d,-debug}=DEBUG_OPT \
  {h,-help}=HELP_OPT \
  || usage

[[ -n $HELP_OPT ]] && usage

export OPENAI_URL="${OPENAI_URL_OPT[-1]:-${OPENAI_URL:-http://127.0.0.1:8080/v1/responses}}"
export OPENAI_MODEL="${MODEL_OPT[-1]:-${OPENAI_MODEL:-google/gemma-4-12b}}"
export OPENAI_API_KEY="${API_KEY_OPT[-1]:-${OPENAI_API_KEY:-nope}}"
if [[ -n $DEBUG_OPT ]]; then
  export OPENAI_CLASSIFIER_DEBUG=1
else
  export OPENAI_CLASSIFIER_DEBUG="${OPENAI_CLASSIFIER_DEBUG:-0}"
fi
export IMAP_SERVER="${IMAP_SERVER_OPT[-1]:-${IMAP_SERVER:-imap.example.com}}"
export IMAP_USER="${IMAP_USER_OPT[-1]:-${IMAP_USER:-user@example.com}}"
#export IMAP_PASSWORD="$(security find-generic-password -a ${USER} -s gmailsecret -w)"

SLEEP_SECONDS="${SLEEP_OPT[-1]:-300}"

export IMAPFILTERCFG="${0:A:h}/imapfilter-sort.lua"

if [[ ! -f $IMAPFILTERCFG ]]; then
  echo "no ${IMAPFILTERCFG} to filter mail... exiting!" >&2
  exit 1
fi

while true; do
  imapfilter -c "${IMAPFILTERCFG}"
  sleep "${SLEEP_SECONDS}"
done
