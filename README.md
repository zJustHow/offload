# Offload

A personal assistant for macOS built around one idea: **understand the user's own data locally,
keep the result as plain Markdown they can read and edit, and let assistants use it** — with a
**hybrid retrieval** layer on top, so that exact details (a booking code, an amount, what was
agreed) are still reachable even though the readable notes are summaries.

It is written in Swift and ships as a CLI and a menu bar app. The design: on-device triage, a Markdown
knowledge base, a stronger model that merges summaries into notes, and assistants on top. The retrieval
layer, provenance links, edit-operation protocol and local MCP server are built in.

```
files · mail · chats · calendar
        │  (read locally, one item at a time, incrementally)
        ▼
  on-device triage ──► junk / sensitive: dropped          survivors:
        │                                                 ├─ summary ──► knowledge base (Markdown notes)
        │                                                 └─ raw text (PII-redacted) ──► hybrid index
        ▼                                                        BM25 + trigram + vectors
 questions · reply drafts · agent tasks · MCP · suggestions  ◄──────────────┘
```

## Quick start

Requires macOS 26+, Xcode 26+ (built and tested on macOS 27 / Swift 6.4), Apple Silicon.

```bash
swift build
.build/debug/offload doctor                       # what is available on this Mac
.build/debug/offload sources add-folder ~/Notes   # choose what to read
.build/debug/offload cycle                        # read → knowledge base → suggestions
.build/debug/offload search "booking code K7P2QX" # hybrid search
.build/debug/offload ask "what did I agree with my landlord?"
```

For notes of good quality, point the knowledge builder at a stronger model than the built-in one
(see *Models* below). Everything else works with the built-in model out of the box.

### The app

```bash
Scripts/make_app.sh release     # build/Offload.app (icon, Info.plist, ad-hoc signature)
Scripts/make_dmg.sh             # build/Offload-<version>.dmg with an Applications shortcut
open build/Offload.app
```

On first launch a short guide walks through what to read, which permissions to grant (and why), which model to use,
what leaves the Mac, and runs the first reading while showing what it is doing. Afterwards the sparkle in the menu bar
opens **Home** (what was read, source health in plain words, last run, one button to run or stop), **Knowledge** (browse
and edit notes, see the evidence behind each one, search by meaning or exact words, and a constellation view of how
notes link) and **Settings**. Click the notch (or press ⌘⇧Space) to open the assistant: **Ask** answers from your
memory, **Do** operates the Mac, asking before anything that cannot be undone. The interface is English only and
respects Reduce Motion and VoiceOver.

For distribution, pass `SIGN_IDENTITY="Developer ID Application: …"` to `make_app.sh` and notarize the result;
that needs your Apple Developer account and has not been done. Diagnostics are in `logs/app.log` inside the app's
data folder (Settings → Advanced → Show log files).

### More sources

```bash
offload sources notes on                              # Apple Notes (Full Disk Access)
offload sources siyuan ~/SiYuan/data                  # a SiYuan workspace's data folder
offload sources google login --client-id <ID> --client-secret-stdin    # Gmail + Google Calendar, read-only
```

Google needs an OAuth client of your own: in Google Cloud Console create a project, enable the Gmail and Calendar
APIs and create an OAuth client of type **Desktop app**. The token is kept in your Keychain.

## Commands

| | |
|---|---|
| `doctor`, `status` | environment checks; what has been read and indexed |
| `config …`, `sources …` | models, embeddings, privacy switch, folders, chats, mail, calendar, Apple Notes, SiYuan, Google |
| `cycle` | read what is new, update the knowledge base, prepare suggestions |
| `watch` | keep search following your folders as files are added, edited, moved or deleted (the app does this by default, and catches up at launch on what changed while it was closed; folders you have not read yet are left alone) |
| `search <q>` | `--mode hybrid\|lexical\|exact\|vector`, `--notes-only` |
| `ask <q>` | answer from memory, citing only the sources used |
| `draft` | draft a reply to text on stdin, or `--screen` to read the screen |
| `agent <task>` | tool-using assistant; `--computer` lets it operate the Mac |
| `suggestions` | review what was prepared overnight |
| `mcp` | MCP server on stdio (Claude Desktop / Claude Code) |
| `schedule install` | nightly run through a per-user LaunchAgent |
| `eval` | compare retrieval strategies on the bundled corpus |

### Use the knowledge base from Claude

```json
{ "mcpServers": { "offload": { "command": "/path/to/offload", "args": ["mcp"] } } }
```

