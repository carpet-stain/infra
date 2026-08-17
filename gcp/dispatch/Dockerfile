# The Cloud Run Job's image (ADR-0024, #191) — a stateless, run-to-exit
# batch job, not a long-lived server (see .trivyignore for DS-0026: no
# process to HEALTHCHECK). Not yet pinned to a digest — no live registry
# to resolve one against from this code-only PR; pin one at build time
# per docs/BOOTSTRAP.md §17.
FROM alpine:3.20

RUN apk add --no-cache aws-cli curl && adduser -D dispatch

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER dispatch

ENTRYPOINT ["/entrypoint.sh"]
