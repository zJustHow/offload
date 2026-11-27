# Architecture, decisions and verification status

## 1. Data model (`Store/`)

One SQLite file. Raw text exists **once**, in `chunks`; the lexical indexes are FTS5 *external
content* tables over it, kept in sync by triggers, so a delete (including a cascade from deleting an
item) can never leave stale index entries.

| table | holds |
|---|---|
| `items` | one row per source item: where it came from, a content **fingerprint**, the triage verdict and summary, a trust tier, merge bookkeeping |
| `chunks` (+ `chunk_fts`, `chunk_tri`) | raw, PII-redacted text pieces of *survivor* items; word-segmented FTS and a trigram FTS |
| `chunk_vec` | one vector per chunk, tagged with its **embedding space** |
| `notes` (+ `note_fts`, `note_vec`) | the knowledge base mirrored for search |
| `note_evidence` | which source items support which note — the link from summary to original |
| `cards`, `conversation` | prepared suggestions; assistant history |

Vectors from different spaces are never compared. This matters for per-language models: a Chinese and
an English vector come from unrelated models. A multilingual HTTP embedder gives one shared space.

## 2. Ingestion (`Pipeline/`, `Sources/`)

`Connector.list()` is cheap (paths, ids, fingerprints); the pipeline drops what it has already
processed, then `load`s the rest. Because identity is `(bucket, key)` plus a fingerprint, an *edited*
file is re-read — a "newest item seen" pointer would miss that — and a file that disappears is removed
with its chunks. An unreadable source (revoked permission) is reported as an error and **never**
treated as empty, which would delete everything learned from it.

Each item is committed atomically (row + chunks in one transaction), one at a time, so an interruption
loses at most the item in flight. Model failures are stored as `failed` and retried next run; they are
never remembered as "junk".

**Live sync** (`LiveSync`, `FolderWatcher`; on by default, `liveSync` in the config) applies the same rules
between cycles. FSEvents reports changed paths; each path is held until it has been quiet for a few seconds
(per path, so a file that never stops changing cannot starve the rest); `IngestPipeline.sync` then reconciles
just those paths through `PathScopedConnector.refs(under:)` — the same eligibility rules as a full listing, so
a path yields exactly the keys a full scan would. A path that is gone deletes its items, chunks and vectors (a
folder is reconciled as a whole), and an unreadable root is an error, not a deletion. When it starts it also
**catches up**: it reconciles each folder once, so what changed while the app was closed or the Mac slept is
applied at launch, not at the next nightly run. Only folders that have been **read in full on purpose** are
followed (`KnowledgeStore.hasBeenRead`, one flag per source, set when a full read runs to the end; a read that
was stopped, timed out or capped does not set it, so it is never silently resumed). The first read of a folder
stays a visible step (onboarding or a cycle) and never starts by itself. Databases from before the flag
existed are trusted once: what they already hold counts as read.
It only updates the raw index; notes are still written by the cycle, which finds the new items waiting. A
cycle and live sync take turns (`Runtime.ingestGate`). Events can still be lost, so the nightly cycle stays
the authoritative full reconciliation. Item keys are real paths (symlinks resolved), which is what both a
directory walk and FSEvents report.

**Triage** is fail-closed: unparseable output, a missing `junk` boolean, an empty summary, or a summary
containing an identifier all resolve to junk/sensitive, never to a survivor. For mail, chat and
calendar the `sensitive` flag is mandatory.

## 3. Knowledge builder (`Vault/`)

* The model proposes **edit operations** (`create` / `append` / `rewrite`) as JSON. Code validates each
  one — path safety, limits on notes/folders/size, a shrink guard on rewrites, duplicate titles — and
  applies it to a **staging copy** of the vault. The model never touches the filesystem.
* Each batch is shown the **existing notes most related to it**, found with the hybrid searcher over a
  scratch index of the staged notes. This keeps the model extending the right note instead of creating
  near-duplicates, and keeps working when the vault is larger than a prompt.
* The model must **account for every evidence item**: cite it in an operation, or list it as skipped.
  Items it ignored, or that only appeared in *rejected* operations, are retried (3 attempts, then
  given up) instead of being silently marked done.
* Operations cite the evidence they used; those citations become `note_evidence`.
* The live folder is replaced by one atomic swap, only if no note changed while the run was going
  (content fingerprint). A user's edits survive updates because staging is a copy of the live vault.
* Deterministic clean-up after every edit: dangling `[[links]]` become plain text, repeated paragraphs
  and list items collapse, appends are idempotent.
* The README is a model-written **portrait** plus a **map generated by code**, so every link resolves.

## 4. Hybrid retrieval (`Retrieval/`)

Four signals per query, merged with **weighted Reciprocal Rank Fusion** (ranks, not scores — BM25 and
cosine are on incomparable scales, and the built-in embeddings squeeze cosine into a narrow band):

1. **lexical** — BM25 over *word-segmented* text. Chinese is segmented with `NLTokenizer`, but that API
   drops the CJK part of a mixed Chinese/English string, so text is first split into script runs and
   each run is tokenized on its own (regression-tested). CJK bigrams are optionally added.
