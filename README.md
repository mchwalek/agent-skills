# agent-skills

Custom [Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) for use with Claude Code, opencode, Codex, and any other harness that supports the `SKILL.md` convention.

Each skill lives in its own folder under `skills/` with a `SKILL.md` containing YAML frontmatter (`name`, `description`) and instructions in the body.

## Skills

### `iis-express`

Use when installing, running, or configuring IIS Express, or debugging its errors — e.g. `applicationhost.config` questions, custom domains/host headers, 503 responses with `Server: Microsoft-HTTPAPI/2.0`, 400 Invalid Hostname, `bindingInformation` syntax, `netsh urlacl`, `appcmd`, or Visual Studio/Rider regenerating/reverting IIS Express config.

### `markdown-to-google-docs`

Use when publishing markdown to a natively-formatted Google Doc (real heading styles, tables, bullets, inline diagrams) from Windows/PowerShell via the `gws` CLI, or when debugging a published doc that shows literal markdown asterisks, scrambled table cells, mojibake, an empty body, or an unreadable shrunken diagram — also when `gws --json` quoting breaks on Windows (`"| was unexpected at this time"`, `batchUpdate` oneof errors, Docs write-quota 429s).

### `orchestrating-plan-execution`

Use when the user approves an approach and wants it implemented end to end, particularly when they say you should not write the code yourself — e.g. "Let's go with Approach B", "proceed with the plan", "implement this and confirm with tests". The orchestrator holds the plan; subagents write the code; state lives on disk.

## Installation

### Install with the `skills` CLI (recommended)

[`npx skills`](https://github.com/vercel-labs/skills) supports Claude Code, opencode, Codex, Cursor, and 70+ other agents — it detects installed agents and symlinks skills into the right directory for you.

```sh
# Interactive: pick skills and agents
npx skills add mchwalek/agent-skills

# List available skills without installing
npx skills add mchwalek/agent-skills --list

# Install a specific skill to a specific agent
npx skills add mchwalek/agent-skills --skill iis-express -a claude-code

# Try a skill once without installing
npx skills use mchwalek/agent-skills --skill iis-express | claude
```

### Manual install

Skills are just a folder containing a `SKILL.md`. Each harness scans its own skill directory (or lets you register an extra path in config), so installing a skill from this repo means getting `skills/<name>/` into that location — via clone, copy, or symlink.

#### Clone the repo

```sh
git clone https://github.com/mchwalek/agent-skills.git
```

#### Claude Code

Copy (or symlink) the skill folder into your personal skills directory:

```powershell
Copy-Item -Recurse .\agent-skills\skills\iis-express $env:USERPROFILE\.claude\skills\iis-express
```

```sh
cp -r agent-skills/skills/iis-express ~/.claude/skills/iis-express
```

#### opencode

opencode scans `~/.config/opencode/skill/` (or `.opencode/skill/` per-project) for `**/SKILL.md`, and also auto-loads anything under `~/.claude/skills/` — so if you already installed for Claude Code above, opencode picks it up automatically. To install directly for opencode only:

```powershell
Copy-Item -Recurse .\agent-skills\skills\iis-express $env:USERPROFILE\.config\opencode\skill\iis-express
```

```sh
cp -r agent-skills/skills/iis-express ~/.config/opencode/skill/iis-express
```

Alternatively, point opencode at the cloned repo directly without copying, via `skills.paths` in `opencode.json`:

```json
{
  "skills": {
    "paths": ["/absolute/path/to/agent-skills/skills"]
  }
}
```

#### Codex

Codex has no native skill-directory scanner — it reads `AGENTS.md` instead. Reference the skill from your project's or global `AGENTS.md` so Codex knows to consult it:

```markdown
## Skills

- IIS Express: see `agent-skills/skills/iis-express/SKILL.md` for install, config, and troubleshooting.
```

#### Other harnesses

Any tool that scans a directory of `SKILL.md` files (or that you can point at an explicit list of skill paths) works the same way: copy or symlink `skills/<name>/` into wherever that harness looks, or reference the file path from whatever instruction file it reads at startup (e.g. its own `AGENTS.md`/`CLAUDE.md`-style entry point).
