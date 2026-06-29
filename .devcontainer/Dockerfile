# Minimal image with the GitHub CLI, used to cut GitHub releases for BindAll.
# The macOS app itself is built on the host (Xcode); this container only runs `gh`.
FROM alpine:3.20

RUN apk add --no-cache github-cli git openssh-client ca-certificates bash

WORKDIR /workspace
