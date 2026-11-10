# The prompt cache

A model reads the whole conversation on every call. The provider keeps what it
read for a few minutes, and a later call that begins with the same words reads
them back from that cache: faster, and at about a tenth of the price. On an API
key a miss costs money; on a subscription it uses up the usage limit faster.

## How long it lasts

An hour from when it was last read, for Anthropic's models, renewed by every
call that reads it. Anthropic's default is five minutes; the sidecar asks for
an hour (pi's `cacheRetention: "long"`, `cacheRetention` in `agent/runtime.mjs`)
because a person's replies are often more than five minutes apart, and a lapsed
cache reads the whole thread again. Writing to an hour's cache costs twice the
input price instead of 1.25 times; reading costs the same tenth. The Claude
subscription honours it. Compaction asks for no cache and gets none.

OpenAI keeps its cache for a few minutes. `Message::PromptCache#cache_ttl`
holds the figure for each reply, by the model that made it: `LONG` for
Anthropic's, `SHORT` for anyone else's.

## What starts it over

The cache holds a prompt from its start, so a change near the start makes the
provider read everything after it again:

- the model, or its thinking level (`/model`, `/thinking`, the agent's settings);
- the agent's name, title, instructions, skills, channels or computer;
- its tools: switching one on or off, a connector's tools, and a tool found with
  "Look up when needed", which joins the list;
- its notes: the instructions list the newest notes (`Agent#notes_listing`), so a
  saved note changes them;
- a summary of earlier messages (`/compact`, or when the context fills).

## Tool changes keep the cache

A change to the agent's tools need not start the cache over: the sidecar adds
a new or changed tool after the ones the conversation already has, and the
rest of the thread is still read from the cache. Declared in another order,
every tool would be removed and declared again (pi-durable's `planTools`), and
Anthropic then drops the thread's earlier thinking and caches nothing, so the
next two requests read it all again. So:

- the sidecar keeps each conversation's tool order (`stableToolOrder` in
  `agent/runtime.mjs`, stored as pi-durable's `modelTools`), new and changed
  tools last;
- find_tools names only its connectors and use_tool lists every searchable
  tool, so neither declaration changes when a connector refreshes or a found
  tool is called.

## What the thread shows

- **Under a reply that missed:** "Cache missed: 84k tokens read again in full."
  and the likeliest reason: the cache had lapsed (and how long it had been),
  the model changed, or something the agent reads first changed. The count is
  what that reply read in full: its new words and those it wrote to the cache.
  After a summary the line says how far the prompt shrank: "Cache missed:
  earlier messages were summarised (252k → 61k); 38k new tokens read in full."
- **On the status line above the composer** (`conversations/_status_line`):
  nothing while the cache is warm. In its last five minutes (the last minute of
  a short cache), and once lapsed, it says what the next message will read
  again, counted down in the page. Hidden while the agent works, when the cache
  is in use.
- **In its Details:** how much of what the thread read came from the cache, and
  how long the cache stays warm.
- **In the composer's list:** `/model`, `/thinking` and `/compact` say they start
  the cache over.
- **On the agent's settings pages** that change what it reads first (General,
  Instructions, Skills, Tools, Channels, Computer): while the cache is warm, a
  note says a change starts it over and how much the next reply will read again.

## How a miss is told

When a reply is recorded (`Message#note_cache_miss`), it is compared with the
reply before it. If that one put at least 4,096 tokens in the cache and this one
read back less than half of them, it missed. The reason, in order:

1. a summary came between them;
2. the two replies ran on different models;
3. more time passed between their requests than the earlier reply's cache keeps;
4. otherwise, something the agent reads first changed.

Each reply is dated when its request began (`at` from the sidecar's `entryView`),
which is when its cache was read. A provider that caches nothing is never said
to miss.
