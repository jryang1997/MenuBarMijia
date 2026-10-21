## Agent skills

### Issue tracker

GitHub Issues (`jryang1997/MenuBarMijia`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical roles (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context (`GLOSSARY.md` + `docs/adr/` at the repo root). See `docs/agents/domain.md`.

### Coding standards

Read `CODING_STANDARDS.md` when reviewing diffs (`/code-review`) or modifying synthesis, optimistic locking, hotkeys, or grid layout.

### Build & verification

Run `bash scripts/check.sh` for secret scan, mechanical lints, and `swift test`. Run `bash scripts/build_app.sh` to package, sign, and restart `MenuBarMijia.app`.
