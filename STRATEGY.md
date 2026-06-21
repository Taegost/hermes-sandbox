---
name: Hermes Sandbox
last_updated: 2026-06-21
---

# Hermes Sandbox Strategy

## Target problem

Hermes Agent needs a minimal, secure SSH backend sandbox with Python and Node.js capabilities, but the exact requirements are unclear and no good documentation exists for this specific combination. The challenge is both discovering what's actually needed and documenting the validated solution.

## Our approach

Research first, validate each addition, document everything — build the minimal viable image and only add what's proven necessary.

## Who it's for

**Primary:** Developers and operators running Hermes Agent — They're hiring Hermes Sandbox to provide a reliable, minimal SSH backend target in Kubernetes with Python and Node.js runtimes available.

## Key metrics

- **SSH connection success rate** — 100% of SSH connections succeed after SSH keys are configured; no additional setup required beyond key placement
- **Zero additional system packages required** — Hermes Agent can complete all work without installing additional system-level packages (Python and npm package installs are acceptable); measured by running agent tasks
- **Documentation completeness** — Full scope of requirements documented, including package justifications and configuration decisions; measured by whether a new user can reproduce the setup from docs alone

## Tracks

### Image Build & Validation

Building the Docker image, testing package completeness, validating Hermes Agent compatibility, and automating build/deploy via GitHub Actions (pattern exists in other repos and can be duplicated).

_Why it serves the approach:_ This is the research-and-validate track — each package addition must be tested and justified before inclusion.

### SSH & Security Configuration

Configuring passwordless SSH, running as non-root, accepting only incoming SSH on port 22, allowing all outgoing traffic, and ensuring secure defaults for Kubernetes deployment.

_Why it serves the approach:_ Security is non-negotiable for a container that accepts SSH connections — every configuration choice must be validated.

### Documentation

Documenting requirements, package justifications, configuration decisions, and producing a blog post covering the full setup.

_Why it serves the approach:_ Directly addresses the documentation gap — the validated solution must be reproducible from docs alone.
