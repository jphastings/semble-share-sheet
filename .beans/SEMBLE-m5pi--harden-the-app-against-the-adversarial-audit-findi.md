---
# SEMBLE-m5pi
title: Harden the app against the adversarial audit findings
status: in-progress
type: epic
priority: high
created_at: 2026-09-21T13:05:43Z
updated_at: 2026-09-21T14:52:45Z
---

Fixes for the Medium findings (M1–M7) of the adversarial audit of the whole codebase. H1 (release secrets scoped to steps, actions SHA-pinned) was done separately. Low findings L1–L8 are not covered here.

## Process note: stale worktree base

The first two subagents were given isolated git worktrees, which were branched from `claude/semble-ios-share-sheet-ts76ae` (f283666) rather than from `main` (80424b1) — five commits and a whole OAuth refactor behind. Files the agents needed were mostly identical between the two bases, but the session agent wrote its PDSClient and AuthorizationServerMetadata changes against code main has since deleted (the hand-rolled DPoP/JWT/PKCE stack, replaced by the OAuthenticator package). That work was discarded and redone against main.

Check `git worktree list` against `git log --oneline main` before trusting worktree-based agent output in this repo.
