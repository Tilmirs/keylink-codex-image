---
name: keylink-image
description: Generate, create, draw, render, or edit images through Keylink. Prefer this installed skill for ordinary image-generation and image-editing requests even when the user does not mention Keylink. Do not use it when the user explicitly chooses another image provider or OpenAI's built-in imagegen/ImageGen. Supports chat completions, image generations, GPT Image and Gemini image models, and local or remote reference images.
---

# Keylink Image

Use `scripts/list_image_models.ps1` to discover the models and resolution metadata available to the current Keylink credential. Use `scripts/generate_image.ps1` for the final deterministic API call. These scripts are internal helpers: run them yourself and never ask the user to type or paste commands, JSON, parameters, paths, or credentials. Read `references/api.md` when selecting an endpoint mode or adapting request fields. Read `references/troubleshooting.md` when a model, proxy, credential, approval, network request, or installation fails.

## Provider Preference

Treat installation and invocation of this skill as the user's preference to fulfill the current image generation or editing request through Keylink. Once this skill is selected, use its scripts instead of calling a built-in image-generation tool in parallel. Switch to another image provider only when the user explicitly requests it, or after a Keylink failure when the user approves the provider change. This preference applies only to creating or editing images; do not activate the skill for ordinary image analysis, OCR, or questions about an existing image that require no generated output.

## Workflow

1. Reuse the prompt, model preference, endpoint preference, reference image, size or aspect ratio, and destination already supplied by the user.
2. If the user did not choose a model, discover available image models instead of asking for a model ID. If one suitable model is available, use it. If several are available or the user asks to compare them, show a concise numbered list with friendly names and known resolution options, then accept a natural-language name, number, or description.
3. Run `list_image_models.ps1` after approval when discovery is needed. Show endpoint choices, advertised sizes/aspect ratios, and clearly label fallback suggestions as unverified. Interpret replies such as "Gemini, 16:9", "the second one in landscape", or "square, high resolution" yourself; never ask for a command, parameter name, file path, or structured payload. Do not invent a Keylink model ID or claim support without discovery or current service documentation.
4. Use `-Route auto` unless the user explicitly selects a route. When the endpoint is omitted, auto routing sends `gpt-image-2`, `gemini-3-pro-image`, `gemini-2.5-flash-image`, and `gemini-3.1-flash-image` directly to Keylink `/v1/images/generations`. An explicit `-EndpointMode chat` sends any model through `/v1/chat/completions`; an explicit `images` selection sends any model through generations.
5. For image editing, use `chat` mode and pass exactly one of `-InputImagePath` or `-InputImageUrl`. Preserve the user's requested composition and unchanged details in the prompt. Do not assume the generations endpoint supports reference-image editing without current service documentation.
6. Resolve credentials without exposing them:
   - Prefer `-ApiKey`, then `-ApiKeyFile`. Without the CCSwitch flag, continue with `KEYLINK_IMAGE_API_KEY`, `KEYLINK_API_KEY`, `KEYLINK_IMAGE_API_KEY_FILE`, `KEYLINK_API_KEY_FILE`, and the default private key file.
   - When the user explicitly wants the active Codex/CCSwitch route, use `-UseCodexRoute`. Add `-NoAuth` only when that local route has been verified to accept requests without a Bearer token.
   - For a direct Keylink request, after the user approves local credential access, use `-UseCCSwitchCredential` to read the current CCSwitch Codex provider's `OPENAI_API_KEY`. It refuses providers or request destinations whose host is not `keylinkclub.com`. The database is read-only and the key stays in memory; never print it or forward it to a loopback proxy. The request model remains the explicit `-Model`; do not substitute CCSwitch's current text model.
   - Treat a key supplied in conversation as one-off unless the user explicitly asks to persist it.
   - Never print, commit, or place a key in generated output.
   - On Windows, when the user asks to configure a direct image credential, run `scripts/configure_key.ps1`; it uses hidden input and stores only the key-file path in `KEYLINK_IMAGE_API_KEY_FILE`.
7. Before model discovery or a live Keylink request, request the host's required filesystem/network approval. If approval infrastructure is unavailable or rejects execution before the request runs, explain which permission is needed and stop. Shell execution and credential handling remain the agent's responsibility. Do not diagnose the key as invalid from an approval-layer failure.
8. Report the saved output path and inspect image metadata and visual quality. Confirm requested subjects, constraints, text, logos, and watermarks.

## Internal Commands

The following examples are for the agent executing the skill, not instructions for the user. Translate the user's natural-language choices into these parameters yourself.

Explicit Chat Completions generation:

```powershell
& "$env:USERPROFILE/.codex/skills/keylink-image/scripts/generate_image.ps1" `
  -Prompt "A cinematic photograph of a coastal city at sunrise, no text" `
  -Model "MODEL_ID" `
  -AspectRatio "16:9"
```

Chat-based edit from a local image:

```powershell
& "$env:USERPROFILE/.codex/skills/keylink-image/scripts/generate_image.ps1" `
  -Prompt "Keep the subject and composition; change the scene to watercolor" `
  -Model "MODEL_ID" `
  -InputImagePath "C:/images/reference.png"
```

