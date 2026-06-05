# imapfilter OpenAI Email Sorting

First-cut local email sorter for imapfilter. It checks `INBOX` messages newer
than one day, asks an OpenAI-compatible endpoint for one category, and moves
only confident matches into existing mailboxes.

Possible categories:

- `coupon`: offers, coupons, solicitations, deals, sales, brand/store/restaurant
  marketing, and list mail trying to get you to buy something.
- `NewsL`: newsletters, magazines, newspapers, Substack, library notices,
  digests, and editorial/informational list mail.
- `Board`: automated notifications from social/community/account services such
  as Facebook, Yelp, Instagram, Zillow, LinkedIn, Nextdoor, or Reddit.
- empty string: leave in `INBOX`.

## Files

- `imapfilter-openai-classifier.lua`: reusable classifier module.
- `imapfilter-example.lua`: example imapfilter config fragment.

## Setup

Install imapfilter if needed:

```sh
brew install imapfilter
```

Edit `imapfilter-example.lua`:

- Set your IMAP server.
- Set your IMAP username.
- Confirm the destination mailboxes already exist and are named exactly
  `coupon`, `NewsL`, and `Board`.
- Replace `dofile("./imapfilter-openai-classifier.lua")` with an absolute path
  if you run imapfilter from another directory.

Run against OpenAI Responses API:

```sh
export OPENAI_API_KEY="..."
export IMAP_PASSWORD="..."
imapfilter -c imapfilter-example.lua
```

Run against an OpenAI-compatible Chat Completions endpoint:

```sh
export OPENAI_API_KEY="..."
export IMAP_PASSWORD="..."
export OPENAI_API_STYLE="chat"
export OPENAI_URL="http://localhost:1234/v1/chat/completions"
export OPENAI_MODEL="your-model"
imapfilter -c imapfilter-example.lua
```

Optional debug output:

```sh
export OPENAI_CLASSIFIER_DEBUG=1
```

## Notes

The classifier is intentionally conservative. If the model returns anything
other than `coupon`, `NewsL`, or `Board`, the message is left in `INBOX`.
