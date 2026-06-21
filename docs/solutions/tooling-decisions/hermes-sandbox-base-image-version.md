---
title: "Match base image runtime versions to the platform's official image"
date: 2026-06-21
category: docs/solutions/tooling-decisions
module: docker-image
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "Building a Docker image to serve as an SSH backend for Hermes Agent"
  - "Choosing a base image with specific Python and Node.js version requirements"
  - "Aligning container toolchain versions with an upstream project"
tags:
  - docker
  - base-image
  - python-version
  - nodejs-version
  - hermes-agent
  - ssh-backend
  - version-alignment
  - nikolaik
---

# Match base image runtime versions to the platform's official image

## Context

Building a custom Docker image (`hermes-sandbox`) to serve as an SSH backend for Hermes Agent. The initial plan used `nikolaik/python-nodejs:python3.11-nodejs20` as the base image, which appeared to be a convenient multi-language image. However, research revealed that the official Hermes Docker image has already moved to Python 3.13 and Node.js 22 (based on `debian:13.4`), while Node.js 20 reached end-of-life in April 2026. The SSH backend itself imposes no version requirements — it only needs a bash shell — but the runtime environment should still align with what Hermes actually ships.

## Guidance

When building a custom Docker image that integrates with an existing platform, **match the runtime versions of that platform rather than choosing versions independently**. In this case, use `python3.13-nodejs22` as the base image instead of `python3.11-nodejs20`.

Additionally, avoid multi-version side-by-side installs unless there is a concrete, documented need. The added image size, complexity, and maintenance burden are rarely justified for an SSH backend that only needs a single runtime per language.

## Why This Matters

1. **Version drift** — If the sandbox image ships different Python/Node versions than the Hermes agent itself, behavior differences can emerge silently. Code that works in one environment may break in the other due to language-level changes between minor/patch versions.

2. **EOL risk** — Node.js 20 reached end-of-life in April 2026. Running an EOL runtime in a backend image means no security patches, no bug fixes, and potential incompatibilities as dependencies drop support for it.

3. **Simplicity** — Installing multiple versions of the same runtime side-by-side adds image bloat and decision overhead for future maintainers. A single aligned version is easier to reason about and debug.

4. **Single source of truth** — The official Hermes Docker image defines what the platform actually runs. The sandbox should mirror that, not invent its own version matrix.

## When to Apply

- Building any auxiliary or integration image that executes code on behalf of a primary platform
- The primary platform has an official Docker image with pinned runtime versions
- A runtime (Python, Node.js, Java, etc.) is approaching or past end-of-life
- There is no explicit requirement to support multiple runtime versions

## Examples

**Before (diverged versions):**

```dockerfile
FROM nikolaik/python-nodejs:python3.11-nodejs20
```

- Python 3.11 vs platform's 3.13
- Node.js 20 (EOL April 2026) vs platform's 22
- Potential for subtle runtime differences and security exposure

**After (aligned versions):**

```dockerfile
FROM nikolaik/python-nodejs:python3.13-nodejs22
```

- Matches the official Hermes Docker image exactly
- Both runtimes are current and supported
- No unnecessary version divergence to debug

## Prevention

Before finalizing a base image tag:

1. Check the platform's official Docker image for its current Python and Node.js versions
2. Verify the chosen tag's runtimes match (or are compatible with) the official versions
3. Check EOL dates for all runtimes — avoid images with end-of-life components
4. Document the version alignment rationale in the plan or README so future maintainers understand the constraint

## Related

- `docs/plans/2026-06-21-001-feat-hermes-sandbox-docker-image-plan.md` — implementation plan that uses this base image decision
- `docs/brainstorms/2026-06-21-docker-image-build-requirements.md` — requirements document specifying R1 (base image)
- `STRATEGY.md` — product strategy with Image Build & Validation track
