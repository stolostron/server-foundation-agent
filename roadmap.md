# Server Foundation Agent - Roadmap

Planned features and improvements. Items are roughly prioritized.

---

## 1. Integrate Google Workspace CLI

Integrate GWS CLI to enable agent interaction with Google Workspace (Gmail, Calendar, Drive, Docs). Opens up workflows like reading team emails, scheduling, and document collaboration.

## 2. Knowledge Base: Workflows & Solutions

Long-term, ongoing effort to build, maintain, and update the agent's knowledge base — `solutions/`, `workflows/`, and `docs/`. The more domain knowledge the agent has, the more autonomously it can operate. Includes documenting common debugging patterns, release procedures, CI/CD recipes, and team conventions.

## 3. Solution staleness workflow

Periodic scan of `solutions/` for `last_verified` older than 6 months and report for human review (described in [solutions/README.md](solutions/README.md) lifecycle, not yet implemented).
