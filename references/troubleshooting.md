# Keylink Image Troubleshooting

Use this guide after a request fails. Preserve the user's requested model. Automatic known-model requests try both endpoints in the model-specific order; explicit endpoint selections remain exact. HTTP errors, 200 responses without an image, and image-download failures are all recorded before the next automatic attempt.

## Model and resolution selection

The API key is only a credential; it does not contain a model catalog. Run `node scripts/list_image_models.js` internally to query `/v1/models`. The helper filters likely image-capable models and returns capability evidence without exposing the key. If the response includes sizes or aspect ratios, they appear as advertised values. If it does not, the helper returns explicitly unverified suggestions. A bare number such as `3840` does not identify an aspect ratio; ask for complete dimensions or the intended canvas before invoking generation. When the user asks for more clarity, a different resolution, or a size outside the conservative defaults, show a short numbered list containing `1024x1024`, `1536x1024`, `1024x1536`, plus advertised/high-resolution candidates. Include `2560x1440` and `3840x2160` as clearly labeled trial options that the channel may reject, and wait for the user's natural-language choice before invoking generation.

For `gpt-image-2` and the supported Gemini image models, use the conservative default sizes `1024x1024`, `1536x1024`, or `1024x1536` according to the requested composition. Treat “更高分辨率”, “高分辨率”, “高清”, “超高清”, “2K”, “4K”, “UHD”, and explicit larger dimensions as high-resolution intent. For 16:9, offer `2560x1440` for 2K-class and `3840x2160` for 4K as trial sizes even when they are not advertised, clearly warning that the channel may reject them. If a submitted high-resolution request fails on the preferred endpoint, try the other endpoint with the same model; if both fail, preserve both service errors and explain whether the model, channel, or requested size is unsupported. Never silently fall back to 1K or switch model IDs. A local resize produces a 4K canvas but not native 4K detail.

If a `3840`-class request is still running, allow at least the automatic 480-second timeout (8 minutes); an explicit longer timeout is honored.

For model-level comparison, Nano Banana (`gemini-2.5-flash-image`) is 1K-class, Nano Banana Pro (`gemini-3-pro-image`) supports 1K/2K/4K, and Nano Banana 2 (`gemini-3.1-flash-image`) supports 512p/1K/2K/4K. The live Keylink `/v1/models` response remains authoritative for the current channel.

## Codex provider reports missing `base_url`

Symptom: `--use-codex-route` reports that the active provider does not declare `base_url`, even though the matching `[model_providers.<name>]` section contains one.

Cause: an older Node helper used a multiline regular expression whose `$` matched the end of the first property line, so the provider section was read as empty.

Action: update the skill to a version with line-based provider-section parsing, then verify the route with `node scripts/list_image_models.js --use-codex-route --no-auth --dry-run`. If the dry-run succeeds but discovery returns zero models, the proxy is reachable but is not exposing an image catalog; that is a proxy capability issue, not a missing `base_url`.

## Direct discovery returns `401`

Symptom: direct `/v1/models` discovery returns `HTTP 401` or `Invalid token`.

Cause: the configured direct Keylink credential is expired, incorrect, revoked, or belongs to a different service. This is independent of Codex provider URL parsing.

Action: keep the credential private and replace or reconfigure it through the approved key-file or CCSwitch flow. Do not treat a direct `401` as evidence that the local proxy URL is wrong, and do not send a direct credential to a loopback proxy.

## macOS or Linux reports missing PowerShell

Do not install PowerShell. Use the Node.js helpers shipped with the skill. Codex supplies the Node runtime; locate its executable through the workspace dependency runtime when `node` is not already on `PATH`. The `.ps1` files are Windows compatibility entrypoints only.

## Built-in ImageGen was selected

The host may select the built-in ImageGen when both skills match a generic image request. `allow_implicit_invocation: true` makes Keylink eligible but does not define provider priority. To guarantee Keylink, invoke `$keylink-image`, say “用 Keylink 生成/编辑”, or explicitly say “不要使用内置 ImageGen，使用 Keylink”. Do not claim that an unqualified request was sent to Keylink unless the Keylink helper output is visible.

