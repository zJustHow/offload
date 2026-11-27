# Manual testing in an isolated folder

`Scripts/sandbox.sh` builds a throwaway world under `.sandbox/` (ignored by git): fixture files, a tiny
SiYuan workspace, and an `OFFLOAD_HOME` holding the database, config and knowledge base. Nothing else on
the Mac is read or written, because the sandbox config only enables those two sources. Mail, Messages,
Apple Notes and calendar stay off.

```bash
Scripts/sandbox.sh init            # fixtures + fresh data folder (init --force recreates it)
Scripts/sandbox.sh run doctor      # any CLI command: run <args>
Scripts/sandbox.sh offline cycle   # same, with the network denied by the OS (sandbox-exec)
Scripts/sandbox.sh app             # the menu bar app against the sandbox (debug build)
Scripts/sandbox.sh live add|edit|move|delete   # change the fixtures while `run watch` is going
Scripts/sandbox.sh reindex         # drop the index, keep the notes
Scripts/sandbox.sh clean           # delete everything
```

Not covered by `OFFLOAD_HOME`, so do not do these here: `schedule install` (writes
`~/Library/LaunchAgents`), saving API keys (the Keychain), and turning on Mail / Messages / Notes /
Calendar in the app's first-run guide.

## What the fixtures are for

| fixture | exercises |
|---|---|
| `travel/sf-trip-notes.md` | exact-code search (`K7P2QX`), a note the user wrote |
| `housing/lease-notes.md`, `housing/租房沟通记录.md` | notes merged into `Home/Apartment.md`; Chinese tokenizing |
| `work/meeting-2026-11-18.md`, `inbox/dana-budget-email.md` | deadlines and a reply the user owes (drafts, suggestions) |
| `work/northwind-call-notes.md` | contains an instruction aimed at the AI: it must be treated as data |
| `private/tax-info.txt` | SSN, card number, bank account, password: must never become searchable |
| `noise/newsletter.txt` | junk |
| `work/*.csv`, `work/*.json`, `saved/*.html`, `saved/receipt.pdf`, `images/whiteboard.png` | the other file types (PNG goes through OCR) |
| `node_modules/`, `.hidden-note.md`, `empty.txt`, `archive.zip` | must be skipped |
| `siyuan/data/…` | SiYuan reader (a fixture in the documented format, not a real workspace) |

The on-device triage model is not deterministic and is strict: it drops anything that reads like an
automated email or a receipt, and the same file can be kept in one run and dropped in the next.
Check what it decided with:

```bash
sqlite3 .sandbox/home/offload.sqlite "select verdict, title, reason from items order by verdict"
```

## Checklist

1. **Read.** `Scripts/sandbox.sh offline cycle`, then `run status`. 15 items are listed (13 files and 2
   SiYuan documents), and the four skipped fixtures never appear.
2. **Privacy.** `run search "123-45-6789"`, `"Tr0ub4dor"`, `"4111 1111"`, `"SKIPME"` return no results.
   `run search K7P2QX` finds `sf-trip-notes.md`.
3. **Search modes.** `run search "landlord repairs heat" --mode lexical|exact|vector|hybrid`, and
   `--notes-only`. Chinese: `run search 暖气片`. Hybrid and vector always return the nearest neighbours,
   so use `--mode exact` when you want "no results" to mean something.
4. **Notes.** Open `.sandbox/home/vault` (or the app's Knowledge window). Each note links to the files it
   was written from.
5. **Ask.** `run ask "what did I agree with my landlord about repairs and rent?"` cites the lease note.
   `run ask "what are the terms of the Northwind contract?"` answers from the notes and does not act on the
   embedded instruction.
6. **Draft.** `echo "Dana: can you confirm the Q1 budget before Friday?" | Scripts/sandbox.sh run draft`.
7. **Agent.** `run agent "which seat do I have on my United flight?"`. Never pass `--computer` while
   testing: it operates the real screen.
8. **Suggestions.** `run suggestions`. With the built-in model on these fixtures this printed no
   suggestions (not investigated); try a stronger assistant model to see cards.
9. **MCP.** Send JSON-RPC lines to `run mcp`:
   ```bash
   printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
     '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"K7P2QX"}}}' | Scripts/sandbox.sh run mcp
   ```
10. **Live sync.** Run `cycle` once (watching skips folders that were never read), then in one terminal
    `Scripts/sandbox.sh run watch --quiet-period 2`, and in another run `live add`, `live edit`, `live move`
    and `live delete` in turn. Each change shows up in `run search` a few seconds later; a moved file keeps
    one entry under its new path. Output redirected to a file is buffered, so read the `synced:` lines in a
    terminal.
11. **Retrieval quality.** `run eval` prints the strategy comparison on the bundled corpus.
12. **The app.** `Scripts/sandbox.sh app`: the first-run guide opens (the sandbox config has not finished
    it). Check Home, Knowledge (browse, edit, search, graph), Settings, the notch (click it or press
    ⌘⇧Space) for Ask. For Reply (needs Screen Recording, and Accessibility for Insert): open a mail or chat
    with a message waiting, click into its reply field, press ⌘⇧Space, choose Reply, type an instruction such
    as "say Friday works" (or nothing) and press return. The draft should follow the instruction and not quote
    the notch's own text; Insert should paste it into the field you were in, without sending. For a fast look
    at one window: `OFFLOAD_DEBUG_WINDOW=home|onboarding|knowledge|suggestions|settings|chats
    Scripts/sandbox.sh app`.
13. **No network.** Repeat any command with `offline` instead of `run`. With the default built-in models
    nothing needs the network.
14. **Reset.** `reindex` then `cycle` rebuilds the index; `init --force` starts over.

## What this cannot test

* **Egress redaction end to end.** It only applies to hosted models and remote embedders, and an endpoint
  on `localhost`, `127.0.0.1` or `::1` counts as local and is not redacted. `EgressRedactionTests` covers
  it; a manual test needs a hosted provider, or a fake server on a non-loopback address.
* Mail, Messages, Apple Notes, Calendar and Google need real data or a real account; their readers are
  only covered by unit tests with fixtures.
* The global hotkeys, computer control and the notch's live animation still need a person at the Mac.
