---
name: map-dotfiles
description: Cross-repo map entry — carpet-stain/dotfiles' backlog facts live in its own memory store
metadata:
  type: reference
---

- Repo: `carpet-stain/dotfiles`
- Memory store: `.claude/agent-memory/backlog-manager/` (tracked; pointer contract per dotfiles ADR-0033)
- Hook: personal macOS/Debian dotfiles; much of its backlog is meta (workflow/agent-config), grooming conventions in its own store.
- Checkout hint (non-portable — probe before trusting; a wrong value means *unknown*, never "no checkout"): `~/.config/dotfiles` (not under `~/code` like the other repos)
- Pending relocation: infra#83 — slim this store to the pointer contract; `dotfiles_repo.md` here predates the residency rule
