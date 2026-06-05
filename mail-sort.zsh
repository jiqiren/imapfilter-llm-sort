#!/bin/zsh

#https://imapsync.lamiral.info/FAQ.d/FAQ.Gmail.txt

set -x

export OPENAI_URL="http://localhost:8080/v1/responses"
export OPENAI_MODEL="google/gemma-4-12b"
export OPENAI_API_KEY="nope"
export IMAP_SERVER="imap.gmail.com"
export IMAP_USER="driver@megahappy.net"
export IMAP_PASSWORD="`security find-generic-password -a ${USER} -s gmailsecret -w`"
export IMAPFILTERCFG="${HOME}/proj/imapfilter-llm-sort/imapfilter-sort.lua"
if [ ! -f ${IMAPFILTERCFG} ]; then
	echo "no ${IMAPFILTERCFG} to filter mail... exiting!"
	exit
fi
imapfilter -v -c ${IMAPFILTERCFG}
