import Foundation
import OffloadCore

// A small hand-rolled argument parser keeps the build free of third-party dependencies.
struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    init(_ raw: [String], valueFlags: Set<String>) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a == "--" { positional.append(contentsOf: raw[(i + 1)...]); break }     // everything after is literal
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if valueFlags.contains(name), i + 1 < raw.count { flags[name] = raw[i + 1]; i += 1 } else { switches.insert(name) }
            } else { positional.append(a) }
            i += 1
        }
    }
    func has(_ s: String) -> Bool { switches.contains(s) }
}

func out(_ s: String = "") { print(s) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func fail(_ s: String) -> Never { err("error: " + s); exit(1) }

let usage = """
offload: a personal knowledge base built from your own files, mail, chats and calendar,
with hybrid (keyword + vector) retrieval. All data stays on this Mac unless you configure a hosted model.

USAGE: offload <command> [options]

SETUP
  doctor                                   check models, permissions and storage
  status                                   what has been read, indexed and prepared
  config show
  config model <triage|knowledge|assistant> --provider <apple|openai|anthropic|claude-cli|codex-cli> [--model M] [--base-url U] [--key-stdin] [--vision] [--memory-tools] [--agent-tools]
  config embedding --kind <apple-contextual|apple-sentence|hashing|openai> [--model M] [--base-url U] [--key-stdin]
  config vault <path>
  sources add-folder <path> | remove-folder <path> | list
  sources chats <imessage|whatsapp>        list chats you could opt into
  sources select <imessage|whatsapp> <chat-id>...
  sources mail|calendar|notes|gmail|gcal <on|off>
  sources siyuan <path-to-workspace/data | off>
  sources google <login|logout|status>   sign in with your own Google OAuth client

USE
  cycle [--max N] [--no-vault] [--no-proactive] [--quiet] [--require-ac]   read, update knowledge, prepare suggestions
  watch [--quiet-period SECONDS]           keep the index following your folders as files change (Ctrl-C to stop)
  search <query> [--mode hybrid|lexical|exact|vector] [--limit N] [--notes-only] [--local]
  ask <question>                           answer from your memory, with sources
  draft [--instruction T] [--screen]       draft a reply to text on stdin (or the screen)
  agent <task> [--computer] [--yes] [--max-steps N] [--mode read-only|write|act|prompt|allow] [--plan] [--no-mcp]
        [--allow RULE,...] [--deny RULE,...] [--ask RULE,...]   rules: tool, prefix*, tool(pattern*)
  tools [--computer]                       list what the assistant can do, and what each tool needs
  apps list | add <name> [--env K=V,K=keychain:acct] [--required] [--read-only] [--no-redact] [--timeout S] [--tools a,b] -- <command> [args...]
  apps remove <name> | enable <name> | disable <name> | test [name]   connect assistant apps (MCP servers)
  suggestions [list | dismiss <id> | done <id>]
  mcp                                      MCP server on stdio for Claude Desktop / Claude Code
  eval                                     compare retrieval strategies on the bundled corpus
  schedule <install|uninstall|status>      run the cycle nightly through launchd
  reset --yes                              delete the index (not your notes or source files)
"""

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { out(usage); exit(0) }
let rest = Array(argv.dropFirst())
let valueFlags: Set<String> = ["client-id", "max", "mode", "limit", "instruction", "provider", "model", "base-url", "kind", "max-steps", "quiet-period", "allow", "deny", "ask", "env", "timeout", "tools", "host"]
let args = Args(rest, valueFlags: valueFlags)

do {
    switch command {
    case "help", "-h", "--help": out(usage)
    case "doctor": try await Commands.doctor()
    case "status": try Commands.status()
    case "config": try Commands.config(args)
    case "sources": try await Commands.sources(args)
    case "cycle", "ingest": try await Commands.cycle(args, ingestOnly: command == "ingest")
    case "watch": try await Commands.watch(args)
    case "search": try await Commands.search(args)
    case "ask": try await Commands.ask(args)
    case "draft": try await Commands.draft(args)
    case "agent": try await Commands.agent(args)
    case "tools": try await Commands.tools(args)
    case "apps": try await Commands.apps(args, raw: rest)
    case "suggestions": try Commands.suggestions(args)
    case "mcp": try await Commands.mcp(args)
    case "eval": try await Commands.eval()
    case "schedule": try Commands.schedule(args)
    case "reset": try Commands.reset(args)
    default: fail("unknown command '\(command)'. Run `offload help`.")
    }
} catch {
    fail("\(error)")
}
