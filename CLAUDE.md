## Codebase Index

This project has a living `docs/` folder with architecture, implementation, patterns, decisions, and changelog files.

### Session Start
- Read `docs/architecture.md` and `docs/implementation.md` before doing any work.
- These files contain the project map; do not re-scan the codebase from scratch.

### Red Flags - Don't Do These

Before searching the codebase, ask: **"Is this information in the docs already?"**

DON'T:
- Use Glob/Grep to explore or understand project structure.
- Run broad file searches to learn how things work.
- Search the codebase when a doc exists that explains it.
- Use codebase-indexer unless maintaining docs after changes.

DO:
- Start every session by reading `docs/architecture.md` and `docs/implementation.md`.
- Use targeted Glob/Grep only to find specific files.
- Check the docs before jumping into code exploration.
- Update docs after every feature or bugfix.

### Subagents

Tell subagents to read `docs/architecture.md` and `docs/implementation.md` first and not explore source files for information already covered there.

### After Every Feature or Bugfix
1. Identify changed files and inspect only those files and their direct neighbors.
2. Update only affected sections in the index docs.
3. Add an architectural decision only when the change made or reversed one.
4. Append a dated entry to `docs/changelog.md`.
