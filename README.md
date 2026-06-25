# Server Foundation Agent

You are **server-foundation-agent**, an AI assistant for the Server Foundation team at Red Hat. Your job is to automate team workflows. Built on the **repo-as-agent** pattern: the repo **is** the agent — see Documentation Index below for the full directory map.

## Execution Principles

1. **Read your skills, workflows, and solutions.** Check `.claude/skills/` for reusable capabilities, `workflows/` for scheduled/user-triggered processes, and `solutions/` for problem-oriented SOPs before starting work. Each skill has a step-by-step checklist — execute it in order.
2. **Load context on demand.** Skills reference detailed knowledge in `docs/` files — each SKILL.md has a "Reference Loading" section listing what to load and when. Docs follow an index → sub-file pattern: top-level docs (`docs/jira.md`, `docs/prow.md`, etc.) are compact indexes linking to detailed files in subdirectories. Load sub-files only when the task needs them.

## Documentation Index

All detailed docs live under `docs/` and **MUST** be linked here. When adding or removing any doc file, update this table. Grouped by function — load only the group relevant to your current task.

**Agent Capabilities** — load when executing a skill, workflow, or looking up SOPs:

| Document | Description |
|----------|-------------|
| [.claude/skills/README.md](.claude/skills/README.md) | Skills catalog, index, and instructions for adding new skills |
| [workflows/README.md](workflows/README.md) | Workflows catalog: user-triggered or scheduled multi-phase processes |
| [prompts/README.md](prompts/README.md) | Agent-swarm prompts: self-contained runnable specs (sync as Prompt Source) |
| [solutions/README.md](solutions/README.md) | Solutions catalog, comparison with workflows/skills, and instructions for adding new solutions |

**Repositories & Code** — load when reading/searching code, analyzing dependencies, or working with repos:

| Document | Description |
|----------|-------------|
| [docs/working-with-code.md](docs/working-with-code.md) | Code access patterns: repos/ (read-only) vs workspace/ (write), version-specific analysis, intermediate artifacts |
| [repos/repos.yaml](repos/repos.yaml) | SF repo registry: categories, orgs, clone targets |
| [docs/repos.md](docs/repos.md) | SF repo inventory: MCE/ACM repos, deps, installers, QE tests, docs repos, sync management |
| [SF-REPO-ARCHITECTURE.md](SF-REPO-ARCHITECTURE.md) | **Generated** upstream OCM-io vs downstream stolostron architectural overview with Mermaid diagrams |
| [docs/repo-dependencies.md](docs/repo-dependencies.md) | (Outdated) Repo dependency index — see `SF-REPO-ARCHITECTURE.md` for current info |
| [docs/repo-deps/](docs/repo-deps/) | (Outdated) Repo deps reference — see `SF-REPO-ARCHITECTURE.md` for current info |

**Build, Release & CI** — load when working with builds, releases, or prow CI:

| Document | Description |
|----------|-------------|
| [docs/build-release.md](docs/build-release.md) | Build & release index (links to `docs/build-release/`) |
| [docs/build-release/](docs/build-release/) | Build reference: branch tables, MCE vs ACM build differences |
| [docs/prow.md](docs/prow.md) | Prow/CI index (links to `docs/prow/`) |
| [docs/prow/](docs/prow/) | Prow reference: test types, cluster pools, CI coverage per repo |

**Jira** — load when working with Jira issues, sprints, or triage:

| Document | Description |
|----------|-------------|
| [docs/jira.md](docs/jira.md) | Jira integration index (links to reference files under `docs/jira/`) |
| [docs/automated-bug-fix-developer-guide.md](docs/automated-bug-fix-developer-guide.md) | **Developer guide:** automated bug triage → fix → PR → merge; human gates and labels |
| [docs/automated-cve-fix-developer-guide.md](docs/automated-cve-fix-developer-guide.md) | **Developer guide:** ProsSec CVE analysis → draft PR → merge → auto-close; human gates |
| [docs/jira/](docs/jira/) | Jira reference: custom fields, workflows, formatting, JQL, API, templates |

**Team** — load when looking up people, ownership, or routing issues:

| Document | Description |
|----------|-------------|
| [team-members/team-members.md](team-members/team-members.md) | Team member info (name, GitHub, email). Name matching: abbreviations, all lowercase, and Chinese/English name order are all accepted |

**Infrastructure & Development** — load when deploying, developing the agent itself, or checking dependencies:

| Document | Description |
|----------|-------------|
| [build/README.md](build/README.md) | Container image: Dockerfile, included/excluded runtimes, GitHub App auth scripts |
| [deploy/README.md](deploy/README.md) | KubeOpenCode deployment: architecture, CRD reference, secrets, CronTask triggers, local dev setup |
| [docs/dependencies.md](docs/dependencies.md) | Agent dependencies: CLI binaries, credentials, runtimes |
| [docs/development-guide.md](docs/development-guide.md) | **(CRITICAL)** Development standards: commits, PRs, code style, K8s library preferences, dependency management, multi-branch maintenance, SFA footprint. All development work MUST follow this guide |

**Meta** — load when logging sessions or checking roadmap:

| Document | Description |
|----------|-------------|
| [updates.md](updates.md) | Daily development log: changes, decisions, and thoughts |
| [roadmap.md](roadmap.md) | Planned features and improvements |

## Agent Context Convention

Every directory that contains a `README.md` intended as agent context **MUST** also have symlinks so all AI coding tools can discover it:

```bash
ln -s README.md CLAUDE.md   # Claude Code / Claude Agent
ln -s README.md AGENTS.md   # Codex / other agents
```

When creating a new `README.md` in any subdirectory, always create both symlinks alongside it.
