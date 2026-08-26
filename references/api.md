# Keylink Image API Contract

This skill treats Keylink as an OpenAI-compatible image service. Model IDs are pass-through values because the supported model catalog can change independently of the skill.

Use `node scripts/list_image_models.js` to query `/v1/models` before asking the user to choose among many models. Use `--use-ccswitch-credential` for direct Keylink discovery or `--use-codex-route --no-auth` to inspect the proxy's own catalog. Filtered results are evidence of image capability from a known ID or API metadata, not a guarantee that both endpoints work in the current deployment.

## Authentication and base URL

- Base URL: `https://keylinkclub.com`
- Header: `Authorization: Bearer <KEYLINK_API_KEY>`
- JSON content type: `application/json`

The helper accepts a base URL with or without a trailing `/v1`. It appends the correct route without duplicating `/v1`.

Credential precedence is explicit `--api-key`, explicit `--api-key-file`, then the current CCSwitch Codex provider when `--use-ccswitch-credential` is present, then `KEYLINK_IMAGE_API_KEY`, `KEYLINK_API_KEY`, `KEYLINK_IMAGE_API_KEY_FILE`, `KEYLINK_API_KEY_FILE`, and `~/.codex/secrets/keylink-image-api-key.txt`. The CCSwitch database is opened read-only and the credential remains in memory. CCSwitch lookup fails closed unless both the current Codex provider's saved `base_url` and the request destination use the `keylinkclub.com` host; it never changes the explicit request model.

## Automatic routing

`--route auto` applies these rules:

1. If no endpoint mode was explicitly supplied, GPT image models (`gpt-image-2`) try direct Images first and Chat second; Gemini image models (`gemini-3-pro-image`, `gemini-2.5-flash-image`, and `gemini-3.1-flash-image`) try Chat first and Images second.
2. Automatic known-model attempts use the direct Keylink base so both `/v1/images/*` and `/v1/chat/completions` can be tested consistently. Explicit Chat mode may reuse the active Codex provider when `config.toml` declares one.
3. HTTP errors, successful responses without an image payload, and image-download failures continue to the next automatic endpoint. Explicit endpoint/mode selections are never changed.
4. Do not send a direct image API key to a loopback Codex route. `--use-ccswitch-credential` is valid only for a direct Keylink request.

Use `--route direct` or `--route codex` to bypass automatic selection. An explicit `--endpoint` has highest precedence.

For CCSwitch or another local router that manages Codex's active provider, `--use-codex-route` reads the selected provider and `base_url` from `~/.codex/config.toml` on every run. `--proxy-base-url` has highest proxy-base precedence, followed by `KEYLINK_PROXY_BASE_URL`, then Codex configuration. This supports manually changed proxy hosts and ports without hardcoding them. If that loopback route accepts unauthenticated requests, pass `--no-auth`.

Codex-oriented local routers may expose only `/v1/responses` and `/v1/chat/completions`. A successful chat request does not prove that `/v1/images/generations` is available. If the local router returns 404, use a direct Keylink base URL with a configured key or, after explicit user approval, `--use-ccswitch-credential` to select `providers(app_type='codex', is_current=1).settings_config.auth.OPENAI_API_KEY` from CCSwitch.

## Chat-completions mode

Endpoint: `POST /v1/chat/completions`

Text-only request:

```json
{
  "model": "MODEL_ID",
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "IMAGE_PROMPT" }
      ]
    }
  ]
}
```

When an aspect ratio is supplied, the helper adds `extra_body.imageConfig.aspectRatio` and a matching system message for gateways that inspect either location.

For an edit in Chat mode, the user content also contains an OpenAI-style image block. Images mode remains preferred for known image models and uses the service's multipart edit contract; use Chat mode only when the deployment documents that contract:

```json
{
  "type": "image_url",
  "image_url": {
    "url": "data:image/png;base64,..."
  }
}
```

Remote reference URLs are passed directly. Local images are converted to data URLs in memory and are not copied into the skill directory.

## Images-generations mode

Endpoint: `POST /v1/images/generations`

```json
{
  "model": "MODEL_ID",
  "prompt": "IMAGE_PROMPT",
  "n": 1,
  "size": "1536x1024"
}
```

Text-only Images requests use JSON on `/v1/images/generations`:

```json
{
  "model": "MODEL_ID",
  "prompt": "IMAGE_PROMPT",
  "n": 1
}
```