OpenAI-compatible images generation:

```powershell
& "$env:USERPROFILE/.codex/skills/keylink-image/scripts/generate_image.ps1" `
  -EndpointMode images `
  -Prompt "A clean product photo of a mechanical keyboard, no text" `
  -Model "MODEL_ID" `
  -Size "1536x1024"
```

Automatic images routing for a known image model:

```powershell
& "$env:USERPROFILE/.codex/skills/keylink-image/scripts/generate_image.ps1" `
  -Route auto `
  -Prompt "A scientifically grounded black hole and accretion disk, no text" `
  -Model "gpt-image-2" `
  -Size "1536x1024"
```

This selects direct Keylink `/v1/images/generations` without first trying chat. The same default applies to `gemini-3-pro-image`, `gemini-2.5-flash-image`, and `gemini-3.1-flash-image`. Pass `-EndpointMode chat` explicitly to use any of these model IDs through chat completions.

Use `-OutputPath` internally to choose a destination. Existing files are not overwritten unless `-Overwrite` is present. Use `-DryRun` internally to inspect the endpoint and sanitized payload without sending a request or requiring a key. Interpret natural-language destinations such as "save it to the desktop" yourself.

Internal model discovery helper:

```powershell
& "$env:USERPROFILE/.codex/skills/keylink-image/scripts/list_image_models.ps1" `
  -UseCCSwitchCredential
```

To inspect the model catalog exposed by the current local proxy instead, use `-UseCodexRoute -NoAuth`. If the proxy returns 404 or omits image models, repeat the direct Keylink query above.

Use `-IncludeAllModels` internally to include models that do not look image-capable. The script reads `/v1/models` and does not assume that every model exposed by one key can generate images. `AdvertisedSizes` and `AdvertisedAspectRatios` are only populated when the service returns matching metadata. When absent, `SuggestedSizes` and `SuggestedAspectRatios` are unverified candidates and must be confirmed through natural-language selection or by the service. Pass the user's selected pixel resolution with `-Size` for `images`; pass the selected aspect ratio with `-AspectRatio` for `chat`.

Direct generations using the credential from the current CCSwitch Codex provider:

```powershell
& "$env:USERPROFILE/.codex/skills/keylink-image/scripts/generate_image.ps1" `
  -Route direct `
  -UseCCSwitchCredential `
  -Prompt "A black hole with a luminous accretion disk and gravitational lensing, no text or watermark" `
  -Model "gpt-image-2" `
  -Size "1536x1024" `
  -OutputPath "$env:USERPROFILE/Desktop/keylink/black-hole-gpt-image-2.png"
```

Reuse the active Codex route managed by a local OpenAI-compatible router such as CCSwitch:

```powershell
& "$env:USERPROFILE/.codex/skills/keylink-image/scripts/generate_image.ps1" `
  -UseCodexRoute `
  -NoAuth `
  -Prompt "A scientifically grounded view of a black hole and accretion disk, no text" `
  -Model "gpt-image-2" `
  -AspectRatio "16:9"
```

`-UseCodexRoute` reads the active Codex provider's `base_url` each time, so a manually changed proxy address is honored. Use `-ProxyBaseUrl` or `KEYLINK_PROXY_BASE_URL` when the local proxy address has changed but Codex configuration has not yet been synchronized. `-UseCCSwitchCredential` is a separate, explicit, user-approved operation for direct Keylink requests.

## Endpoint Rules

- Default base URL: `https://keylinkclub.com`
- The script parameter default endpoint mode is `chat`; `-Route auto` overrides known image models to Images Generations as described below.
- Alternate route: `POST /v1/images/generations`
- `-Route auto` selects direct routing for known image models or images mode, and the active Codex provider for chat when available.
- `-Route direct` always calls Keylink and requires a direct image credential.
- `-Route codex` reads the active provider URL from Codex configuration unless `-ProxyBaseUrl` or `KEYLINK_PROXY_BASE_URL` overrides it.
- Override the direct image base with `KEYLINK_IMAGE_BASE_URL`, `KEYLINK_BASE_URL`, or `-BaseUrl`; override the complete URL with `-Endpoint`.
- Use `-UseCodexRoute` to reuse the active provider URL in Codex configuration. It cannot be combined with direct `-BaseUrl`; use `-ProxyBaseUrl` for a manually changed proxy address.
- Use `-NoAuth` only for a trusted route already verified to accept unauthenticated local requests.
- Some Codex-oriented local routes do not implement `/v1/images/generations`. A chat request succeeding does not prove images routing exists. If the local images route returns 404, use direct Keylink with a configured key or the explicitly approved `-UseCCSwitchCredential` flow; do not silently switch the model or endpoint.
- `images` mode is text-to-image only in this helper. Use `chat` mode when a reference image is present.

Keylink calls require outbound network access. If a valid request is blocked, request the environment's network approval. If that approval mechanism itself fails, explain the blocked permission and stop. Never transfer shell work to the user.
