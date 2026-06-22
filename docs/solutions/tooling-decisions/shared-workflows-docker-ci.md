---
title: "Use shared reusable workflows for Docker image CI/CD"
date: 2026-06-22
category: docs/solutions/tooling-decisions
module: docker-image
problem_type: tooling_decision
component: tooling
severity: low
applies_when:
  - "Adding CI/CD for a Docker image that publishes to Docker Hub"
  - "A shared reusable workflow exists in the organization that handles Docker build, sign, and publish"
  - "You want multi-arch builds, Cosign signing, and semver tagging without implementing them from scratch"
tags:
  - github-actions
  - docker
  - ci-cd
  - reusable-workflows
  - dockerhub
  - multi-arch
  - cosign
---

# Use shared reusable workflows for Docker image CI/CD

## Context

The Hermes Sandbox Docker image was built and validated locally, but had no CI/CD pipeline to automate building and publishing to Docker Hub. Implementing multi-arch builds (amd64 + arm64), Cosign signing, semver tagging, and Docker Hub README sync from scratch would be significant effort. The `Taegost/shared-workflows` repository already provides a reusable workflow (`docker-build-push.yml`) that handles all of this.

## Guidance

When a shared reusable workflow exists for Docker image CI/CD, use it as a caller rather than reimplementing the pipeline. Create a minimal caller workflow that:

1. Defines triggers (version tags, PRs, schedule, manual dispatch)
2. Calls the reusable workflow with `uses:` pointing to the shared repo at a pinned version tag
3. Passes required inputs and explicitly maps only the required secrets

The caller workflow should be ~17 lines — triggers plus one job calling the reusable workflow.

## Why This Matters

1. **Avoids duplicated effort** — Multi-arch builds via QEMU/Buildx, Cosign keyless signing via Sigstore, Docker Hub README sync, and semver tag expansion (`1.2.3` → `1.2`, `1`, `latest`) are all handled by the shared workflow.
2. **Consistent CI across repos** — All repos using the same shared workflow get identical build, sign, and publish behavior.
3. **Centralized maintenance** — Updates to the shared workflow (action version bumps, new features) propagate to all callers on the next run.
4. **Multi-arch for free** — The shared workflow builds `linux/amd64` and `linux/arm64` by default. No extra configuration needed; the only cost is longer CI time.

## When to Use

- The organization has a shared reusable workflow for Docker builds
- You want multi-arch builds, Cosign signing, or semver tagging
- You don't need custom build logic that deviates from the shared workflow's behavior
- The shared workflow's inputs cover your needs (image name, event name, secrets)

## Examples

### Caller workflow (`.github/workflows/docker-build-push.yml`)

```yaml
name: Build and Publish

on:
  push:
    tags:
      - 'v*.*.*'
  pull_request:
    branches:
      - main
  schedule:
    - cron: '0 4 * * 1'
  workflow_dispatch:

jobs:
  build:
    uses: Taegost/shared-workflows/.github/workflows/docker-build-push.yml@v1.0.0
    with:
      event_name: ${{ github.event_name }}
    secrets:
      DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}
      DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
      DOCKERHUB_IMAGENAME: ${{ secrets.DOCKERHUB_IMAGENAME }}
```

### Trigger behavior

| Trigger | Behavior |
|---------|----------|
| Push `v1.2.3` tag | Builds, pushes tags `1.2.3`, `1.2`, `1`, `latest`, `sha-<short>`, signs with Cosign |
| PR to `main` | Build-only validation (no push, no sign) |
| Weekly schedule (Monday 04:00 UTC) | Builds with `latest` + `sha-<short>` tags |
| Manual dispatch | Builds from the Actions tab |

### Required repository secrets

These must be configured in the repo's Settings > Secrets and variables > Actions:

- `DOCKERHUB_USERNAME` — Docker Hub username
- `DOCKERHUB_TOKEN` — Docker Hub access token (Account Settings > Security)
- `DOCKERHUB_IMAGENAME` — Image name (e.g., `hermes-sandbox`)

## Related

- `docs/brainstorms/2026-06-21-docker-image-build-requirements.md` — requirements document
- `docs/plans/2026-06-22-001-feat-github-action-docker-build-plan.md` — implementation plan
- `docs/solutions/tooling-decisions/hermes-sandbox-base-image-version.md` — base image version alignment
