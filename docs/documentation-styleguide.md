**Documentation Rules and Guidelines**

**Context**

- [decisions.md](http://decisions.md) is for documenting explicit design decisions that may not be intuitive at first glance; it's not a log for work we've done in the past.
- sometimes the original author did not have full context when drafting the first pass at documentation; it's ok to clean things up when concepts become more clear

**Code Comments**

Code documentation should be:

- as close to the source as possible
- clarify or inform context that can't be known by  other means 
- should clarify present code only; we do not need to document past decisions or past code; git history is for that
- be brief and clear
- be contextually relevant

**Examples**

At the top of `gardener.lua`

Original: 

```lua
--[[
gardener.lua

The matching engine: a budgeted, round-robin scan pass over logistic networks
and space platforms. Player-facing behavior is in README.md, design invariants
in CLAUDE.md, rationale and history in docs/decisions.md.
]]
```

Evaluation:

- this contains low level implementation details ('budgeted, round-robin scan'), which is inappropriate as the top level comment as it requires constant upkeep with code changes
- fails to communicate the intention of gardener.lua
- includes a repo map which is not contextually relevant (why are we explaining the purpose of the [README.md](http://README.md) in here??)
- includes the name of the file "gardener.lua", people do not need that re-stated and it clarifies nothing

Improved:

```lua
--[[
This module is for tracking inventory and applying upgrade orders within logistic networks. 
]]
```

Explanation:

- clear, simple, direct language of the purpose of the file and nothing else

---

From `gardener.lua`

Original: 

```lua
  -- Storage keys from retired architectures; nil them so old saves migrate.
  storage.candidates = nil
  storage.ledger = nil
  storage.ledger_by_position = nil
  storage.cooldown = nil
  storage.refresh = nil
```

Evaluation:

- this is an excellent use of comment; there's no other way to know why these values are stored here without this context

---

From `CLAUDE.md`

Original from the section "Design invariants (read before changing core behavior)"

```markdown
The order ledger is a cancellation license — and, for module proxies, a
retarget hold. Membership in storage.order_ledger (keyed by unit number)
records that an order is ours and when we placed it: building marks we
ordered, and module-swap proxies we created or whose rows we retargeted.
Everything else the mod does is ownership-blind and reads the world. Absence
from the ledger means never cancelled; player marks can be quality-retargeted
but stay uncancellable forever. A ledgered mark is cancelled only when it has
outlived order-expiry-seconds and its target quality is out of stock — a
queued-but-stocked order is the bots' business. A ledgered proxy is never
cancelled; instead its starved module rows are held — not retargeted — until
the entry outlives the same expiry, covering the window where an ordered
module rides a bot and reads as out of stock. Losing the ledger is safe:
orphaned marks simply never expire, and orphaned proxies just lose their
hold and get the ordinary starved-request treatment.
The platform wait ledger (storage.platform_wait_ledger, swept by the same
between-rounds mechanism) is not a second ownership registry — it is a
clock table with no ownership meaning, answering only "since when has this
target been waiting."
```

Evaluation:

- way too much low-level detail that fails to clearly communicate a principle of the design
- much of this is not contextually relevant in CLAUDE.md
- includes implementation level details and terminology that may change in the future

Improved:

```markdown
- Orders that the mod initiates are ok to cancel if they grow stale. Order's placed by players should never be cancelled; to distinguish the two we use a ledger to track orders that are safe to cancel.
```

Explanation:

- We have clarified the general rule that is important
- Implementation details, such as when an order in the ledger can be cancelled, can be discovered by reading code; it doesn't need to be explained up front
- Regarding the detail about a player orders being safe to re-target; that is the intended purpose of the mod so it doesn't need to be in the design invariants section. 
- The detailed differences about space platforms, module retargeting, etc are implementation details that just confuse the picture at this level
- This context is loaded for every claude session, so it should be clear and brief



**changelog.txt**

This change log is for players - not engineers. It will be consumed by non-technical folks. 

It should:

- document gameplay changes in plain simple language
- focus on what players will notice that changed
- avoid words that don't provide surety or that can confuse the narrative
- should be limited to one or two brief sentences about what changed
- be conceptually clear and straightforward
- use consistent expected terms for concepts ("settings" instead of "behavior-toggles")

Here are some things it should not do:

- do not describe implementation details or internals unless relevant to the player (UPS improvements impact all players and should be mentioned, naming conventions of internal variables should not)
- use paragraphs of text when a single sentence or two is sufficient

**Examples**

Original: Fixed module upgrade orders sometimes being cancelled or replaced with a same-quality order moments after being placed.

- Improved: Fixed module upgrade orders that were being cancelled or replaced too early.
- Explanation: 'sometimes' is wishy washy; that is implying that sometimes it worked correctly and sometimes it didn't - that concept doesn't need to exist at all in our change log.



Original: Starved upgrade orders now self-heal. The mod remembers which upgrade marks it placed - and only ever cancels those; your own marks are never touched - and cancels one that has waited longer than the new Order Expiry setting (default 300 s) with its item out of stock, for example after biter damage or your own upgrade passes consumed the stock the order was counting on. The building becomes an ordinary candidate again on the next round. Orders whose item is in stock but queued behind busy bots are left alone. Set the expiry to 0 to keep the old never-cancel behavior.

- Improved: The mod now remembers which upgrade orders it placed and cancels them if items have been out of stock for a period of time. The Order Expiry setting can be used to adjust the period of time.
- Explanation: It should be self apparent; but players shouldn't need to read an essay on a change. The improved version is much clearer for everyone.

