# syntax=docker/dockerfile:1
#
# wyattjoh/jmap-mcp, unmodified, with safe.ts as the entrypoint instead of its
# own mod.ts. Upstream publishes no image, and its server only speaks stdio and
# registers send/reply/delete tools whenever the account is writable. safe.ts
# imports the upstream tool code, serves it over Streamable HTTP, and puts two
# allow-lists in front of it (tool names, and JMAP methods on the wire). Read
# the header of safe.ts before bumping UPSTREAM_REF.
#
# Build and push (from the repo root):
#   docker buildx build --platform linux/amd64 --push \
#     -t ghcr.io/yyewolf/jmap-mcp:0.6.5-1 images/jmap-mcp
ARG DENO_IMAGE=docker.io/denoland/deno:2.9.5@sha256:b429777c3dcff34a6488f365a1537db1640b2d48379b60f5e6206be034472463

FROM ${DENO_IMAGE}

# v0.6.5. A commit, not the tag: a tag can be moved.
ADD --keep-git-dir=false https://github.com/wyattjoh/jmap-mcp.git#55eed8536e1c334f703938e5b6ca5335d1e5bda1 /app
WORKDIR /app

# Every dependency is fetched here, at build time, against upstream's lockfile.
# The container runs with --cached-only and has no route to a registry.
RUN deno install --frozen

COPY safe.ts packages/jmap-mcp/src/safe.ts
RUN deno check packages/jmap-mcp/src/safe.ts

USER deno
EXPOSE 8080

# The permission flags are in the Deployment, next to the network policy they
# mirror: apps/mail-mcp/deployment.yaml.
ENTRYPOINT ["deno", "run", "--cached-only"]
