# Keylink Image Troubleshooting

Use this guide after a request fails. Preserve the user's requested model. Implicit known-model reference edits may make one Chat retry after an Images Edits capability error; explicit endpoint selections and non-capability errors are not retried.

## Model and resolution selection

The API key is only a credential; it does not contain a model catalog. Run `node scripts/list_image_models.js` internally to query `/v1/models`. The helper filters likely image-capable models and returns capability evidence without exposing the key. If the response includes sizes or aspect ratios, they appear as advertised values. If it does not, the helper returns explicitly unverified suggestions. The model and resolution still require user selection when multiple choices are available; ask for that choice in natural language and translate it into script parameters internally.

For `gpt-image-2` and the supported Gemini image models, use the conservative default sizes `1024x1024`, `1536x1024`, or `1024x1536` according to the requested composition. Treat “更高分辨率”, “高分辨率”, “高清”, “超高清”, “2K”, “4K”, “UHD”, and explicit larger dimensions as high-resolution intent. For 16:9, try `2560x1440` for 2K-class and `3840x2160` for 4K while preserving the selected model ID. If no 4K size is advertised, report the available sizes and ask for explicit approval before local upscaling. If a submitted high-resolution request fails, preserve the service's original status/body and explain that the model, channel, or requested size is unsupported; do not silently fall back to 1K or switch to Chat. A local resize produces a 4K canvas but not native 4K detail.

If a `3840`-class request is still running, allow at least the automatic 480-second timeout (8 minutes); an explicit longer timeout is honored.

For model-level comparison, Nano Banana (`gemini-2.5-flash-image`) is 1K-class, Nano Banana Pro (`gemini-3-pro-image`) supports 1K/2K/4K, and Nano Banana 2 (`gemini-3.1-flash-image`) supports 512p/1K/2K/4K. The live Keylink `/v1/models` response remains authoritative for the current channel.

## macOS or Linux reports missing PowerShell

Do not install PowerShell. Use the Node.js helpers shipped with the skill. Codex supplies the Node runtime; locate its executable through the workspace dependency runtime when `node` is not already on `PATH`. The `.ps1` files are Windows compatibility entrypoints only.

## Built-in ImageGen was selected

The host may select the built-in ImageGen when both skills match a generic image request. `allow_implicit_invocation: true` makes Keylink eligible but does not define provider priority. To guarantee Keylink, invoke `$keylink-image`, say “用 Keylink 生成/编辑”, or explicitly say “不要使用内置 ImageGen，使用 Keylink”. Do not claim that an unqualified request was sent to Keylink unless the Keylink helper output is visible.

After generation, inspect the saved file's actual width and height. For Chat Completions, the requested aspect ratio may be honored without the response exposing a fixed pixel-size contract.

## Follow-up edit or uploaded image

When the user asks to change part of an image generated earlier, reuse that generation's saved output path as the next request's input image. When the user uploads an image, pass the attachment path directly with the new prompt. Known image models first use `/v1/images/edits` and upload the bytes as the multipart `image` field; explicit Chat mode uses `image_url`. If an implicit Images Edits request returns an endpoint/capability error such as `image is required`, the helper may make one Chat retry with the same image; JSON `input_image` is not a file upload for Images Edits. Surface both errors if the fallback also fails.

If an edit appears to regenerate from the text prompt, inspect the command before diagnosing the model: confirm that `--input-image-path` equals the immediately preceding successful result's `NextEditInputPath`. A visually similar or older filename is not sufficient.

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
