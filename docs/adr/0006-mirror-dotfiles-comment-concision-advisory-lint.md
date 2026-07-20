# 0006. Mirror dotfiles comment-concision advisory lint

Date: 2026-07-19

## Status

Accepted

## Context

PR #38's `app.tf` restated a repo-wide fact ("runs under the elevated
session, same as every other Administration-scope apply") already in this
repo's own README.md/AGENTS.md — nothing mechanically checked
design-principles.md's comment-concision rule (comments explain why, not
what; point elsewhere instead of restating), so it got missed
(`dotfiles`#374, this repo's #40). `dotfiles`#375 designed and landed the
reference implementation (`dotfiles` ADR-0031); this repo's issue was
explicit: mirror that mechanism rather than re-derive it independently.

## Decision

Port `dotfiles`' `scripts/check-comment-concision.sh` and its
`comment-concision` lefthook job as-is in shape: a length-based advisory
nudge (never a non-zero exit) on a comment block over `THRESHOLD_LINES`
attached to a single declaration, excluding a file's leading header block.
Recalibrated for this repo: `THRESHOLD_LINES=15`, not `dotfiles`' 20 —
`dotfiles` ADR-0031 explicitly says reuse the shape, not the number,
calibrating each repo against its own real comments. This repo's densest
legitimate single-declaration comment is `app.tf`'s 10-line
`github_actions_secret.app_private_key` block, so 15 sits with the same
proportional headroom `dotfiles` used (5 lines above its own observed max
of 15). Scoped to `*.tf` and `scripts/*.sh` (this repo's only two comment-bearing
file types), wired into `lefthook-base.yml` tagged `base` per #40's explicit
placement — anticipating `project-starter-template`#17 making this a
genuinely template-owned base job.

## Alternatives considered

- **Phrase-overlap against this repo's own README.md/AGENTS.md** —
  `dotfiles` ADR-0031 already tried and rejected this for the identical
  reason a `dotfiles`-recalibrated version would fail here too: this
  repo's comments and its own README/AGENTS.md share the same "elevated
  session" / "Administration scope" vocabulary _everywhere_ on purpose
  (AGENTS.md:124, README.md's `just tofu-apply` line), so a phrase-overlap
  check would flood false positives on this repo's normal cross-referenced
  style, not just the one restated PR #38 sentence. Not re-tested
  independently — `dotfiles`#375's finding was structural (no
  bag-of-words/n-gram method can tell genuine restatement apart from
  a well-cross-referenced repo's normal vocabulary), not something
  specific to `dotfiles`' file set.
- **Re-deriving the design from scratch for this repo's `.tf` style** —
  rejected per #40's own instruction: "don't design this independently;
  land the same mechanism once it's proven there."

## Consequences

Same accepted gap as `dotfiles` ADR-0031: the lint cannot catch PR #38's
actual regression — the redundant sentence was embedded in a comment block
short enough (well under 15 lines) that no threshold calibrated to avoid
false-positiving on this repo's real style would have caught it either.
Verified: the check runs silent across every `.tf` file in this repo as of
this ADR, and reproduces the same non-flag on a reconstruction of PR #38's
actual comment block. #40's acceptance criterion ("a restated-elsewhere one
should [flag]") is not met by this mechanism — that criterion was written
before `dotfiles`#375's design testing surfaced this as a structural limit,
not a per-repo tuning gap; catching a short, already-documented restatement
stays a human/PR-review concern here too. `project-starter-template`#17
should mirror this same shape and calibrate its own `THRESHOLD_LINES`
against its own real comments rather than reusing either repo's number.
