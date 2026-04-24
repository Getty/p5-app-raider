# App::Raider

An autonomous command-line agent in Perl. Wraps [Langertha](https://metacpan.org/dist/Langertha)'s
`Raider` with a practical toolbox (filesystem, bash, web search, web fetch)
and drops you into a REPL where a viking shield-maiden named **Langertha**
does the work.

```
             __     __
.----.---.-.|__|.--|  |.-----.----.
|   _|  _  ||  ||  _  ||  -__|   _|
|__| |___._||__||_____||_____|__|
 perl agent - powered by Langertha
```

## Why it exists

`raider` is what you get when you strip an AI coding tool down to the
essential loop: one terminal, one conversation, a small fixed toolbox, and
15+ LLM providers wired up the same way. No daemon, no SaaS, no IDE plugin.

- **Local filesystem access** — confined to a chosen root so the agent
  cannot wander outside the project.
- **Full shell** — the `bash` tool runs real commands; the agent can
  `git status`, `prove`, `grep`, whatever.
- **Web search + fetch** — DuckDuckGo out of the box, Brave/Serper/Google
  added automatically when their API keys are in the environment.
- **Any provider** — Anthropic, OpenAI, DeepSeek, Groq, Mistral, Gemini,
  MiniMax, Cerebras, OpenRouter, Ollama, ... whichever one you have a key
  for.
- **Custom persona** — drop a `.raider.md` into the working directory to
  rename Langertha, reshape her, or replace her entirely. A built-in
  prompt-builder helps you craft one interactively.
- **Transparent** — live trace of every tool call, running token counter,
  history-size indicator, automatic context compression.
- **Skill aware** — `--claude` / `--openai` load your project's `CLAUDE.md`,
  `AGENTS.md`, and `.claude/skills/*/SKILL.md` directly into the mission,
  remembered in `.raider.yml` after the first use.
- **Packs** — toggleable persona + power bundles (`caveman`, `polite`,
  `teacher`, `git-guru`, `testing-fu`, `perl-hacker`). Drop your own
  under `share/packs/` or point `packs:` in `.raider.yml` at a directory.
- **Perl-native** — `--perl` unlocks `perl_eval` / `perl_check` /
  `perl_cpanm`, a private `local::lib` under `.raider/lib/`, and
  auto-recovery on missing modules (the agent installs, retries, moves on).
- **Raider Hall** — `raider-hall` is a lightweight daemon that spawns
  other raiders on demand, on cron, on a Telegram message, or over the
  Agent Client Protocol. See [Raider Hall](#raider-hall) below.

## Quick start

From CPAN:

```bash
cpanm App::Raider
export ANTHROPIC_API_KEY=...     # or OPENAI_API_KEY, GROQ_API_KEY, ...
raider                           # REPL opens in the current directory
```

From a git checkout:

```bash
cpanm --installdeps .
perl -Ilib bin/raider
```

Or via Docker — no Perl toolchain required:

```bash
docker pull raudssus/raider
docker run --rm -it -v "$PWD:/work" -e ANTHROPIC_API_KEY raudssus/raider
```

See the [Docker](#docker) section below for the recommended shell alias.

Then tell Langertha what to do:

```
raider> lies die Changes und schreib mir ne kurze summary
raider> such im web nach "Perl 5.40 release notes", dann hol den ersten treffer
raider> prove -l t/ laufen, falls was rot ist report zurück
```

One-shot usage (no REPL):

```bash
raider "check git status and summarize"
raider --json "count the .pm files in lib" | jq .
```

## How it picks an engine

Zero configuration: the first `*_API_KEY` found in the environment decides
the engine, and a cheap model is used by default.

| Engine    | Env var               | Default model                  |
|-----------|-----------------------|--------------------------------|
| anthropic | `ANTHROPIC_API_KEY`   | `claude-haiku-4-5`             |
| openai    | `OPENAI_API_KEY`      | `gpt-4o-mini`                  |
| deepseek  | `DEEPSEEK_API_KEY`    | `deepseek-chat`                |
| groq      | `GROQ_API_KEY`        | `llama-3.3-70b-versatile`      |
| mistral   | `MISTRAL_API_KEY`     | `mistral-small-latest`         |
| gemini    | `GEMINI_API_KEY`      | `gemini-2.5-flash`             |
| cerebras  | `CEREBRAS_API_KEY`    | `llama3.1-8b`                  |
| openrouter| `OPENROUTER_API_KEY`  | *(must set `-m`)*              |
| ollama    | *(none — local)*      | *(must set `-m` and `--root`)* |

Override with `-e <engine>`, `-m <model>`, or `-k <key>`.

Raider currently uses provider APIs. Claude Code subscription/OAuth
credentials from `~/.claude` are not read or reused as Anthropic API
credentials.

## Tools the agent has

| Tool                                            | Notes                                       |
|-------------------------------------------------|---------------------------------------------|
| `list_files(path)`                              | Directory listing, dirs suffixed with `/`   |
| `read_file(path)`                               | Full text file                              |
| `write_file(path, content)`                     | Creates parents, overwrites                 |
| `edit_file(path, old_string, new_string)`       | Exact unique-match substitution             |
| `bash(command, [working_directory], [timeout])` | `bash -c $command`, captures out/err/exit   |
| `web_search(query, [limit])`                    | Multi-provider, rank-fused                  |
| `web_fetch(url, [as_html])`                     | HTML flattened to text by default           |

Filesystem tools are confined to the `--root` directory. `bash` inherits
it as its working directory.

## Persona customization

By default, Langertha speaks in a terse "caveman mode" (drop articles,
drop filler, technical terms exact) and runs without any pause/abort/yield
tool — when she has nothing else to say she hands control back to the
prompt, and your next line continues the conversation.

Rename her, rewrite her personality, or swap her for another character
entirely by placing a `.raider.md` in the working directory:

```markdown
# Name: Helga
# Tone: dry, professional, never chatty
# Specialty: Perl 5 and Dist::Zilla

Always run prove -l t/ before reporting a task complete.
Never touch anything under third-party/ without explicit permission.
```

Or build it interactively with the slash command:

```
raider> /prompt
raider:prompt> mach mir eine persona die nur rust reviews macht und englisch spricht
raider:prompt> /done
```

## Loading project skills into the mission

`raider` can preload per-tool agent files and skill collections from the
working directory. Two profile flags do the heavy lifting:

```bash
raider --claude   # CLAUDE.md + .claude/skills/*/SKILL.md
raider --openai   # AGENTS.md (cross-tool / Codex convention; alias --codex)
```

These profile flags **persist** to `.raider.yml` on first use — the banner
shows `(saved)` next to each newly-persisted profile. On the next run the
same skills load automatically without the flag:

```
profiles: claude (saved), openai
skills:   3 loaded (CLAUDE.md, AGENTS.md, perl-core)
```

If a well-known file is present but its profile isn't active, the banner
says so:

```
skills:   none
          seeing CLAUDE.md, ignoring (use --claude to load)
```

Extra skill directories (plain markdown) can be added with
`--skills DIR` (repeatable), or via the `skills:` key in `.raider.yml`:

```yaml
skills:
  - claude
  - openai
  - docs/house-rules      # loads *.md from this dir
  - type: dir
    path: team/handbook
    glob: '*.md'
```

YAML frontmatter (`---...---`) in a `SKILL.md` is stripped automatically
when the body is injected into the mission.

## Engine options: `.raider.yml`

Drop a `.raider.yml` in the working directory to set engine-level
attributes (temperature, response_size, seed, ...). Flat form:

```yaml
temperature: 0.2
response_size: 2048
```

Or per-engine with a shared default layer:

```yaml
default:
  temperature: 0.3
anthropic:
  temperature: 0.7
  response_size: 8192
openai:
  temperature: 0.5
```

CLI `-o key=value` (repeatable) overrides the file:

```bash
raider -o temperature=0.1 -o response_size=4096
```

Values are auto-coerced: `0.2` → Float, `4096` → Int, `true`/`false` → 1/0.

## Slash commands (REPL)

| Command              | Does                                                |
|----------------------|-----------------------------------------------------|
| `/help`              | Command list                                        |
| `/clear`             | Reset conversation history and token counters       |
| `/metrics`           | Cumulative raid metrics                             |
| `/stats`             | Tokens in / out / total this session                |
| `/reload`            | Re-read `.raider.md`, hot-swap the mission          |
| `/prompt`            | Launch the prompt-builder (edits `.raider.md`)      |
| `/skill [PATH]`      | Export plain markdown how-to-use-raider doc         |
| `/skill-claude [PATH]` | Export Claude Code SKILL.md with YAML frontmatter |
| `/model [NAME]`      | Show or save the model for the next run             |
| `/model list [FILTER]` | List models reported by the active engine         |
| `/packs`             | List available packs and whether they are active    |
| `/pack on/off NAME`  | Enable or disable a pack                            |
| `/pack NAME`         | Toggle a pack                                       |
| `/quit` `/exit` `:q` | Leave                                               |

## Packs — persona and power bundles

Packs are small, toggleable modifiers stacked on top of Langertha's
default mission. Two flavors:

- **persona** packs (exclusive group — one active at a time):
  `caveman` *(default)*, `polite`, `teacher`.
- **power** packs (stackable):
  `git-guru`, `testing-fu`, `perl-hacker`.

From the REPL:

```
raider> /packs                       # list all with state
raider> /pack on git-guru            # enable a power pack
raider> /polite                      # same as /pack on polite — swaps caveman off
raider> /pack off teacher            # turn one off explicitly
```

Active packs persist to `.raider.yml`:

```yaml
packs:
  - polite
  - git-guru
  - testing-fu
```

Drop your own under `share/packs/<name>/` with a `SKILL.md` plus an
optional `pack.yml`:

```yaml
# share/packs/my-rules/pack.yml
exclusive_group: persona     # or 'power' (default)
mcp: [perl, web]             # extra MCPs to load with this pack
engine_options:
  temperature: 0.2
```

The `SKILL.md` body is appended to the mission when the pack is active.

## Perl-native tools

`--perl` (or `perl: true` in `.raider.yml`) adds three MCP tools the
agent can use directly:

| Tool                             | Notes                                              |
|----------------------------------|----------------------------------------------------|
| `perl_eval(code, [stdin])`       | Ephemeral interpreter; captures stdout/stderr/exit |
| `perl_check(code)`               | `perl -c` — syntax check without executing         |
| `perl_cpanm(module, [options])`  | Install into the raider's private `local::lib`     |

All installs land in a lib the raider owns — `.raider/lib/` next to the
working directory by default, or `.raider-hall/raiders/<name>/lib/` when
running under a hall (or a shared `.raider-hall/longhouse/lib/` if
`longhouse: true` in `.raider-hall.yml`). The raider process itself
imports the lib at startup, so freshly-installed modules are visible to
subsequent `perl_eval` calls without restart.

`perl_eval` also auto-recovers from `Can't locate X/Y.pm in @INC`
errors: it installs the missing module once, retries the eval, and
returns `auto_installed: [...]` in the result so the model knows what
happened. It never loops.

```
raider --perl
raider> welche version von DBI hab ich?
[perl_eval] use DBI; print $DBI::VERSION    →  1.644
raider> installier JSON::XS und mach einen quick-smoketest
[perl_cpanm JSON::XS]                        →  installed 4.03
[perl_eval] use JSON::XS; ...                →  {"ok":1}
```

## Raider Hall

`raider-hall` is a small daemon that spawns other raiders on demand.
Built for things a single one-shot REPL can't do:

- **Named raiders** — `bjorn`, `ragnar`, `lagertha` with their own
  persona, engine, model, and pack set. Defined once in
  `.raider-hall.yml`.
- **`1name` singletons** — spawn as `1bjorn` to force at most one
  instance of Björn at a time. Overlapping missions queue FIFO on his
  slot (queue persists to disk across restarts).
- **Cron** — `cron:` entries fire spawns on a schedule, non-blocking.
  Opt-in `coalesce: true` drops a run if the previous one is still
  going; default falls through to 1name queueing.
- **Telegram** — multi-bot long-poll; each bot has its own allowlist,
  routing map, and message history. `telegram_reply` lands as an MCP
  tool in the spawned raider so the agent can answer back.
- **MCP adapter** — exposes `spawn_raider`, `list_raiders`,
  `schedule_raid`, `cancel_job`, `send_telegram`, `hall_status` as MCP
  tools for other agents to drive the hall.
- **ACP adapter** — ships an [Agent Client Protocol][acp] server over
  TCP so Zed (and any other ACP-capable client) can treat a hall as a
  remote agent. See [ACP](#agent-client-protocol-acp) below.

### Quick start

```bash
mkdir my-village && cd my-village
raider hall init --name bjorn --engine anthropic --persona caveman
raider hall add-raider lagertha --engine openai --persona polite --pack git-guru
raider hall start --daemon                      # foreground: omit --daemon
raider hall ps
raider hall spawn bjorn "summarise yesterday's git log"
raider hall spawn 1lagertha "review the last PR diff"
raider hall logs <id>
raider hall kill <id>
raider hall stop
```

For a fuller walkthrough — three raiders, a cron entry, ACP open,
Telegram commented out — copy
[`examples/multi-raider-hall/`](examples/multi-raider-hall/) and read
the README in it.

### `.raider-hall.yml`

```yaml
longhouse: false                    # true: share one local::lib across raiders
preferred_lib_target: .raider-hall/lib
raiders:
  bjorn:
    engine: anthropic
    persona: caveman
    packs: [git-guru]
    mcp: []
  lagertha:
    engine: openai
    model: gpt-4o-mini
    persona: polite
    packs: [testing-fu, perl-hacker]

cron:
  - name: 1bjorn                    # singleton — queues if still running
    cron: '*/15 * * * *'
    mission: "check the CI dashboard, post a line in #eng-alerts if anything is red"
  - name: lagertha
    cron: '0 9 * * MON'
    mission: "compile last week's release notes"
    coalesce: true                  # drop this run if the previous is still going

telegram:
  bots:
    ops:
      token: '123456:ABC...'
      allowlist: [42, 99]
      routing:
        42: bjorn                   # chat 42 maps to Björn
        '*': lagertha               # everyone else lands on Lagertha

acp:
  port: 38421
  host: 127.0.0.1

mcp:
  enable: true                      # exposes .raider-hall.mcp socket
```

### Agent Client Protocol (ACP)

With `acp.port` set (or `--acp-port N` on `raider hall start`), the
hall listens for ACP clients over TCP. Methods implemented in this
release:

| Method           | Maps to                                                     |
|------------------|-------------------------------------------------------------|
| `initialize`     | Returns protocol version + agent capabilities               |
| `session/new`    | Creates an ACP session bound to a configured raider name    |
| `session/prompt` | Spawns the raider with the user turn; streams back events   |
| `session/cancel` | Sends `TERM` to the current raider                          |

Events from the hall bus (`raider.*`) are forwarded to the client as
`session/update` notifications. A richer mapping (tool_call →
`tool_use` blocks, segmented `agent_message_chunk`s, `fs/*` push edits)
is on the roadmap.

### ACP client — `raider acp`

The same binary ships a small ACP client so you can drive any
conforming ACP agent (the hall or someone else's) without wiring up a
separate tool:

```bash
# Handshake / dump capabilities
raider acp ping 127.0.0.1:38421

# One-shot — open a session, send one prompt, exit on stopReason
raider acp prompt 127.0.0.1:38421 --raider bjorn \
    "summarise the last 10 commits"

# Interactive REPL — session stays alive between turns, /cancel
# sends session/cancel, /quit exits
raider acp connect 127.0.0.1:38421 --raider lagertha
```

`--json` on `prompt` / `connect` also streams the raw JSON-RPC frames
to stderr, which is handy when debugging the server side.

Under the hood this is just `App::Raider::ACP::Client` — a tiny
blocking JSON-RPC 2.0 line-framed client — so you can embed the same
thing into your own Perl without shelling out.

### Hall events

Every state change is emitted on the hall's event bus (JSONL over the
unix socket). Subscribe with `{"type":"subscribe","payload":{"filter":"raider."}}`.

| Event                   | When                                            |
|-------------------------|-------------------------------------------------|
| `hall.started`          | Daemon ready                                    |
| `hall.stopping`         | Shutdown in progress                            |
| `raider.spawned`        | New child started                               |
| `raider.queued`         | 1name slot busy, mission queued                 |
| `raider.done`           | Child exited                                    |
| `raider.failed`         | Child crashed / signaled                        |
| `cron.fired`            | Scheduled raid fired                            |
| `cron.coalesced`        | Scheduled raid dropped (previous still running) |
| `telegram.in`           | Incoming Telegram message                       |
| `telegram.poll_error`   | Long-poll HTTP failure                          |
| `acp.started`           | ACP listener bound                              |

### systemd

**Native install** — raider is on the host as a regular binary:

```bash
raider hall install                         # default unit
raider hall install --acp-port 38421        # with ACP exposed
systemctl --user daemon-reload
systemctl --user enable --now raider-hall
```

**Docker install** — raider only lives inside a container image.
`systemd` lives on the *host*, so the unit file has to land in the
host's `~/.config/systemd/user/`. Two ways:

*(a) From the host, if raider is installed on the host too:*

```bash
raider hall install --docker \
    --image raudssus/raider:latest \
    --acp-port 38421
systemctl --user daemon-reload
systemctl --user enable --now raider-hall
```

*(b) From inside the container* — raider uses the bind-mounted working
directory as the drop-off point, so the unit appears in your project
tree and you just copy it:

```bash
# inside the container:
raider hall install --docker \
    --image raudssus/raider:latest \
    --acp-port 38421
# → writes .raider-hall/systemd/raider-hall.service

# on the host:
cp .raider-hall/systemd/raider-hall.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now raider-hall
```

`--stdout` on its own skips writing entirely and just prints the unit
to stdout.

The generated unit runs `docker run --rm --name raider-hall -v
$PWD:/work …`, forwards every known `*_API_KEY` env var, and
publishes the ACP port with `-p`. With `--acp-port` set, it also
passes `--acp-host 0.0.0.0` to the in-container raider so the
listener is reachable outside the container.

[acp]: https://agentclientprotocol.com/

## Context window and rate limits

The built-in defaults try to keep long sessions smooth:

- `max_context_tokens = 40000` (effective ceiling before compression)
- `context_compress_threshold = 0.7` (compress at 70%)
- `max_iterations = 10000` (effectively unlimited — the model decides
  when the task is done)

When the running prompt exceeds the threshold, `Langertha::Raider`
automatically summarizes the history into a compressed context, which
keeps most providers comfortably under their per-minute input-token
limits. Each meta-line after a raid shows `history N msgs, X/Y tok (Z%)`
so you can see how close you are.

## Options reference

```
raider [options] [prompt...]

  -e, --engine NAME        anthropic, openai, deepseek, groq, mistral,
                           gemini, minimax, cerebras, openrouter, ollama
                           (default: auto-detected from env)
  -m, --model NAME         Model identifier (engine-specific cheap default)
  -k, --api-key KEY        API key (overrides *_API_KEY env var)
  -o, --option KEY=VALUE   Engine attribute (repeatable), e.g. -o temperature=0.2
  -r, --root DIR           Working directory (default: cwd)
  -M, --mission TEXT       Override the system prompt entirely
  -i, --interactive        Force REPL mode
      --json               One-shot JSON output
      --max-iterations N   Hard safety cap on tool rounds per raid
      --no-color           Disable ANSI colors
      --no-trace           Hide live tool-call progress output
      --perl               Enable perl_eval / perl_check / perl_cpanm tools
      --pack NAME          Enable a bundled pack (repeatable)
      --customize-prompt   Launch the prompt-builder at startup
      --claude             Load CLAUDE.md + .claude/skills/*/SKILL.md
      --openai / --codex   Load AGENTS.md
      --skills DIR         Load *.md from DIR (repeatable)
      --export-skill [P]   Write the plain-markdown how-to-use doc and exit
      --export-claude-skill [P]
                           Write .claude/skills/app-raider/SKILL.md and exit
  -h, --help               Show help
```

When STDIN is a TTY and nothing is piped or on argv, `raider` drops into
the REPL automatically.

## Environment variables

| Var                     | Purpose                                                    |
|-------------------------|------------------------------------------------------------|
| `ANTHROPIC_API_KEY`     | Anthropic (Claude models)                                  |
| `OPENAI_API_KEY`        | OpenAI                                                     |
| `DEEPSEEK_API_KEY`      | DeepSeek                                                   |
| `GROQ_API_KEY`          | Groq                                                       |
| `MISTRAL_API_KEY`       | Mistral                                                    |
| `GEMINI_API_KEY`        | Google Gemini                                              |
| `MINIMAX_API_KEY`       | MiniMax                                                    |
| `CEREBRAS_API_KEY`      | Cerebras                                                   |
| `OPENROUTER_API_KEY`    | OpenRouter                                                 |
| `BRAVE_API_KEY`         | Adds Brave to `web_search`                                 |
| `SERPER_API_KEY`        | Adds Serper to `web_search`                                |
| `GOOGLE_API_KEY` + `GOOGLE_CSE_ID` | Adds Google CSE to `web_search`                 |
| `ANSI_COLORS_DISABLED`  | Turn off coloring globally                                 |

## Development

```bash
dzil test           # Build and run the test suite
prove -l t/         # Alternative
prove -lv t/10_filetools.t   # Single test, verbose
```

Build system: [Dist::Zilla](https://metacpan.org/dist/Dist-Zilla) with
`[@Author::GETTY]`.

A checked-in `cpanfile.snapshot` pins the exact dependency versions that
last produced a known-good build. Docker uses that snapshot through
[`cpm`](https://metacpan.org/dist/App-cpm) with the MetaCPAN resolver.
For local non-Docker installs you can still use
[Carton](https://metacpan.org/dist/Carton):

```bash
carton install --deployment   # installs into ./local/ from snapshot
carton exec -- perl -Ilib bin/raider
```

Refresh the snapshot whenever `cpanfile` changes:

```bash
carton install                # updates cpanfile.snapshot
```

## Docker

A prebuilt image is published on Docker Hub as
[**`raudssus/raider`**](https://hub.docker.com/r/raudssus/raider). The
bundled `Dockerfile` is multi-stage with two runtime targets:

- `runtime-root` *(default on Docker Hub, tag `:latest` / `:<version>`)* —
  runs as root. Good for one-off sessions where ownership of files under
  `/work` doesn't matter.
- `runtime-user` — runs as a non-root user, uid/gid matchable to the host.
  Good for interactive use inside real project trees.

### Pull from Docker Hub

```bash
docker pull raudssus/raider              # rolling latest
docker pull raudssus/raider:0.002        # pinned version
```

Recommended shell alias — mounts `$PWD` into `/work` and forwards the
relevant API-key env vars:

```bash
raider() {
  docker run --rm -it \
    -v "$PWD:/work" \
    -v "$HOME/.raider_history:/root/.raider_history" \
    -e ANTHROPIC_API_KEY \
    -e OPENAI_API_KEY \
    -e DEEPSEEK_API_KEY \
    -e GROQ_API_KEY \
    -e MISTRAL_API_KEY \
    -e GEMINI_API_KEY \
    -e MINIMAX_API_KEY \
    -e CEREBRAS_API_KEY \
    -e OPENROUTER_API_KEY \
    -e BRAVE_API_KEY -e SERPER_API_KEY \
    -e GOOGLE_API_KEY -e GOOGLE_CSE_ID \
    raudssus/raider "$@"
}
```

Drop that into your `~/.bashrc` / `~/.zshrc`. You can then `cd` into any
project and just type `raider` — the container sees the project, uses the
API keys from your shell, and keeps your REPL history persistent across
sessions via the mounted `.raider_history` file.

### Build locally

The Dockerfile installs from the Dist::Zilla-built distribution directory,
not from a tarball in the build context. Build the dist directory first and
use that as the Docker context:

```bash
dzil build
VERSION=$(perl -Ilib -MApp::Raider -E 'say $App::Raider::VERSION')
```

Build the user-target image with your current uid/gid so files written by
raider keep your ownership:

```bash
docker build \
  --build-arg RAIDER_VERSION=$VERSION \
  --target runtime-user \
  --build-arg RAIDER_UID=$(id -u) \
  --build-arg RAIDER_GID=$(id -g) \
  -t raider:local App-Raider-$VERSION
```

For a local root image:

```bash
docker build --build-arg RAIDER_VERSION=$VERSION \
  --target runtime-root -t raider:local-root App-Raider-$VERSION
```

### Publishing the Docker Hub image (maintainer)

Automated — `dist.ini` declares `run_after_release` hooks that, after
`dzil release` uploads the tarball to CPAN, also:

1. Create (or update) the matching GitHub release and attach the
   `App-Raider-%v.tar.gz` as an asset.
2. `docker build` the Dist::Zilla build directory with the `runtime-root`
   target tagged
   `raudssus/raider:%v` and `raudssus/raider:latest`.
3. `docker push` both tags.

So the full release is just:

```bash
dzil release
```

You must be logged in to Docker Hub (`docker login`) and GitHub
(`gh auth login`) for the hooks to succeed. Extra flags can be injected:

```bash
RAIDER_DOCKER_BUILD_ARGS='--platform linux/amd64,linux/arm64' dzil release
```

Manual fallback (if the hooks are skipped — e.g. `dzil release --no-release` is
obviously not a thing, but for rebuilding an old release):

```bash
VERSION=0.004
dzil build
docker build \
  --build-arg RAIDER_VERSION=$VERSION \
  --target runtime-root \
  -t raudssus/raider:$VERSION -t raudssus/raider:latest \
  App-Raider-$VERSION
docker push raudssus/raider:$VERSION raudssus/raider:latest
```

## License

This software is copyright (c) 2026 by Torsten Raudssus.

It is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
