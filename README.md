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

## Quick start

```bash
cpanm --installdeps .
export ANTHROPIC_API_KEY=...     # or OPENAI_API_KEY, GROQ_API_KEY, ...
perl -Ilib bin/raider            # REPL opens in the current directory
```

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
| `/quit` `/exit` `:q` | Leave                                               |

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

## Docker

A multi-stage `Dockerfile` is included. Two build targets:

- `runtime-root` — runs as root. Good for one-off sessions where ownership
  of files under `/work` doesn't matter.
- `runtime-user` — runs as a non-root user, uid/gid matchable to the host.
  Good for interactive use inside real project trees.

Build the user-target image with your current uid/gid so files written by
raider keep your ownership:

```bash
docker build \
  --target runtime-user \
  --build-arg RAIDER_UID=$(id -u) \
  --build-arg RAIDER_GID=$(id -g) \
  -t raider:latest .
```

Recommended shell alias — mounts `$PWD` into `/work` and forwards the
relevant API-key env vars:

```bash
raider() {
  docker run --rm -it \
    -v "$PWD:/work" \
    -v "$HOME/.raider_history:/home/raider/.raider_history" \
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
    raider:latest "$@"
}
```

Drop that into your `~/.bashrc` / `~/.zshrc`. You can then `cd` into any
project and just type `raider` — the container sees the project, uses the
API keys from your shell, and keeps your REPL history persistent across
sessions via the mounted `.raider_history` file.

For one-off root usage (no uid juggling, but files written as root):

```bash
docker build --target runtime-root -t raider:root .
alias raider='docker run --rm -it -v "$PWD:/work" \
  -e ANTHROPIC_API_KEY -e OPENAI_API_KEY raider:root'
```

## License

This software is copyright (c) 2026 by Torsten Raudssus.

It is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