After generation, inspect the saved file's actual width and height. For Chat Completions, the requested aspect ratio may be honored without the response exposing a fixed pixel-size contract.

## Follow-up edit or uploaded image

When the user expresses dissatisfaction or a correction about the current picture, reuse the immediately preceding successful generation's saved output path as the next request's input image. The helper persists that path per `CODEX_THREAD_ID` and can recover it when `--operation edit` is used. When it is unclear whether the user wants image-to-image editing or a fresh generation, ask before invoking the helper; use `--operation edit` or `--operation generate` according to the answer. When the user uploads an image, pass the attachment path directly with the new prompt. GPT image models first use `/v1/images/edits`; Gemini image models first use `/v1/chat/completions`; the other endpoint is attempted automatically when the first fails or returns no image. Images edits upload bytes as the multipart `image` field; Chat sends both the standard `messages[].content[].image_url` and Keylink's compatibility `images[].image_url`. JSON `input_image` is not a file upload for Images Edits. Surface both endpoint errors if both attempts fail.

If an edit appears to regenerate from the text prompt, inspect the command before diagnosing the model: confirm that `--input-image-path` equals the immediately preceding successful result's `NextEditInputPath`, and confirm the Chat payload contains both image fields when Chat is used. A visually similar or older filename is not sufficient.

Symptom: `status_code=400, images[].image_url is required`.

Cause: the gateway received the edit prompt without its compatibility top-level image entry, often because the previous assistant image was displayed in the conversation but was not reused as the next request's reference.

Action: recover the latest `NextEditInputPath`, pass it as `--input-image-path`, and let the helper emit both `messages[].content[].image_url` and `images[].image_url`. Keep only the requested visual delta in the prompt.

Symptom: the helper says it cannot recognize the returned image.

Action: the response parser accepts standard `data[].b64_json`/`url`, Chat `image_url` blocks, `images[].image_url`, Markdown/data URLs, and nested base64 image fields. Preserve the safe response preview in the error; if the provider returns a new shape, add it to the parser and a mock regression test instead of treating a text-only response as an image.

## Model rejected by one endpoint

Symptom: `/v1/chat/completions` or an Images endpoint returns HTTP 400/404 or reports that an image model is unsupported.

Cause: availability on one endpoint does not imply support on the other. GPT and Gemini channels can expose different endpoint capabilities.

Action: omit `--endpoint-mode` for a known image model so the helper can try both endpoints in the preferred order. If both attempts fail, report both safe errors and ask whether to try another discovered image model. Use an explicit mode only when the user requests a fixed endpoint.

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

When `--proxy-base-url` or `KEYLINK_PROXY_BASE_URL` is present, automatic generation uses that proxy route, including known image models that normally prefer the direct Images endpoint. To bypass a configured proxy and use Keylink directly, select `--route direct` and provide a direct credential source; do not pass a proxy override with that route.

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

## GitHub update does not start

For an existing installation, do not use `$skill-installer`: the built-in installer aborts when `~/.codex/skills/keylink-image` already exists. Use the installed `install.ps1 -Remote` on Windows or `bash install.sh --remote` on macOS/Linux. If the installed copy predates remote updates and does not contain either installer, fetch the raw installer from `https://raw.githubusercontent.com/Tilmirs/keylink-codex-image/main/` into a temporary location, then run it in remote mode. Keep the source pinned to the repository's `main` branch.

If GitHub is unavailable, check the user's configured network route or local proxy without exposing credentials. The installers accept `KEYLINK_IMAGE_PROXY_URL` (and inherit standard `HTTPS_PROXY`/`HTTP_PROXY` settings; macOS/Linux also honors `ALL_PROXY`); Windows also accepts `-ProxyUrl`, and macOS/Linux accepts `--proxy-url`. A failed download must leave the currently installed version untouched.
