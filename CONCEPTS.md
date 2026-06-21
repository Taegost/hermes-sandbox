# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Hermes Agent

The AI agent platform this sandbox serves. Hermes Agent opens a persistent bash session over SSH (ControlMaster reuse), runs arbitrary shell commands, rsyncs skills and credentials in before commands, and rsyncs modified files back out on teardown. It does not install its own runtime — whatever the agent's tasks need must already be present in the sandbox.

## Sandbox

The execution environment (Docker container) where Hermes Agent runs commands. The sandbox provides Python and Node.js runtimes, system packages, and SSH access. It is ephemeral — host keys are generated at startup, and the container can be destroyed and recreated without losing state (files are rsynced back to the agent on teardown).

## SSH Backend

A specific type of sandbox that uses SSH for communication with Hermes Agent. The SSH backend listens on a non-standard port (2222), uses passwordless key-based authentication, and supports ControlMaster connection reuse with a 5-minute keepalive. Authorized keys are mounted at runtime via Kubernetes Secrets, not baked into the image.
