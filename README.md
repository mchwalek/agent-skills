# agent-skills

Custom [Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) for use with Claude Code, opencode, Codex, and any other harness that supports the `SKILL.md` convention.

Each skill lives in its own folder under `skills/` with a `SKILL.md` containing YAML frontmatter (`name`, `description`) and instructions in the body.

## Skills

### `iis-express`

Use when installing, running, or configuring IIS Express, or debugging its errors — e.g. `applicationhost.config` questions, custom domains/host headers, 503 responses with `Server: Microsoft-HTTPAPI/2.0`, 400 Invalid Hostname, `bindingInformation` syntax, `netsh urlacl`, `appcmd`, or Visual Studio/Rider regenerating/reverting IIS Express config.

## Installation

Skills are just a folder containing a `SKILL.md`. Each harness scans its own skill directory (or lets you register an extra path in config), so installing a skill from this repo means getting `skills/<name>/` into that location — via clone, copy, or symlink.

### Clone the repo

```powershell
git clone https://github.com/<you>/agent-skills.git
```

```sh
git clone https://github.com/<you>/agent-skills.git
```

### Claude Code

Copy (or symlink) the skill folder into your personal skills directory:

```powershell
Copy-Item -Recurse .\agent-skills\skills\iis-express $env:USERPROFILE\.claude\skills\iis-express
```

```sh
cp -r agent-skills/skills/iis-express ~/.claude/skills/iis-express
```

### opencode

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

### Codex

Codex has no native skill-directory scanner — it reads `AGENTS.md` instead. Reference the skill from your project's or global `AGENTS.md` so Codex knows to consult it:

```markdown
## Skills

- IIS Express: see `agent-skills/skills/iis-express/SKILL.md` for install, config, and troubleshooting.
```

### Other harnesses

Any tool that scans a directory of `SKILL.md` files (or that you can point at an explicit list of skill paths) works the same way: copy or symlink `skills/<name>/` into wherever that harness looks, or reference the file path from whatever instruction file it reads at startup (e.g. its own `AGENTS.md`/`CLAUDE.md`-style entry point).