Tools: `get_structure`, `get_files`, `search_memory`. It runs locally as a child process of the
client; there is no hosted relay.

## Models

Three independent roles, each configurable (`offload config model <role> --provider …`):

| role | does | default | recommendation |
|---|---|---|---|
| `triage` | reads every item, decides keep / junk / sensitive, writes the summary | built-in on-device model | keep it local |
| `knowledge` | merges summaries into notes | built-in | **use a stronger model** — see *Findings* |
| `assistant` | answers, drafts, runs the agent, prepares suggestions | built-in | any |

Providers: the built-in Apple on-device model; **your Claude subscription** (`--provider claude-cli`, needs the
`claude` tool and `claude auth login`); **your ChatGPT subscription** (`--provider codex-cli`, needs `codex login`;
not verified against the real tool); any OpenAI-compatible endpoint (OpenAI, OpenRouter, Ollama, LM Studio,
llama.cpp); and the Anthropic API. API keys go in the Keychain, never in the config file. Subscription models
and APIs are *hosted*: keep `triage` on the built-in or a local model, since it reads every item.

## Privacy model

* Raw source text is read on this Mac. The triage model never sees more than one item.
* Items the model calls sensitive are dropped entirely. A regex backstop (card numbers with Luhn
  check, SSNs, national IDs with checksum, passport numbers, API keys, passwords) drops any summary
  that leaks an identifier and **redacts** the same patterns from raw text before it is indexed.
* The knowledge base and the index live on this Mac (the index is excluded from backups and Spotlight).
* Raw excerpts (already redacted by the pass above) are returned to every consumer: local or hosted
  models and MCP clients alike. There is no switch to withhold them, so a hosted model that answers,
  drafts or acts receives those excerpts. If that is not acceptable, use local models for `assistant`
  and `knowledge`, and do not connect an MCP client.
* **Everything that leaves this Mac is scanned again.** Text sent to a hosted model (`RedactingModel`),
  to a remote embedding endpoint (`RedactingEmbedder`) or returned to an MCP client goes through the same
  `PIIScan.redact` first. That covers what never touches the index: the raw item given to `triage`,
  notes, on-screen text read by a reply draft or the agent, and search queries. Models and embedders on
  this Mac (on-device, or a server on localhost) receive text unchanged. Limits: it is the same regex
  set, so the same blind spots (names, addresses, free-text medical detail), and **screenshots are not
  scanned**. The pass can also over-redact, for example a long Luhn-valid order number.
* Chats are opt-in per chat; unselected chats are never read. Source databases are read from a copy.
* The agent asks before anything irreversible, can only open files Offload itself indexed, and
  treats everything it reads as data, not instructions.

## Layout

```
Sources/OffloadCore     the library (everything below is tested)
Sources/OffloadUI       notch assistant, first-run guide, Home, knowledge graph, glow (no dependency on Core)
Sources/OffloadPreviews renders every UI state to PNG (`offload-previews <dir>`) and the app icon (`--icon`)
  Store/      SQLite schema, items, chunks, notes, provenance links
  Text/       CJK-aware tokenizer, chunker, OCR
  Retrieval/  embedders, BM25/trigram/vector indexes, weighted-RRF hybrid searcher, eval harness
  Pipeline/   triage ("bouncer"), PII scan/redaction, incremental ingestion
  Sources/    files, iMessage, WhatsApp, Apple Mail (.emlx), Apple Notes, SiYuan, Gmail, Calendars (EventKit, Google)
  Vault/      knowledge builder: edit operations, validation, staging + atomic swap
  Agents/     memory service, Q&A, reply drafter, agent loop, proactive planner
  MCP/        stdio MCP server
  Runtime/    config, Keychain, wiring, the nightly cycle, health checks, reset, wording shared by app and CLI, log
  Scheduler/  LaunchAgent, power check
Sources/offload         the CLI
Sources/OffloadApp      the menu bar app
docs/ARCHITECTURE.md     design, decisions, measured results, known gaps
```

## Tests

```bash
swift test      # 173 tests (146 core, 27 UI); 4 use the real on-device model (skipped where unavailable);
                # 1 more calls the real `claude` CLI and runs only with OFFLOAD_LIVE_CLI=1
```

See `docs/ARCHITECTURE.md` for what is verified automatically, what was only smoke-tested, and what
could not be tested at all (live GUI interaction, global hotkey, computer control, real chat databases).
