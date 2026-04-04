# Security Policy

## Scope

This repo includes infrastructure config, local service wiring, generated data artifacts, and machine-specific tooling context. Treat it as a mixed-code and operational repository.

## Secret Handling

- do not commit real secrets to `.env`
- do not commit live credentials to `.cursor/mcp.env`
- do not store production tokens or API keys in tracked config files
- use `.env.example` for documented placeholders only

## `.cursor` Policy

`.cursor/` may be tracked only when its contents are sanitized for sharing.

Rules:

- no real API keys
- no local machine secrets
- no provider tokens in `mcp.json` or related files
- prefer redacted/default-safe values

## Data And Generated Artifacts

- do not commit large generated parcel artifacts under `data/`
- do not commit ad hoc packed outputs such as `repomix.md` when they contain sensitive or derived internal material
- keep screenshots and local test output untracked unless there is a deliberate reason to add a fixture

## Object Storage Credentials

- local MinIO defaults are for development only
- production object storage credentials must not be committed
- scripts should prefer env-driven credentials over hard-coded secrets whenever possible

## Reporting

If you discover a credential leak or unsafe tracked config:

1. stop propagating the file
2. rotate the credential if it was real
3. remove or redact the secret in the repo
4. document the policy gap if a process allowed it
