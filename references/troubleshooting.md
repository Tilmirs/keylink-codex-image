# Keylink Image Troubleshooting

Use this guide after a request fails. Preserve the user's requested model and endpoint; do not silently retry a different model or route.

## Model and resolution selection

The API key is only a credential; it does not contain a model catalog. Run `node scripts/list_image_models.js` internally to query `/v1/models`. The helper filters likely image-capable models and returns capability evidence without exposing the key. If the response includes sizes or aspect ratios, they appear as advertised values. If it does not, the helper returns explicitly unverified suggestions. The model and resolution still require user selection when multiple choices are available; ask for that choice in natural language and translate it into script parameters internally.

## macOS or Linux reports missing PowerShell

Do not install PowerShell. Use the Node.js helpers shipped with the skill. Codex supplies the Node runtime; locate its executable through the workspace dependency runtime when `node` is not already on `PATH`. The `.ps1` files are Windows compatibility entrypoints only.

After generation, inspect the saved file's actual width and height. For Chat Completions, the requested aspect ratio may be honored without the response exposing a fixed pixel-size contract.

## Model rejected by chat

Symptom: `/v1/chat/completions` returns HTTP 400 or reports that an image model is unsupported.

Cause: availability on `/v1/images/generations` does not imply chat-completions support. In the observed setup, `gpt-image-2` was rejected by chat.

Action: omit `--endpoint-mode` for a known image model or pass `--endpoint-mode images`. Use explicit `chat` only when the user requests it or the deployment documents that model on chat.

## Local proxy returns 404 for generations

Symptom: chat works through CCSwitch, but `/v1/images/generations` on the same proxy returns HTTP 404.

Cause: a Codex-oriented proxy may expose `/v1/responses` and `/v1/chat/completions` without implementing the images route. A working chat request is not an images-route health check.

Action: use `--route direct` for generations. Resolve a direct credential from a private key file, environment variable, or the explicitly approved `--use-ccswitch-credential` flow. Never send that credential to the loopback proxy.

## Proxy address was changed manually

The proxy host and port are not fixed. Resolution order is:

1. `--proxy-base-url`
2. `KEYLINK_PROXY_BASE_URL`
3. The active Codex provider's `base_url` in `config.toml`, read on every run

Use `--dry-run` to confirm the complete endpoint before a live request. `--base-url` and `KEYLINK_BASE_URL` control direct Keylink routing, not the proxy.

## CCSwitch credential access

`--use-ccswitch-credential` requires approval to read the local CCSwitch database. It selects only the current `codex` provider, verifies that the provider and destination hosts are `keylinkclub.com`, and keeps the credential in memory. It does not reuse CCSwitch's current text model; `--model` remains authoritative.

If CCSwitch is installed in a non-default location, set `CCSWITCH_DB_PATH`. If the current provider is not Keylink, switch CCSwitch to the Keylink Codex provider or use `scripts/configure_key.ps1`; do not use another provider's key.

## Approval or sandbox failure

Symptom: the host rejects filesystem/network escalation, returns an approval-service error such as HTTP 503, or fails before any request reaches Keylink.

Action:

1. Ask for approval immediately before reading the CCSwitch credential and sending the network request.
2. If approval infrastructure cannot execute the operation, do not diagnose the API key, model, or Keylink as broken.
3. Explain that local filesystem and/or network approval is required, then stop. Shell execution, credentials, and JSON remain internal to the host.
4. When permission becomes available, rerun the internal helper automatically and then check that the output is nonempty, inspect format/dimensions, and view the image.

## Installation needs approval

Installing into `~/.codex/skills` writes outside many project sandboxes. Ask for filesystem approval before copying and perform the copy internally. If approval is rejected, explain that skill-installation permission is required and stop. Shell handoff to the user is not allowed. Restart or reload the host if it does not discover the newly installed skill immediately.