2. **exact** — FTS5 trigram substring search for identifiers, quoted phrases and e-mails.
3. **vector** — exact cosine search (one matrix–vector product per space, Accelerate).
4. **provenance** — a chunk gains score when a highly ranked note cites its item, and a note gains
   score when its evidence contains highly ranked chunks.

Queries that look like identifiers shift weight toward lexical/exact; vague ones toward vectors.
Results are capped per source item and get a mild recency boost.

### Measured, on the bundled synthetic corpus

```
config                             | overall MRR  R@3  R@5 | keyword    MRR  R@3 | paraphrase MRR  R@3 | identifier MRR  R@3 | crossLinguaMRR  R@3
--------------------------------------------------------------------------------------------------------------------------------------------------
lexical (BM25)                     |  0.78         0.81  0.81 |             1.00  1.00 |             0.54  0.62 |             1.00  1.00 |             0.50  0.50
exact (trigram) only               |  0.24         0.24  0.24 |             0.00  0.00 |             0.00  0.00 |             1.00  1.00 |             0.00  0.00
vector: apple sentence             |  0.27         0.30  0.43 |             0.38  0.36 |             0.15  0.15 |             0.33  0.44 |             0.19  0.25
vector: apple contextual           |  0.65         0.70  0.78 |             0.84  0.82 |             0.66  0.69 |             0.44  0.44 |             0.58  1.00
HYBRID: hashing                    |  0.80         0.81  0.86 |             1.00  1.00 |             0.58  0.62 |             1.00  1.00 |             0.50  0.50
HYBRID: apple sentence             |  0.76         0.86  0.89 |             0.91  1.00 |             0.55  0.69 |             1.00  1.00 |             0.50  0.75
HYBRID: apple contextual           |  0.85         0.92  0.97 |             1.00  1.00 |             0.69  0.85 |             1.00  1.00 |             0.65  0.75
```

How to read this honestly:

* The corpus (40 documents, 37 queries, English + Chinese) was **written by the same author as the
  retrieval code**. It is a regression harness and a way to compare configurations with each other,
  not a benchmark; absolute numbers are not real-world accuracy. Contextual-embedding runs vary by about
  ±0.02 MRR between runs.
* Hybrid with the contextual embedder beats both lexical-only and vector-only overall, mostly through
  paraphrase queries (lexical 0.54 → hybrid ~0.7 MRR) while keeping keyword and identifier recall at 1.00.
* **Apple's sentence embeddings are poor** (0.27 MRR alone, worse than a plain hashing baseline) and
  *lower* hybrid MRR below lexical-only. They are not the default; the contextual model is.
* Cross-lingual queries (Chinese question, English document) are only partly answered: the built-in
  embedders are per-language. A multilingual endpoint (e.g. bge-m3 via Ollama) is needed for that.
* **No measured benefit** was found for CJK bigrams or for the trigram retriever on this corpus (plain
  BM25 already matched the identifiers). They are kept because they are cheap and target cases the
  corpus does not cover (partial ids, e-mails, segmentation disagreement), but that is a design
  argument, not a result.

## 5. Consumers (`Agents/`, `MCP/`)

* **`MemoryService`** is the single doorway for assistants. It returns notes and raw excerpts to every
  caller; there is no egress gate. Excerpts are protected by `PIIScan.redact` at ingestion.
* **Egress redaction** (`Pipeline/EgressRedaction.swift`): `Runtime.makeModel` wraps every hosted model in
  `RedactingModel` and `makeEmbedder` wraps remote endpoints in `RedactingEmbedder`; both run `PIIScan.redact`
  over everything they send. `MCPServer` does the same to each tool result. This closes the paths that bypass
  the index (triage input, notes, live screen text, queries). Local models are returned unwrapped, name and
  capabilities are forwarded unchanged, and the pass is idempotent, so ingestion plus egress never double-redacts.
  Not covered: images, and anything the regex set does not know.
* **Reply drafter**: the visible conversation, plus the user's instruction if they gave one ("say yes and
  include the deposit reference" names a fact the screen may not show), is the search query, so the prompt
  contains only the few relevant notes/excerpts (the request does not grow with the vault) and can include
  specifics a summary dropped. Output is text only; sending is the user's act. It has three entry points: the
  double-⌘ hotkey (no instruction; pastes at once), `offload draft --instruction`, and the notch's **Reply**
  mode, which takes an optional instruction, shows the draft, and pastes it only when the user presses
  **Insert** (or puts it on the clipboard with **Copy**). Reply mode photographs the screen without Offload's
  own windows in it, so the notch's status text is not read as part of the message; it needs Screen Recording
  to read the screen and Accessibility only to insert (without it, Insert copies the draft instead and asks for
  the permission). It does not look an e-mail up by sender or subject: it replies to what is on screen.
* **Agent**: one JSON action per turn for every model that has no native tool calling (small local ones
  included), native tool calls for those that do (§14). Irreversible actions need confirmation; the model's own
  risk flag is only ever *added to* by a keyword backstop (English and Chinese). `open_source` only opens
  files Offload indexed; `open_url` allows http(s)/mailto only. What runs, asks or is refused is decided by
  the tool layer, not by the loop (§14).
* **Proactive planner**: a cheap judge over summaries picks candidates; each is grounded with a hybrid
  search and dropped if stale. "Unverified" is allowed and can never be shown as confident.
