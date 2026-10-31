# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
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
ARG DENO_IMAGE=docker.io/denoland/deno:2.9.8@sha256:a0d88a7fcbd44f062cba2748e19df67d30290ad12aa203c7c1e0b12462c483f0

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