## Images-edits mode

When a reference image is supplied in Images mode, the helper sends `POST /v1/images/edits` as `multipart/form-data`. The file is uploaded under the `image` field (not `input_image`):

```text
model=MODEL_ID
prompt=Edit the supplied image ... User instruction: ...
n=1
image=<binary image file>
```

The optional `size`, `quality`, `background`, `output_format`, and `response_format` fields are added as multipart text fields only when explicitly supplied. Local files are read as bytes in memory, and remote/data URLs are downloaded or decoded before upload so the service receives an actual file part.

## Accepted response shapes

The helper saves the first image found in these forms:

- `data[0].b64_json`
- `data[0].url`
- A `data:image/...;base64,...` URI in a chat response
- An image URL in chat message content, including Markdown image syntax

The script never switches model IDs after an API error. For an implicit known-model request, it tries the two endpoints in the model-specific order above. Authentication, rate-limit, content, network, server, unsupported-endpoint, and missing-image responses are recorded as failed attempts; if both attempts fail, report both safe errors and ask whether to try another discovered image model.

For a follow-up edit, pass the previously saved `OutputPath` as `--input-image-path`. For an uploaded attachment, pass its local path or an approved remote image URL. In Images mode the value is uploaded as the `image` multipart file to `/v1/images/edits`; in Chat mode it is sent as `image_url`. The helper adds an instruction to preserve unspecified content and requires an image payload in the response; it does not treat a text-only answer as a successful edit.

When an automatic endpoint retry is used, the result reports the effective `EndpointMode`/`Endpoint`, `AttemptOrder`, and `EndpointAttempts`; `FallbackFromEndpoint`/`FallbackReason` identify the failed attempt for compatibility with existing callers.

## Model and resolution discovery

`GET /v1/models` may return model IDs, display names, capabilities, sizes, aspect ratios, or no image metadata at all. The discovery helper reports:

- `AdvertisedSizes` and `AdvertisedAspectRatios`: values found in the response metadata.
- `AdvertisedResolutionTiers`: advertised pixel sizes grouped as `OneK`, `TwoK`, or `FourK` using the long edge (`<1800`, `1800–3499`, and `>=3500`). These are classification aids, not a guarantee that every channel behind the model will accept every size.
- `SuggestedSizes` and `SuggestedAspectRatios`: common candidates returned only when the service advertises no values; these are not claims of support.

Resolution selection is policy-driven. `gpt-image-2` and the supported Gemini image models use the conservative default sizes `1024x1024`, `1536x1024`, and `1024x1536`; an unadvertised `2048x2048` is not assumed. “Higher resolution”, “high resolution”, “2K”, “4K”, “UHD”, and explicit larger dimensions are high-resolution intent. For 16:9, use `2560x1440` for 2K-class and `3840x2160` for 4K. Preserve the selected model ID when sending every tier. If a submitted high-resolution request fails on one automatic endpoint, try the other endpoint with the same model and requested tier; if both fail, preserve both status/body errors and explain that the model, channel, or requested dimensions are unsupported. Do not silently retry at 1K or switch model IDs. A Chat success does not guarantee the requested pixel dimensions. If 4K is not advertised before a request, show the available sizes and ask for explicit approval before local upscaling; never describe a resized image as native 4K.

For `3840`-class 4K requests, the helper raises the effective request timeout to at least 480 seconds (8 minutes). An explicitly longer timeout remains in effect.

Model-level Nano Banana guidance is separate from the live Keylink catalog: `gemini-2.5-flash-image` is 1K-class, `gemini-3-pro-image` supports 1K/2K/4K, and `gemini-3.1-flash-image` supports 512p/1K/2K/4K. Gemini 3's documented 16:9 examples are `1376x768`, `2752x1536`, and `5504x3072` for 1K/2K/4K respectively. Treat these as guidance only when `/v1/models` does not expose channel-specific metadata.

For Chat Completions, prefer `--aspect-ratio` when the provider supports it. A requested pixel `--size` in the generations payload does not prove that chat will produce those exact dimensions. The helper rejects `--size` in chat mode and rejects `--aspect-ratio` in images mode instead of silently ignoring the user's selection. If the API does not publish resolution metadata, let the user choose from candidates or keep the model default and verify the returned image dimensions after generation.