* **MCP**: stdio JSON-RPC, four read-only tools plus the notes as resources, path-traversal safe,
  case-insensitive path fallback; and a client for other MCP servers (§14).

## 6. Findings from running it for real

These came from running the real on-device model and a real end-to-end cycle, not from the unit tests:

* **Triage works on the built-in model**: 6/6 verdicts correct on a mixed English/Chinese set,
  ~1–3 s per item. It converted "yesterday" into a wrong calendar date until the prompt forbade
  computing dates.
* **Knowledge synthesis does not work well on the built-in model.** It put a bread recipe in the
  apartment note, a trip into the fundraising note, repeated itself, and wrote a misleading portrait.
  The pipeline's safeguards (accounting, validation, dedupe) keep it from *losing* data, but cannot make
  a 3B model reason across items. `cycle` warns when this model writes the knowledge base. **The raw
  index is what made the system useful in that run**: searching a booking code, or a Chinese question
  about a lease the notes had dropped entirely, found the right original.
* Bugs the real run exposed and the unit tests had missed (each now has a regression test):
  a path-containment check that silently skipped every write when the data directory was under
  `/private/tmp` (symlink vs. non-existent-file normalization); `"\r\n"` being one Swift `Character`
  (eating the first letter of MIME part headers); a default data path that collided with another app's
  directory; a test that wrote into the real home directory; items marked "merged" even when their
  operations had been rejected.

## 7. More sources (`Sources/`)

| source | how it is read | notes |
|---|---|---|
| **Apple Notes** | `NoteStore.sqlite` (copied first). Each note is a gzip stream of Protocol Buffers; a ~40-line wire-format reader extracts `document(2) > note(3) > note_text(2)` | asks the database which columns exist and selects only those (the table changed between macOS versions); skips password-protected notes, notes marked deleted and the Recently Deleted folder |
| **SiYuan** | the workspace's `data/` folder: `.sy` JSON files, no running app or token | notebook = first folder under `data/` (document folders carry IDs of the same shape, which once fooled a "nearest ID-like folder" search); renders headings, lists, code, tables, tags, block refs |
| **Word / PowerPoint** | `.docx` and `.pptx` files inside the chosen folders (`Text/OfficeText.swift`). Both are ZIP archives of XML, so a small ZIP reader (stored and DEFLATE, via the system decompressor) plus a streaming XML pass, with no dependency | untrusted input: offsets are bounds-checked, each entry is inflated through a stream capped at 32 MB (an archive that lies about its size is still stopped), external XML entities are off, output is capped. Word: body, footnotes, endnotes; tables keep rows on one line; the fallback copy of a text box is skipped so it is not read twice. PowerPoint: slides in deck order (from `presentation.xml`, since reordered slides keep their old file names), each followed by its speaker notes. Treated as saved material, like PDFs. Not read: legacy `.doc`/`.ppt`, password-protected files (not ZIP archives), headers and footers, charts, SmartArt, ZIP64. Checked against the system `textutil` on real Word files: identical word counts apart from list bullets it adds |
| **Gmail** | Gmail REST API, `gmail.readonly` | message id doubles as fingerprint (mail is immutable); dates/subjects fetched only for unseen ids with bounded concurrency and cached; a failed listing never deletes anything. Gmail allows 6,000 quota units per user per minute and a metadata `get` costs 20, so about 300 messages a minute: a quota error (HTTP 429, or a 403 naming a rate limit or a per-minute quota) is retried with truncated exponential backoff (2, 4, 8, 16, 32, 32 s, `Retry-After` honoured) shared by every request in flight, and metadata fetched before a failure is saved so the next run continues instead of starting over. A message deleted between the listing and the fetch is skipped. A disabled API, a missing permission or a daily limit is reported at once, not retried |
| **Google Calendar** | Calendar REST API, `calendar.readonly`, as a `CalendarEventSource` | every calendar except holidays; attendee **names** only, never addresses |

**Google sign-in** is the standard desktop flow: system browser, loopback redirect on `127.0.0.1` only,
PKCE (S256), a random `state`, and the refresh token in the Keychain. You must create an OAuth client of
type *Desktop app* in your own Google Cloud project (enable the Gmail and Calendar APIs): an app cannot
ship a shared client that is allowed to read mailboxes without Google's security review.

