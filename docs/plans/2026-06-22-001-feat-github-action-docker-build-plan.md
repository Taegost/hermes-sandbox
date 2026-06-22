---
title: "feat: Add GitHub Action for Docker image build and publish"
type: feat
status: completed
date: 2026-06-22
origin: docs/brainstorms/2026-06-21-docker-image-build-requirements.md
---

# feat: Add GitHub Action for Docker image build and publish

## Summary

Add a GitHub Actions workflow to build and publish the Hermes Sandbox Docker image to Docker Hub by calling the `Taegost/shared-workflows` reusable workflow at `v1.0.0`. Also update the requirements doc to reflect multi-arch builds as optional rather than excluded.

## Problem Frame

The Docker image is built and validated locally, but there is no CI/CD pipeline to automate building and publishing to Docker Hub. The `Taegost/shared-workflows` repository provides a reusable workflow that handles multi-arch builds, Cosign signing, semver tagging, and Docker Hub README sync — all features that would be significant effort to replicate from scratch.

## Requirements

- R1. A caller workflow exists at `.github/workflows/docker-build-push.yml` that invokes `Taegost/shared-workflows/.github/workflows/docker-build-push.yml@v1.0.0`.
- R2. The workflow triggers on version tag pushes (`v*.*.*`), pull requests to `main` (build-only validation), a weekly schedule, and manual dispatch.
- R3. The workflow passes `event_name` input and explicitly maps the three required secrets.
- R4. Three repository secrets are documented as prerequisites: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `DOCKERHUB_IMAGENAME`.
- R5. The requirements doc's multi-arch scope boundary is updated from "not in scope for v1" to "optional — provided by the shared workflow at no extra configuration cost".

## Key Technical Decisions

**KTD-1: Use the shared workflow as-is, including multi-arch builds.** The reusable workflow already handles `linux/amd64` and `linux/arm64` via QEMU/Buildx. Overriding to single-arch would require either forking the workflow or adding an input the shared workflow doesn't expose. Multi-arch builds cost longer CI time but no additional configuration, and provide broader platform support for free.

**KTD-2: Explicit secret mapping over `secrets: inherit`.** The shared workflow requires `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, and `DOCKERHUB_IMAGENAME`. Using explicit mapping limits the blast radius to only the three required secrets, following least-privilege principles.

## Implementation Units

### U1. Create caller workflow

**Goal:** Add the GitHub Actions workflow that builds and publishes the Docker image.

**Dependencies:** None

**Files:**
- `.github/workflows/docker-build-push.yml` (create)

**Approach:** Create a minimal caller workflow matching the shared workflow's `examples/caller-workflow.yml`. Triggers: `push` tags `v*.*.*`, `pull_request` to `main`, `schedule` (weekly Monday 04:00 UTC), `workflow_dispatch`. Single job calling the reusable workflow with `event_name` input and explicit secret mapping.

**Test scenarios:**
- Happy path: Pushing a `v1.0.0` tag triggers the workflow and builds the image.
- PR validation: Opening a PR to `main` triggers a build-only run (no push, no sign).
- Manual dispatch: `workflow_dispatch` triggers a build from the Actions tab.
- Schedule: Weekly cron fires and builds with `latest` + `sha-<short>` tags.

**Verification:** The workflow file exists at `.github/workflows/docker-build-push.yml` and matches the structure of the shared workflow's example caller.

### U2. Update requirements doc scope boundary

**Goal:** Change the multi-arch scope boundary from excluded to optional.

**Dependencies:** None

**Files:**
- `docs/brainstorms/2026-06-21-docker-image-build-requirements.md` (modify)

**Approach:** Replace the line "Multi-architecture builds — not in scope for v1." with "Multi-architecture builds — optional; provided by the shared workflow at no extra configuration cost."

**Test expectation:** none — documentation-only change.

**Verification:** The scope boundary section no longer lists multi-arch as excluded.

### ~~U3. Add UID:GID to README examples~~ (superseded by PR review)

**Status:** Superseded. PR review found that `--user 10000:10000` and `runAsUser: 10000` break sshd privilege separation. The final implementation removes these flags and adds a note explaining that the container starts as root and drops to `hermes` (UID 10000:10000) after SSH authentication.

## Scope Boundaries

- **Secrets configuration** — setting `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, and `DOCKERHUB_IMAGENAME` as GitHub repo secrets is a manual step in the repo's Settings > Secrets and variables > Actions. Not automatable from a PR.
- **Docker Hub repository creation** — the Docker Hub repo must exist before the first push. Out of scope for this plan.
- **Cosign key management** — the shared workflow uses keyless Sigstore signing via GitHub OIDC. No additional key setup needed.

## Deferred to Follow-Up Work

- Branch protection rules requiring the build check to pass before merging.
- Renovate or Dependabot for the shared workflow version pin.

## Sources & Research

- `Taegost/shared-workflows` reusable workflow: `.github/workflows/docker-build-push.yml@v1.0.0`
- Example caller: `Taegost/shared-workflows/examples/caller-workflow.yml`
- Origin document: `docs/brainstorms/2026-06-21-docker-image-build-requirements.md`
