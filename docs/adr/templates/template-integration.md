# NUMBER. TITLE

Date: DATE

## Status

STATUS

## Context

What forces are at play — the problem, constraints, why it needs a decision now.

## ADR-0014 §5 integration checklist

Answer each before deciding — a blank line here is a question skipped, not a
question with no answer.

1. **Class** (protocol / runtime / adapter / platform):
2. **Deployment/data artifact** — is it standard?:
3. **Exit path**, in one command or one paragraph:
4. **Egress exposure** to read all the data out once a month:
5. **Self-hostable alternative** on existing Hetzner/homelab capacity at
   ~zero marginal cost?:
6. **Terraform provider** — official and maintained?:
7. **Vendor-death / suspension blast radius** — what breaks with 30 days'
   notice, or none? Name anything correlated (shared account with DNS,
   storage, hosting):
8. **Free-tier dependency** — paid price when the tier changes, and the
   trigger (rows, seats, requests) that flips it:
9. **Backup, not just exit** — is there a scheduled, restore-tested backup
   path, or only a migration tool run by hand?:
10. **Vendor security posture** — SOC 2 / breach history / access controls
    for the data this service will hold:
11. **Spend alerts / safety controls** — what the vendor supports, and which
    land at adoption (per ADR-0027's stance)? Ongoing posture is §6, not here:

## Decision

What we're doing, stated plainly.

## Alternatives considered

- **Option A** — why rejected.
- **Option B** — why rejected.

## Consequences

What gets easier or harder as a result; what to revisit if a premise changes.