Each source gets its own bucket (`calendar:apple` and `calendar:google` are different on purpose: two
sources sharing a bucket would each delete the other's items when reconciling, and there is a test).

## 8. Using your ChatGPT / Claude subscription

`ClaudeCLIModel` and `CodexCLIModel` run the official command-line tools as one-shot subprocesses, so
the user's own login is used and no API key is involved.

* **Claude** (`claude -p`): empty working directory, `--tools ""` (no tools), `--strict-mcp-config` (no MCP
  servers), `--setting-sources ""`, `--no-session-persistence`, prompt on stdin (never in argv). `ANTHROPIC_API_KEY`
  and friends are *removed from the child's environment*, otherwise the CLI bills that key instead of the subscription.
  **Optional, answering questions only** (`memoryTools` in the assistant's model profile, `offload config model assistant
  --provider claude-cli --memory-tools`, or the toggle in Settings): the command is also given Offload's own read-only MCP
  server (`--mcp-config`, still `--strict-mcp-config`, still `--tools ""`) and `--allowedTools` names exactly its four memory
  tools. Claude can then search and read the knowledge base itself instead of only being handed the excerpts retrieval picked,
  and answers questions whose notes the first search missed. It is limited three ways: only a request that sets `lookups`
  (`MemoryQA`) gets the server, so triage, note writing, drafting and the agent's own turns never do; only the assistant role
  can enable it; and the server returns redacted text, like any MCP client's. The command loop runs inside Claude Code, so
  Offload does not see each lookup. The `offload` program is found as the running command-line tool, next to the app inside its
  bundle, or on the search path; if it cannot be found, a note says so and answers use excerpts only. Verified with the real
  `claude` command over a notes folder with no index (it fetched a surname that exists only in one note), and through
  `offload ask`.

  **Optional, carrying out "Do" tasks** (`agentTools`, `--agent-tools`, or the second toggle in Settings): the whole task is handed to
  `claude`, which plans and calls tools; every call comes **back into the Offload process** that started it (§14, "Tool host") and goes through
  the assistant's own dispatcher, so it gets exactly the assistant's tools (notes, the web if enabled, connected apps, operating the Mac), permission
  rules, approvals in the notch, hooks, redaction, the audit log and the step limit. The command still has no built-in tools and only the one MCP server.
  Verified with the real command: a task that searched, fetched a web page (asked, approved), browsed and read a note, created a new note (asked, approved,
  written to the vault) and called a connected app's tool (asked, approved), with every step reported as it happened.
* **Codex** (`codex exec`): read-only sandbox in an empty directory, final message read from `-o <file>`, screenshots
  passed with `-i`. Codex has no switch that removes its shell tool, so containment is the sandbox only.
* Both count as **hosted** (`isLocal == false`). If *triage* is pointed at one, the text of every item read is sent
  to that provider; `config` and `cycle` warn about this.

Verified: the Claude path against the real CLI (login status, a one-shot reply through the app's own code, and a
full `ask` over the knowledge base, checked before the raw-excerpt gate was removed: with the gate closed the hosted
model saw only notes and answered "not in the excerpts"; with it open it returned the booking code and cited the file). **Not verified: Codex** — it is
not installed where this was built. Its flags follow Codex's documented `exec` interface and the argument handling is
tested against a stand-in executable, nothing more.

## 9. The notch assistant and the visual language (`OffloadUI/`)

* **Where the notch is** is read from `NSScreen` (`safeAreaInsets` + the menu-bar areas either side). On the
  development Mac (14-inch MacBook Pro) that gave 185 × 32 pt on a 1512-pt screen; a Mac without a notch gets
  a pill-sized stand-in.
* **A state machine** (`NotchModel`: hidden, compact, input, thinking, working, confirm, answer, error; modes Ask,
  Do and Reply, where a Reply may be submitted with an empty field and its answer is a draft with Copy/Insert)
  with no knowledge of models; the app feeds it. A question the user never answered, or a surface that was closed or
  superseded, resolves as **No**, never as approval.
* **The panel** is borderless, transparent, non-activating (it takes typing without stealing focus), sits above the
  menu bar, and lets clicks through everywhere except the visible surface. A click on the notch, or ⌘⇧Space (a
  combination that types no character, because a global monitor can see a key but not swallow it), opens it. While
  the agent operates the Mac the whole display glows (`ScreenEdgeGlowController`) so there is no doubt who has the mouse.
* **Visual language.** The look is ChatGPT's dark theme, in black, white and gray only (no hue anywhere): one flat canvas
  (`Theme.canvas`, ~#212121), a darker sidebar (~#171717), one raised surface for cards, the composer and chips
  (~#2F2F2F), hairline borders, a white pill for the one thing to press and an outlined pill for everything else
  (`PrimaryButtonStyle`, `QuietButtonStyle`), a round white send arrow (`SendButton`), sentence-case section labels, and
  no gradients, mesh backgrounds or glow. Home is a sidebar (ask, knowledge, suggestions, then the sources, as ChatGPT
  lists chats) beside a centered column (greeting, a composer-shaped button that opens the assistant, then the facts).
  The Knowledge and Settings windows follow the same layout (a dark sidebar, with a round search field or the list of settings sections, beside a canvas with the content), as do Suggestions and the chat picker; inside Settings the native form controls are re-skinned (pill switches, outlined buttons, white accent) rather than replaced. The menu-bar menu itself stays a native menu, which cannot be styled. The only animated ornaments are a small breathing white dot (`ThinkingDot`) and the shimmering status text; the one
  glow left is the white whole-display glow while the agent operates the Mac, because that is a safety signal, not
  decoration. In the notch the surface stays black so it joins the hardware notch; inside it the input is a round
  composer with the mode as quiet pills, and a long answer's card is solid black at the top and dissolves into dark glass
  along the bottom edge (`GlassFade`), as Apple's new Siri response card does. OpenAI publishes no tokens, so the grays
  are read by eye (third-party write-ups put the main area near #212121 and the sidebar near #171717); the glass fade's
  numbers are likewise read off screenshots. All of it is an approximation to tune in `Theme`.
* **How it was checked.** Because the animations cannot be watched here, every state is rendered to PNG with
  `ImageRenderer` (`offload-previews <dir>`) and was inspected, and a pixel test renders every notch state and asserts
  that no pixel anywhere carries a hue, and a second one does the same for every first-run screen, Home (with every
  status icon), the knowledge graph and the whole-display glow (both fail if a colored button or glow comes back). Not checked: the live
  behind-window blur of the glass layer, which `ImageRenderer` cannot draw.

## 10. Findings from running this round

* A `@StateObject` initializer runs *inside* a SwiftUI graph update; creating an `NSHostingView` there re-enters
  SwiftUI and aborts the process. Only launching the real app showed it (no unit test could). Window setup now
  happens one run-loop turn later.
* `.completeFileProtection` makes writes fail while the screen is locked, which is when the nightly job runs, and
  `try?` hid it, so the Gmail cache silently never saved. Removed (owner-only permissions + FileVault instead).
* A task group does not return until every child finishes, so a timeout around a *non-cancellable* continuation
  (waiting for the OAuth redirect) hung forever; the wait now honors cancellation.
* Swift's synthesized `Codable` ignores property defaults for missing keys, so adding config fields would have
  broken every existing config; decoding is now tolerant, with a test.
* `ImageRenderer` cannot draw AppKit-backed controls (`TextField`, `ScrollView`), so stills substitute static views;
  the live app uses the real controls.

## 11. The app around the notch (`OffloadApp/`, `OffloadUI/`)

* **First-run guide** (`OnboardingModel` + `OnboardingView`, seven steps: welcome, sources, permissions, models, privacy,
  first reading, done). The model is a plain state machine with no dependency on Core, so every rule is unit-tested:
  you cannot leave *Sources* with nothing chosen; *Permissions* warns ("Continue anyway") but never blocks; model
  options that are unavailable cannot be selected; while the first reading runs you can only keep going in the
  background, not walk back into a half-finished step. The app wires it to the real thing: permission rows follow what you do in
  System Settings (re-checked every second while the guide is open), the reading step runs the real cycle and shows what it is doing, and a
  relaunch resumes at the saved step. Skipping everything is allowed and still leaves a working app.
* **Home** (`HomeView`): a greeting, what was read and how many notes exist, per-source status in plain words
  (`Dashboard.sourceStatus` names the exact missing permission instead of "error"), the last run in a sentence
  (`Dashboard.activityText`), and one primary action that becomes *Stop* while a run is in progress.
* **Knowledge** (`KnowledgeView`): a note browser and Markdown editor with the evidence behind each note, search over the
  hybrid index, and a **constellation** of the vault (`KnowledgeGraph` + `GraphLayout`: wiki-links become edges, folders
  become colors, a seeded force layout makes the picture identical every time; pan, zoom, hover, click to open). An edit
  made by hand wins over the builder: the nightly run skips the knowledge step while a note has unsaved changes.
* **Settings** has six tabs (General, Sources, Models, Privacy, Nightly, Advanced). *Advanced* shows live health checks, the
  two reset actions behind confirmation dialogs, and a log folder (`AppLog`: events, counts and error text, never contents;
  also in Console.app under `dev.offload`).
* **Plain-language errors** (`ErrorText.friendly`): usage limits, a missing `claude`/`codex` tool, being offline and an
  ineligible Apple Intelligence setup each get a sentence that says what to do; anything else is shortened, not hidden.
* **Accessibility.** Icon-only controls carry labels, the mode switch exposes its selection, decorative orbs are hidden from
  VoiceOver. With **Reduce Motion** on, every continuous animation (glow, orb, shimmer, graph twinkle) stops at a fixed
  pleasant frame, onboarding slides become fades and the notch changes size with a short fade instead of a spring.
* **Packaging.** `Scripts/make_app.sh` builds the bundle (version/build via `VERSION`/`BUILD`, an icon drawn by the same
  SwiftUI code as the app, usage strings, ad-hoc signature, or `SIGN_IDENTITY` for a Developer ID); `Scripts/make_dmg.sh`
  makes a verified disk image. Notarization needs your Apple Developer account and was not done.

### Redundancy removed in this pass

Three copies of the "describe an agent step" mapping, two of the source-status logic and two of the error-wording helpers were
folded into `Runtime/Dashboard.swift` (tested once, used by the app and CLI). Connectors no longer copy a chat/notes database
per *item*: one snapshot per run (`SnapshotBox`) and one calendar fetch per run (`EventCache`), each with a regression test
that counts the copies/fetches. The build is warning-free.

## 12. Verification status

| | |
|---|---|
| **Automated tests (363; 321 core, 42 UI)** | the tool layer: JSON values and schema repair, the permission table (modes × tiers, rules, hooks, "always asks"), the dispatcher (a refused or declined call never runs; the audit event carries no contents), registry search and deferral, the agent under policy / plan-first / hidden tools / native calls / compaction, the MCP client against this app's own server and against a bash stand-in server run as a real child process (qualified names, a missing program, timeout, restart after a crash, the app's keys not leaking into the child, identifiers scrubbed from arguments), the MCP server's resources, request shapes for Anthropic and OpenAI-compatible tool calling against a stubbed URL protocol, web address guard (every spelling of a private address), web tools and note edits (every rejection happens before anyone is asked). Earlier: |
| **Automated tests, earlier (218)** | everything in the first release, plus: the notch's Reply mode (empty instruction allowed, draft shown before anything is inserted, Copy/Insert only for a draft) and the user's instruction steering retrieval; the first-run state machine (every forward/back/blocked rule), graph construction and layout (determinism, bounds, folder clustering), dashboard and error wording, the log (rotation, permissions, deleted directory), a render check that every onboarding screen and Home draw real content and that a still is stable while a different phase is not, connector copy/fetch counts; gzip against the system `gzip`, protobuf extraction, Apple Notes and SiYuan fixtures (incl. older schema, locked/deleted notes, edits), the full Google OAuth flow against a real local listener (PKCE binding, forged state, denial, timeout), Gmail paging/cache/401-retry/parsing/pipeline, Google Calendar mapping, subscription CLIs against stand-in executables (args, env stripping, empty cwd, timeout, 3 MB of output), notch geometry/layout/state machine, gradient invariants, pixel-level glow checks |
| **Run for real** | the MCP client against a real, independent MCP server (`claude mcp serve`: handshake, discovery of 27 tools, and real calls to its `Read` and `ToolSearch` tools: a file read, string-to-integer repair of `offset`/`limit`, a server-reported error, schema rejection before sending, and an allow rule silencing the question; `OFFLOAD_LIVE_MCP=1`); the agent on the built-in on-device model through the new registry; live web fetch and search (`OFFLOAD_LIVE_WEB=1`); built-in on-device model; Apple embeddings; full `cycle → search → ask → draft → mcp`; **the real Claude subscription** (`ask` with and without raw excerpts, before the gate was removed); the app bundle launching with the notch shown, window level and frame confirmed from inside AppKit; a fresh install opening exactly one Welcome window and leaving no files, Keychain items or LaunchAgents outside its own folder; the icon, `.icns`, `Info.plist` and a verified DMG |
| **Not tested** | native tool calling against the **real Anthropic and OpenAI endpoints**: no key was available. What was done instead: the request and reply shapes were checked against the current API documentation (which found and fixed real errors, see §14) and against a stubbed URL protocol; `LiveProviderTests` runs the real calls, including a cache-hit check, once you give it a key (`ANTHROPIC_API_KEY=... OFFLOAD_LIVE_ANTHROPIC=1 swift test --filter LiveProviderTests`); the computer-operation tools reached through `claude` (tested with a fake controller, in-process and through the real socket and bridge; not run against the real screen, which needs Screen Recording and Accessibility and would send what is on screen to Anthropic); calls to MCP servers other than Claude Code's own (the official `@modelcontextprotocol/server-everything` was downloaded but not run, because the permission check blocked running it); the notch's checklist, plan, approval and question surfaces were rendered to images and read, and the model behind them is unit-tested, but they were not used live on a screen; the notch's *live* appearance and animation on a screen (no screen-recording permission here); click-through and the ⌘⇧Space / click-on-notch triggers; the double-⌘ hotkey and paste; the notch's Reply mode on a real screen (the screenshot without Offload's own windows, OCR of a real mail, and Insert's ⌘V landing in the right field after the notch closes); `MacComputerController`; real Gmail/Google Calendar beyond one hand-run (a Personal-mode OAuth client; 400 messages listed in about 90 s including quota back-off, 3 read; the first attempt, before back-off existed, failed on the per-minute quota); real Apple Notes / SiYuan / WhatsApp / iMessage databases (fixtures only) |
| **Open question** | the window server reports an on-screen window at 0.9× scale, anchored at its bottom-centre. It does the same for a trivial solid-colour panel in a separate test program, and AppKit reports the intended frame, so it looks like a property of the environment this was built in rather than of the panel; it could not be confirmed on a real display. |
| **Unverified formats** | WhatsApp schema, Apple Notes store layout, SiYuan `.sy` node layout: from documentation, not from real data |

## 13. Not implemented

* Voice input, the physical screen-tap gesture, a separate virtual cursor (the agent uses the real cursor),
  auto-update (Sparkle), notarization, localization (the interface is English only).
* A privileged wake helper (`schedule install` prints the `pmset` command instead), a hosted relay / remote MCP, Windows.
* MCP: HTTP/SSE transports, OAuth, sampling and roots; MCP server `listChanged` and prompts. Web search depends on a scraped page.
* Native tool calling for the on-device model (the OS API does not offer it to this code), so it keeps the text protocol.
* SiYuan through its HTTP API (files are read directly), and Gmail through hosted connectors (the REST API is used).

## 14. The tool layer (`Tools/`, `MCP/`)

Ideas taken from reading how claw-code (a Rust coding agent) structures its tools, adapted to this app's
constraints (small on-device model, privacy first, no shell). Nothing was copied: the code is Swift, and several
claw-code choices were deliberately not followed (see "Not taken" below).

**One registry.** A tool is declared once (`ToolSpec`: name, description, JSON Schema, access tier, approval policy,
whether it is deferred or untrusted) and implemented once (`Tool`, or a closure via `FunctionTool`). The agent's text
protocol list, native tool definitions, the MCP server's `tools/list` and execution all come from `ToolRegistry`.
Before this, the same tool was written three times (the agent's `switch`, its prompt text, the MCP server's table).
Arguments are `JSONValue`, not `[String: String]`, so arrays and nested objects (MCP tools, native calls) fit; models'
loose typing (`"10"` for 10, a JSON array sent as a string) is repaired by `SchemaCheck.coerce`, and what is still wrong is
reported to the model in words (`x is required`).

**One path for every call** (`ToolDispatcher`), used by the agent loop and the MCP server alike:
look up (case and separators ignored) → repair and validate arguments → pre-hooks → the tool's own `preflight` →
permission → approval → run → post-hooks. A refusal is an ordinary tool result ("denied: …"), so the model can choose another
way. No tool runs without passing the permission step. `ToolEvent`s (name, tier, result, whether the user was asked, output
*size*) go to `AppLog`; arguments and output text never do.

**Permissions** (`Permissions.swift`). Tools have a tier: `read-only`, `write` (the user's notes), `act` (operate the Mac,
reach outside). The session has a mode: `read-only`, `write`, `act` (privilege tiers) or `prompt` (ask about everything) /
`allow` (ask about nothing). Modes of asking are never ranked against tiers, which is how claw-code's ladder once let `prompt`
auto-allow everything. Order, first match wins: disabled tool name → `deny` rule → hook deny/ask → `ask` rule → `allow` rule or a
mode that covers the tier → ask (one step short) or refuse. Rules are `name`, `prefix*` or `name(arg-pattern*)`. A tool with
`approval: .always` (third-party MCP tools, web access, note edits) asks even in `allow` mode unless a rule names it. The keyword
backstop (`RiskClassifier`) and the model's own flag still only ever add a question, whatever the rules say. Default mode is `act`, which
reproduces the previous behaviour exactly.

**Hooks** (`ToolHooks.swift`): before a tool (may deny, ask, or rewrite the arguments, never grant), after it, after it fails.
Built in: `OutputRedactionHook` (the MCP server's scrub, formerly hand-written in its request handler),
`ArgumentRedactionHook` (identifiers removed from what is sent to an MCP server), `UntrustedContentHook` (output of web pages and
third-party servers is labelled as data).

**MCP client** (`MCP/MCPClient*.swift`). The assistant can use tools from MCP servers the user adds (`offload apps add …`). stdio only,
newline-delimited JSON-RPC (the protocol's framing; claw-code uses `Content-Length` headers, which MCP stdio does not).
Tools are named `mcp__<server>__<tool>` (64-character cap, stable hash when shortened) so servers cannot collide or impersonate built-ins.
Connection is best-effort and parallel: one server failing yields a report (phase, whether retrying could help, `required`) and the rest
still work. Each call has a timeout; a server whose process died is started again on the next call. A server runs with an empty scratch
directory and a short allow-listed environment (not the app's own keys); `KEY=keychain:account` fills a secret from the Keychain.
Because a server's tool descriptions go into the model's prompt, they are cut to one 400-character line without control characters.
A tool counts as read-only only if the server says so (`readOnlyHint`) or the user vouches for the server; otherwise it asks every time.
When more than six MCP tools exist they are not all listed: the model finds them with `tool_search` (ranked search, `select:name`,
`+required`), after which they are listed for the rest of the run. Servers that offer resources get `list_mcp_resources` / `read_mcp_resource`.

**MCP server** (`MCP/MCPServer.swift`) now runs under a read-only policy through the same dispatcher, offers `read_item`, and offers the
notes as resources (`resources/list`, `resources/read`, `offload://note/<path>`; traversal and other schemes are "not found").

**What the real APIs require** (found by checking the code against the current Anthropic documentation, and for OpenAI against its API reference; neither could be called without a key):
* Anthropic: current models, and every model on API version `2026-10-21`, answer **400 to `temperature`**, which the old `AnthropicModel` sent on every call (the agent's 0.2, the default of `complete(system:user:)`). It is no longer sent. Thinking is on by default and counts toward `max_tokens`, so a cap below 4,096 is raised to 4,096 (a cap never lengthens a reply). A reply starts with signed `thinking` blocks that must be sent back **unchanged**; they are kept as `providerBlocks` and replayed verbatim. They are valid only while everything before them is unchanged, so a native run freezes its system prompt and tool list (no `tool_search` there; the plan-first rule stays in the prompt after approval and the dispatcher enforces it), and a history rewrite (compaction, shortening) drops them once. A `refusal` stop ends the run as refused; a reply cut off at `max_tokens` runs no tool (its call may be incomplete) and is retried.
* OpenAI: `api.openai.com` and Azure take `max_completion_tokens` and refuse `temperature` on newer models; Ollama, LM Studio, vLLM and OpenRouter still take `max_tokens`. The form follows the host (or `modernParameters`). `finish_reason`, `refusal` and cached tokens are mapped to the same vocabulary.
* `ModelReply` now carries `stopReason` and `usage` (including cache creation and cache read tokens), so cache effectiveness is observable.

**Native tool calling and caching.** `LanguageModel.completeWithTools` (default: unsupported) is implemented for Anthropic and, opt-in
(`nativeTools` in the model profile), for OpenAI-compatible servers; everything else keeps the JSON text protocol. Native mode allows several
calls per turn, executed in order, each answered; tools that act get an optional `irreversible` flag in their schema (stripped before
the tool runs). Anthropic requests mark the system prompt and the newest message as cache breakpoints, since an agent run resends the same
prefix every step; plain one-shot calls are not marked. Hosted models stay wrapped in `RedactingModel`, now also redacting tool results and the
arguments of earlier calls.

**History compaction** (`HistoryCompaction.swift`). Replaces "[earlier step omitted]" blanking: older steps become a digest (tool, arguments,
first part of the result) folded into the task message, the last two steps stay verbatim, steps are removed as whole pairs (so every native
call keeps its result), the digest is capped and drops its oldest lines first. No model call.

**Tools added to the assistant.**
* `propose_note_edit` goes through `VaultOps.apply` (the nightly builder's validation), is refused *before* the user is asked if invalid, shown
  to the user, and written (and indexed) only if approved. `README.md` cannot be edited. On by default; `agent.noteEditing` turns it off.
* `web_fetch` / `web_search` (off by default, `agent.webTools`): ask every time and show the exact address or query; refuse addresses or
  queries containing identifiers (also percent-encoded); refuse `localhost`, private, link-local, carrier-grade-NAT and multicast ranges in any
  spelling (`127.1`, `2130706433`, `0x7f000001`, IPv4-mapped IPv6), and names that resolve to them; no credentials in URLs; redirects are re-checked;
  2 MB cap; no cookies or cache; allow/block domain lists. The address is checked, and then connected to, with two separate name lookups, so a hostile DNS server could answer differently the second time; that is not defended. Search scrapes DuckDuckGo's HTML endpoint and returns nothing when its layout changes.
* `todo_write` (checklist events; native-tool models only), `exit_plan_mode` (with plan-first: read-only until the user approves the plan),
  `ask_user` with options, `tool_search`.

**In the notch** (`NotchModel`, `NotchView`, wired in `OffloadApp/NotchAssistantBridge.swift`). The assistant's checklist shows under its steps (done struck through,
the step in progress lit; a long list shows a window of five around the current step). An approval has three kinds: the original irreversible question, a
"needs your OK" question that says *why* it is asked (a connected app, a note edit), and a plan shown as a numbered list with "Go ahead" / "Not this plan". `ask_user` is a
question surface with up to four answer buttons and a text field, and "Skip"; before this, `ask_user` always answered "the user is not available" in the notch, because
no `ask` callback was connected. A newer question replaces an unanswered one as a "no", and closing the notch, stopping, or an error answers every open question with
"no" or nothing, so the assistant is never left waiting. The agent hands the app the full `ApprovalRequest` (`AgentOptions.approval`) instead of a sentence, which is how a plan is shown as a plan.

**Not taken from claw-code:** bash and file-editing tools, git/LSP/worker/team/task registries and its sandbox and policy engine (this is not a coding agent);
its shell-command hooks (a desktop app should not run user shell snippets around tool calls; hooks here are Swift code); `Content-Length` MCP framing;
approval tokens with delegation chains (overkill for one user); its cron tool (in claw-code it is an in-memory registry that never fires; scheduling here is
the LaunchAgent); its RAG service (this app's retrieval is stronger).

**Tool host and bridge** (`Tools/ToolHost.swift`, `MCP/MCPBridge.swift`): how Claude's command-line tool calls the assistant's tools, all of them,
without those tools moving into another process. A separate MCP server would have no screen permissions, no notch to ask in, and none of the assistant's
policy; so the tools stay in the app (or the `offload` command that started the task), and `claude` is given an MCP server that owns nothing:
`offload mcp --host <socket>` relays `tools/list` and `tools/call` over a Unix socket to a `ToolHost` in the starting process, which dispatches them.
* The socket lives in `/tmp/offload-h<random>/` (mode 0700, the socket 0600) for one task only; the first message must carry a random 128-bit token, or the
  connection is dropped unanswered. The token is in the bridge's environment, and in a 0600 configuration file in the command's private scratch folder; it is never on a
  command line (`ps` shows those to other users). A task that is stopped removes the folder; one that was killed leaves it, and the next task sweeps folders older than six hours.
* Only what the task exposes can be called: the assistant's registry minus `finish` and `tool_search` (Claude has its own ending and search). Names are shortened (with a hash)
  to fit the command's `mcp__offload__` prefix inside a provider's 64 characters. Acting tools get the optional `irreversible` flag, so Claude can say what cannot be undone.
* Because the command is a hosted model and its tool results do not pass the redacting model wrapper, the host adds the output-redaction hook to the dispatcher for these runs
  (the task text and instructions are redacted by the wrapper as before). Screenshots are not attached (`vision` is off for this model: `screenshot` says to use `screen_text`,
  which is OCR'd and scrubbed), so images, which cannot be scanned, never leave.
* The limits of the normal loop still hold, because the host counts: a step limit, two declines, four errors in a row. A refused call is answered with a reason, so Claude can finish.
  Plan-first works: the dispatcher stays read-only until `exit_plan_mode` is approved, then the host lifts it. Stopping the task in the notch terminates the command.
* Found by running it for real: without `get_structure` and `get_files`, a search that missed left Claude with nothing to try but asking the user, so models that can take a longer tool
  list (native tool calling, or running their own loop) are offered them too. And an optional call (`onEvent?(…)`) does not evaluate its arguments when nobody listens, which had made
  the step limit silently not count; it is counted on its own line now.
