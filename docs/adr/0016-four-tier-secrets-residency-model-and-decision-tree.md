# 0016. Four-tier secrets-residency model and decision tree

Date: 2026-08-13

## Status

Accepted

Supersedes **only ADR-0010's human-credential residency claim** ("human
credentials stay in the Bitwarden password-manager vault"). ADR-0010's
machine-store decision and its machine/human scope boundary stand
untouched — its Status stays Accepted, with an amendment pointer to here.
That scope boundary is what authorizes this ADR to own the human side:
0010 explicitly punted the structure of the human tier, and this ADR
fills it.

## Context

Secrets live across four stores — AWS SSM, iCloud Passwords, the Bitwarden
password-manager vault, and the macOS login Keychain — but the "where does
secret X go?" rationale is spread across ADR-0010, docs/BOOTSTRAP.md, and
tribal knowledge. There's no single decision tree, so a new secret class
(the LLM API key, say — dotfiles#511) has no obvious home and could
sprawl.

The model itself is already sound: the 2026-08-10 residency review
confirmed the machine tier (ADR-0010's SSM) is tight and found no ambient
sprawl beyond one dual-homed token (#171, the Cloudflare token still in
`.envrc.local`). What's missing is the written residency policy, not the
mechanism.

Throughout: "Bitwarden" means the **password-manager vault**, never the
decommissioned Bitwarden Secrets Manager (ADR-0010, #126).

## Decision

Four residency tiers, one home per secret item, and a decision tree that
assigns every new secret to exactly one of them.

### The four tiers

1. **Machine → AWS SSM Parameter Store.** `/infra/*` for crown-jewel
   long-lived/high-value secrets, `/runtime/*` for rotating ones; CI reads
   via OIDC roles, local shells via Keychain-gated IAM users. The spec —
   the tier split, the IAM×path matrix, the KMS fences — is ADR-0010 (as
   amended), docs/CONSUMING-SECRETS.md, and ADR-0014 §3–4; this ADR cites
   it and does not restate it.
2. **Human logins → iCloud Passwords.** The default human store: the
   standard login triad — username + password + 2FA (passkey or OTP) —
   synced across workstation and phone. ~99% of human secrets land here.
3. **Human secrets beyond the triad → Bitwarden vault.** Recovery and
   MFA-recovery codes, free-form secret strings, standalone usernames,
   files, break-glass material, the state-passphrase backup.
4. **Local bootstrap credential → macOS login Keychain.** The IAM access
   keys that unlock SSM itself (`infra-aws-local-apply`,
   `infra-aws-bootstrap`, `infra-aws-local-read`). Distinguished by
   _role_ — the credential that can't live in the store it unlocks — not
   by trust domain: the login Keychain shares the Apple-ID blast radius
   with iCloud Passwords (a compromised Apple ID reaches both). That's an
   **accepted consequence**, recorded plainly, not two tiers pretending
   independence.

### Decision tree — where does a new secret go?

- **Fetched by automation, infra's own?** → SSM: `/infra/*` if
  long-lived/high-value, `/runtime/*` if rotating (ADR-0010).
- **Fetched by automation, break-glass-provisioned for a consumer repo's
  own CI to read?** → SSM `/cicd/*` — a third machine sub-tier, own KMS
  key, applied only by `iam/`'s break-glass root module (ADR-0010's #272
  amendment).
- **Human login that's just username + password + 2FA?** → iCloud.
- **Human secret beyond that triad** (recovery codes, a free-form string,
  a file, break-glass)? → Bitwarden vault.
- **Bootstraps SSM access itself?** → Keychain.
- **Never** `.envrc.local` or any tracked file — gitleaks and
  `scripts/check-envrc-local-example.sh` enforce.

The iCloud/Bitwarden discriminator, as a one-line test: _"just username +
password + 2FA → iCloud; more than that → Bitwarden."_

### Why the tiers can't collapse

Recorded so the splits aren't re-litigated:

- **CI has no Keychain** and must hold no standing credential → OIDC into
  SSM (ADR-0010).
- **Humans can't fetch an interactive login from SSM** — a browser login
  needs autofill on workstation and phone → iCloud/Bitwarden.
- **The bootstrap key can't live in the store it unlocks** — fetching the
  SSM-unlocking credential from SSM is circular → Keychain.

### LLM API-key residency

Local-launcher LLM keys stay in the **Keychain**: the OpenRouter key is
the login-Keychain item `openrouter-api-key`, silent-read (`-A`), resolved
at pane launch by dotfiles' `aichat-pane.sh` (dotfiles#511). SSM is
reserved for CI and cross-machine consumers, and this key has neither — a
new `/runtime` parameter would add an IAM grant and a fetch path for one
local reader.

Silent-read for a spend-capable credential is justified, not defaulted:
it's a routine-tier key on a personal machine, and the blast radius is
capped by the provider's own spend limit — the same class as
`infra-aws-local-read`, not the prompt-gated elevated items. **Revisit
trigger:** a second machine or a CI consumer moves it to
`/runtime/openrouter`, a one-line swap of the launcher's Keychain read.

### Sanctioned dual-home: the state passphrase

The Tofu state passphrase's **primary** home is SSM
`/infra/tf-state-passphrase` (ADR-0010 — a pointer, not this ADR's claim);
its **backup** is the Bitwarden vault. Losing it means re-importing every
resource, not recovering (ADR-0002), so a second, offline-reachable copy
is deliberate — a named exception to one-home-per-item, not a tree
violation.

### Secret→tier snapshot (2026-08-10 hunt)

A decision-time illustration of the tree against every secret item the
2026-08-10 ambient-secret hunt enumerated — per-**item**, not per-service
(AWS root splits across two tiers). Frozen with this ADR; a living
inventory, if ever wanted, is a separate mutable doc.

| Secret item                                                    | Tier                                     |
| -------------------------------------------------------------- | ---------------------------------------- |
| GitHub App private key                                         | SSM `/infra/gh-app-private-key`          |
| GitHub admin PAT                                               | SSM `/infra/gh-admin-token`              |
| Cloudflare API tokens (edit + read-only)                       | SSM `/infra/cloudflare-api-token{,-ro}`¹ |
| Tofu state passphrase (primary)                                | SSM `/infra/tf-state-passphrase`         |
| R2 credential pairs + account id                               | SSM `/infra/r2-*`                        |
| Vended GitHub token                                            | SSM `/runtime/vended-token`              |
| AWS root email + password                                      | iCloud                                   |
| AWS root MFA-recovery codes                                    | Bitwarden vault                          |
| `infra-console-admin` password + MFA OTP                       | iCloud                                   |
| `infra-console-admin` MFA-recovery codes                       | Bitwarden vault                          |
| Other account logins (GitHub, Cloudflare, Apple ID, Bitwarden) | iCloud                                   |
| Those accounts' recovery codes                                 | Bitwarden vault                          |
| State-passphrase backup                                        | Bitwarden vault (sanctioned dual-home)   |
| `infra-aws-local-apply` access key (prompt-gated)              | Keychain                                 |
| `infra-aws-bootstrap` access key (prompt-gated, deactivated)   | Keychain                                 |
| `infra-aws-local-read` access key (silent, dotfiles)           | Keychain                                 |
| Routine dev PAT (gh's keyring credential, #151)                | Keychain²                                |
| OpenRouter LLM key (`openrouter-api-key`, silent)              | Keychain²                                |

¹ The hunt's one finding: the edit token was also ambient in
`.envrc.local` — the dual home #171 collapses.
² Local-only machine keys with no CI or cross-machine consumer sit in the
Keychain by the same reasoning as the LLM-key decision above — SSM is for
automation that isn't this machine.

## Alternatives considered

- **Three tiers — one human vault (Bitwarden), no iCloud.** The round-1
  reviewer's simpler path, and what ADR-0010's residency line implied.
  Rejected: iCloud Passwords is where login autofill actually happens on
  workstation and phone — the triad's day-to-day consumer — and forcing
  ~99% of human secrets into Bitwarden trades away that ergonomic default
  to avoid naming one discriminator. The blast-radius objection (iCloud
  and the login Keychain share an Apple ID) is real but doesn't pick
  Bitwarden — it's recorded above as an accepted consequence.
- **Keychain as a peer trust domain rather than a role.** Rejected: it
  shares the Apple-ID domain with iCloud, so presenting it as an
  independent tier would overstate the isolation. It earns its tier by
  role — the credential that bootstraps SSM access can't live behind SSM.
- **LLM key to SSM `/runtime` now.** Rejected: no CI or second-machine
  consumer exists; the move is designed (a one-line launcher swap) and
  waits for its trigger rather than paying the IAM-grant and fetch-path
  cost ahead of one.
- **A living secret-inventory table.** Rejected for this ADR: an ADR is
  frozen at decision time. The snapshot proves the tree covers every
  existing class; keeping an inventory current is a separate mutable
  doc's job, if ever wanted.

## Consequences

- A new secret class has an answer before it exists — walk the tree, land
  in one tier. The 2026-08-10 hunt's baseline is recorded above; the one
  code change it surfaced is #171.
- ADR-0010 gets an amendment pointer, and docs/BOOTSTRAP.md's
  password-manager references become per-item (root email+password →
  iCloud; console-admin recovery codes and the state-passphrase backup →
  Bitwarden). AGENTS.md points here for "where does a secret go".
- The Apple-ID blast radius now spans two tiers (iCloud + Keychain) by
  recorded choice. Mitigation stays where it is: the elevated Keychain
  items' read prompt (`audit-keychain-gate`, #167) and hardware MFA on
  the accounts that matter.
- **Revisit if** the LLM key gains a second machine or CI consumer
  (→ `/runtime/openrouter`), or if Apple-ID compromise exposure ever
  warrants splitting the human default off the same trust domain as the
  Keychain tier.

## Amendment — #272 (2026-08-20): a third machine sub-tier, `/cicd`

The machine tier (tier 1) assumed exactly two SSM paths — `/infra/*` and
`/runtime/*` — a binary the decision tree's "fetched by automation?"
branch inherited unchanged. agent-memory-server's CI-apply seam (#272)
needs a third shape: bootstrap secrets that are neither infra's own
crown jewels nor a consumer-created rotating value, but
**infra-provisioned, break-glass-applied, and consumer-CI-read**. The
tree above is amended to name it as its own branch rather than stretch
`/infra`'s "long-lived/high-value" test to cover a value another repo's
CI reads.

Full role×path spec (which SSM paths, which OIDC roles, which KMS key)
is ADR-0010's own #272 amendment; this ADR only records the tier's place
in the residency tree. Nothing else in the tree changes.
