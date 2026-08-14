# 0019. Blocking two-line signpost cap for comments, superseding ADR-0006

Date: 2026-08-14

## Status

Accepted

Supersedes ADR-0006.

## Context

ADR-0006 mirrored `dotfiles`' original comment-concision lint as an advisory outlier
detector: `THRESHOLD_LINES=15`, calibrated against this repo's own densest legitimate
block (`app.tf`'s 10-line `github_actions_secret` block), never a non-zero exit. Its own
Consequences section named the gap plainly: it can't catch a restatement short enough to
stay under 15 lines, because that's not what a length-outlier detector does.

`dotfiles` epic #530/#531 changed what the rule is, which is what forces a new decision
here rather than a retune: the rule is no longer "this block is an outlier, re-read it"
but "a comment on one declaration is a ≤2-line signpost — the tripwire plus a pointer —
and the durable why lives in an ADR, AGENTS.md, or an issue." `dotfiles` ADR-0044 designed
and landed the mechanism (script + rule text) once; this repo's own issue (#163) is
explicit, same as ADR-0006's original instruction: mirror the landed mechanism, sweep this
repo's own comments against it, and flip the wiring — don't re-derive the design.

The sweep (#163) is what makes flipping safe: every existing `.tf`/`scripts/*.sh` comment
block over 2 lines was relocated (mostly into existing ADRs and AGENTS.md, three into new
ADR amendments for whys that had no prior home) or tightened to a self-contained tripwire
before this ADR landed. Flipping the threshold without the sweep would fail `just lint` on
every pre-existing block at once.

## Decision

**The cap is 2 lines, enforced by a non-zero exit** — `scripts/check-comment-concision.sh`
is replaced with `dotfiles`' updated reference implementation (post-ADR-0044), unchanged in
shape:

- `THRESHOLD_LINES=2` is the maximum allowed (`count > threshold`, not `>=`).
- Non-zero exit on any violation; the script accumulates status across files so it reports
  every offending block in one run, not just the first.
- File-header preambles stay exempt (the first comment block, nothing above it but a
  shebang or blanks) — unchanged from ADR-0006.
- No escape hatch: no pragma, no per-file opt-out, no per-repo threshold recalibration.
  Relocate-or-point is the pressure release, the same boundary `dotfiles` ADR-0044 draws
  between the inline tripwire (kept, terse) and its supporting evidence (relocated).
- No banner exemption ported: `dotfiles`' box-drawn `+---+`/`|text|` ASCII banners don't
  occur in this repo's style (`# --- Section ---` single-line dividers, which never trip a
  2-line cap on their own). Nothing to exempt that isn't already fine.
- Comment-prefix map stays `*.tf` and `scripts/*.sh` only — this repo's only two
  comment-bearing file types (ADR-0006's original scoping decision, still correct); the
  language prefixes `dotfiles` ADR-0044 added (Lua, JS, Python) don't apply here.
- `lefthook.yml`'s `comment-concision` job (tagged `base`) is unchanged — same glob, same
  invocation. What changes is only the script's own behavior.

Point at `dotfiles` ADR-0044 for the shared reasoning this repo doesn't re-derive: why an
absolute cap replaces per-repo outlier calibration, and the boundary clause between a kept
tripwire and relocated evidence.

## Alternatives considered

- **Keep it advisory, just lower the threshold.** Rejected for the same reason `dotfiles`
  ADR-0044 rejected it: the rule this repo adopted is an absolute cap, and an advisory nudge
  everyone scrolls past is the state that let ADR-0006's own motivating restatement (PR #38)
  through in the first place.
- **Recalibrate a per-repo threshold instead of adopting `2`.** Right for an outlier
  detector (ADR-0006's own model), wrong for a discipline stated the same way everywhere.
  2 is the same number in every repo mirroring this mechanism because the rule is the same
  rule everywhere, not a per-repo style preference.
- **Re-derive the design independently for this repo's `.tf`/`.sh` style.** Rejected per
  ADR-0006's own precedent and #163's explicit instruction: land the same mechanism once
  it's proven upstream, don't design it twice.
- **Editing ADR-0006 in place** instead of a new ADR. Rejected per `docs/adr/README.md`'s
  own rule: a later decision that replaces an earlier one gets its own ADR, so the
  rejected 15-line-advisory path stays visible instead of being edited out of the record.

## Consequences

`just lint`/CI now hard-fail on any new `.tf`/`scripts/*.sh` comment block over 2 lines on
one declaration — a real gate, not a nudge. The #163 sweep is the one-time cost that makes
this safe to flip today: every pre-existing block is already at or under the cap, so this
ADR introduces no new CI failures on `main`. ADR-0006's own accepted gap (length isn't a
redundancy detector; a short restatement already documented elsewhere isn't mechanically
caught) is not resolved by this cap either — it makes the long restatements impossible and
leaves the short ones to review, same as `dotfiles` ADR-0044 states for itself.

Revisit if a future comment can't be shaped to fit the tripwire/pointer boundary (that
would mean the boundary is drawn wrong here, not that the cap needs a hatch), or if this
repo ever gains a comment-bearing file type beyond `.tf`/`.sh` that needs its own prefix
entry.
