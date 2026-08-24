# Keylink Image API Contract

This skill treats Keylink as an OpenAI-compatible image service. Model IDs are pass-through values because the supported model catalog can change independently of the skill.

Use `scripts/list_image_models.ps1` to query `/v1/models` before asking the user to choose among many models. Use `-UseCCSwitchCredential` for direct Keylink discovery or `-UseCodexRoute -NoAuth` to inspect the proxy's own catalog. Filtered results are evidence of image capability from a known ID or API metadata, not a guarantee that both endpoints work in the current deployment.

## Authentication and base URL

- Base URL: `https://keylinkclub.com`
- Header: `Authorization: Bearer <KEYLINK_API_KEY>`
- JSON content type: `application/json`

The helper accepts a base URL with or without a trailing `/v1`. It appends the correct route without duplicating `/v1`.

Credential precedence is explicit `-ApiKey`, explicit `-ApiKeyFile`, then the current CCSwitch Codex provider when `-UseCCSwitchCredential` is present, then `KEYLINK_IMAGE_API_KEY`, `KEYLINK_API_KEY`, `KEYLINK_IMAGE_API_KEY_FILE`, `KEYLINK_API_KEY_FILE`, and `~/.codex/secrets/keylink-image-api-key.txt`. The CCSwitch database is opened read-only and the credential remains in memory. CCSwitch lookup fails closed unless both the current Codex provider's saved `base_url` and the request destination use the `keylinkclub.com` host; it never changes the explicit request model.

## Automatic routing

`-Route auto` applies these rules:

1. If no endpoint mode was explicitly supplied and the model is `gpt-image-2`, `gemini-3-pro-image`, `gemini-2.5-flash-image`, or `gemini-3.1-flash-image`, select `images` mode.
2. Send all images-mode requests directly to Keylink.
3. For chat mode, reuse the active Codex provider when `config.toml` declares one; otherwise call Keylink directly.
4. Do not send a direct image API key to a loopback Codex route. `-UseCCSwitchCredential` is valid only for a direct Keylink request.

Use `-Route direct` or `-Route codex` to bypass automatic selection. An explicit `-Endpoint` has highest precedence.

For CCSwitch or another local router that manages Codex's active provider, `-UseCodexRoute` reads the selected provider and `base_url` from `~/.codex/config.toml` on every run. `-ProxyBaseUrl` has highest proxy-base precedence, followed by `KEYLINK_PROXY_BASE_URL`, then Codex configuration. This supports manually changed proxy hosts and ports without hardcoding them. If that loopback route accepts unauthenticated requests, pass `-NoAuth`.

Codex-oriented local routers may expose only `/v1/responses` and `/v1/chat/completions`. A successful chat request does not prove that `/v1/images/generations` is available. If the local router returns 404, use a direct Keylink base URL with a configured key or, after explicit user approval, `-UseCCSwitchCredential` to select `providers(app_type='codex', is_current=1).settings_config.auth.OPENAI_API_KEY` from CCSwitch.

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

For an edit, the user content also contains an OpenAI-style image block:

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

The optional `quality`, `background`, `output_format`, and `response_format` fields are sent only when explicitly provided. This avoids rejecting requests for models that do not implement those options.

## Accepted response shapes

The helper saves the first image found in these forms:

- `data[0].b64_json`
- `data[0].url`
- A `data:image/...;base64,...` URI in a chat response
- An image URL in chat message content, including Markdown image syntax

The script does not silently switch models or endpoints after an API error. Surface the service error so Codex can ask the user for a natural-language correction. If the host approval layer blocks filesystem or network access, explain the required permission and stop. Shell execution and credentials remain internal to the host.

## Model and resolution discovery

`GET /v1/models` may return model IDs, display names, capabilities, sizes, aspect ratios, or no image metadata at all. The discovery helper reports:

- `AdvertisedSizes` and `AdvertisedAspectRatios`: values found in the response metadata.
- `SuggestedSizes` and `SuggestedAspectRatios`: common candidates returned only when the service advertises no values; these are not claims of support.

For Chat Completions, prefer `-AspectRatio` when the provider supports it. A requested pixel `Size` in the generations payload does not prove that chat will produce those exact dimensions. The helper rejects `-Size` in chat mode and rejects `-AspectRatio` in images mode instead of silently ignoring the user's selection. If the API does not publish resolution metadata, let the user choose from candidates or keep the model default and verify the returned image dimensions after generation.
