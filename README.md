# Claude Code Rite Workflow

> Universal Issue-Driven Development Workflow for Claude Code

[![Version](https://img.shields.io/badge/version-0.7.0-blue.svg)](https://github.com/asakaguchi/cc-rite-workflow/releases/tag/v0.7.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**English** | [日本語](README.ja.md)

## Demo

From Issue to PR — see Rite Workflow turn development into a *rite*. A ~100-second intro (English).

https://github.com/user-attachments/assets/d6e42398-4299-40ff-9bac-86e5333880b1

## Why "Rite"?

The name comes from the English word **rite**, meaning "ritual" or "ceremony." Issue-driven development — creating Issues, cutting branches, implementing, reviewing, and merging — is a set of practices that every team should follow as second nature. Rite Workflow embeds these practices as a repeatable ritual so they become the natural way you build software.

## Overview

**Claude Code Rite Workflow** is a Claude Code plugin that provides a complete Issue-driven development workflow. It works with any software development project regardless of language or framework.

### Features

- **Universal**: No dependency on specific tech stacks
- **Automated**: Auto-detection and auto-configuration
- **Customizable**: Flexible configuration via YAML
- **Integrated**: GitHub Projects
- **Smart Reviews**: Dynamic multi-reviewer code review with **Doc-Heavy PR Mode** for documentation-centric PRs. When a PR is detected as doc-heavy, the tech-writer reviewer verifies five doc-implementation consistency categories (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) using Grep/Read/Glob. See [`plugins/rite/skills/review/references/internal-consistency.md`](plugins/rite/skills/review/references/internal-consistency.md) for the full verification protocol
- **External Review Integration**: `/rite:fix` accepts PR URL or comment URL arguments, so output from external review tools can feed directly into the fix loop
- **Iteration Tracking**: Optional GitHub Projects Iteration field integration (auto-assign on `/rite:open`, `--sprint` / `--backlog` filters in `/rite:issue-list`)
- **Local Work Memory**: Compact-resilient work state management with lock/resuming support
- **Implementation Contract**: Structured Issue template format for clear specifications
- **Assumption Surfacing**: Before generating the Implementation Contract, `/rite:issue-create` surfaces the assumptions the model implicitly filled in and processes them in three categories — derivable (self-resolved from the repository/Wiki), user-specific decisions (confirmed with up to three recommended-option questions), and deferrable (documented as Assumptions / Open Questions in the Issue body). **Design principle**: questions are limited to information that exists only in the user's head; anything derivable from the repository or Wiki is resolved by the model. This keeps implicit guesses from being silently locked into the contract that drives the whole downstream pipeline
- **Experience Wiki**: LLM-driven project knowledge base, stored as an [OKF v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog)-conformant bundle (`type`/`okf_version` frontmatter, OKF index/log). Auto-ingests review/fix outcomes into topical pages and injects relevant heuristics at the start of each Issue (opt-out). The conformant bundle can be browsed as a concept graph with the upstream OKF static visualizer (not vendored; see `plugins/rite/references/wiki-patterns.md`)

## Installation

Rite Workflow uses a two-step installation: first register the marketplace, then install the plugin from it.

**Step 1**: Add the marketplace

```bash
/plugin marketplace add asakaguchi/cc-rite-workflow
```

**Step 2**: Install the plugin

```bash
/plugin install rite@rite-marketplace
```

**Verify installation**: Run `/rite:init` to confirm the plugin is working.

## Quick Start

```bash
/rite:init
```

This will:
1. Detect your project type
2. Set up GitHub Projects integration
3. Generate Issue/PR templates
4. Create configuration file

## Commands

| Command | Description |
|---------|-------------|
| `/rite:init` | Initial setup wizard |
| `/rite:init --upgrade` | Upgrade existing `rite-config.yml` to the latest schema version |
| `/rite:getting-started` | Interactive onboarding guide |
| `/rite:workflow` | Show workflow guide |
| `/rite:issue-list` | List Issues |
| `/rite:issue-create` | Create new Issue |
| `/rite:issue-update` | Update work memory |
| `/rite:issue-close` | Check Issue completion |
| `/rite:issue-edit` | Edit existing Issue interactively |
| `/rite:open` | Start work end-to-end (branch → plan → implement → lint → draft PR) |
| `/rite:iterate` | Loop review ⇄ fix until mergeable |
| `/rite:merge` | Squash-merge the PR |
| `/rite:pr-create` | Create draft PR |
| `/rite:ready` | Mark as Ready for review |
| `/rite:review` | Multi-reviewer review |
| `/rite:fix` | Address review feedback |
| `/rite:cleanup` | Post-merge cleanup |
| `/rite:investigate` | Structured code investigation |
| `/rite:lint` | Run quality checks |
| `/rite:template-reset` | Regenerate templates |
| `/rite:wiki-init` | Initialize Experience Wiki branch and directory layout |
| `/rite:wiki-query` | Query Wiki pages for heuristics matching keywords |
| `/rite:wiki-ingest` | Ingest raw sources (reviews, fixes, Issues) into Wiki pages |
| `/rite:wiki-lint` | Lint Wiki pages for contradictions, staleness, orphans, missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs |
| `/rite:resume` | Resume interrupted work |
| `/rite:skill-suggest` | Analyze context and suggest applicable skills |

## Workflow

```
/rite:issue-create → /rite:open (branch → plan → implement → /rite:lint → draft PR)
                  → /rite:iterate (review ⇄ fix loop until mergeable)
                  → /rite:ready → /rite:merge → /rite:cleanup
```

**Note:** The end-to-end flow is split across four single-responsibility commands. `/rite:open <issue>` handles branch creation, implementation, quality checks, and draft PR creation. `/rite:iterate <pr>` loops review and fix until mergeable. `/rite:ready <pr>` flips the PR to Ready for review. `/rite:merge <pr>` performs the squash-merge. If any step is interrupted (e.g. `Context limit reached`), run `/rite:resume` to recover.

Status Transitions:
```
Todo → In Progress → In Review → Done
 ↑         ↑            ↑         ↑
Create   Start Work   Set Ready  Merged
```

## Configuration

Create `rite-config.yml` in your project root:

```yaml
schema_version: 2

project:
  type: webapp  # generic | webapp | library | cli | documentation

github:
  projects:
    enabled: true

branch:
  base: "main"       # Base branch for feature branches (use "develop" for Git Flow)
  pattern: "{type}/issue-{number}-{slug}"

# Optional: Iteration (GitHub Projects Iteration field) integration
iteration:
  enabled: false  # Set true to enable
```

See [Configuration Reference](docs/CONFIGURATION.md) for all options.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Context limit reached` during long-running commands | Run `/clear` then `/rite:resume` to continue |

## Documentation

- [Full Specification](docs/SPEC.md)
- [Configuration Reference](docs/CONFIGURATION.md)

## Requirements

- [GitHub CLI (gh)](https://cli.github.com/) - Required for GitHub operations

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

Made with 📜 rite
