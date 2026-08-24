# Keylink Image Maintenance Guide

This repository is a Codex skill, not a general-purpose CLI. Preserve the natural-language user experience and keep shell commands, JSON payloads, credentials, and filesystem details inside the agent workflow.

## User contract

- Users describe the image, model preference, resolution or aspect ratio, reference image, and destination in natural language.
- Never ask users to type or paste PowerShell, JSON, API parameters, file paths, or API keys during normal image generation or editing.
- If more than one image model or resolution is available, present a short readable list and accept replies such as "the second model", "Gemini in 16:9", or "square high resolution".
- Ask for host approval immediately before reading a local CCSwitch credential, writing outside the workspace, or making a restricted network request.
- Report the saved image path and verify the returned file after generation.

## Repository map

| Path | Responsibility |
| --- | --- |
| `SKILL.md` | Runtime instructions, routing policy, credential rules, and agent-only command examples. |
| `agents/openai.yaml` | Codex display metadata and default invocation prompt. |
| `scripts/generate_image.ps1` | Deterministic Chat Completions and Images Generations requests, response extraction, and output saving. |
| `scripts/list_image_models.ps1` | `/v1/models` discovery and advertised-versus-suggested resolution reporting. |
| `scripts/read_ccswitch_credential.js` | Read-only lookup of the active CCSwitch Codex provider credential. |
| `scripts/configure_key.ps1` | Hidden-input setup for a separate Keylink credential file. |
| `references/api.md` | Request/response contract and endpoint details. |
| `references/troubleshooting.md` | Failure classification and safe recovery guidance. |
| `tests/` | Offline mock-server tests. Tests must not call the live Keylink API. |
| `install.ps1` | Repeatable local install/update with staging and backup. |
| `install.sh` | Repeatable macOS/Linux install/update and remote bootstrap from the public GitHub archive. |

## Installation documentation

- Keep the recommended first-install prompt in `README.md` based on Codex's built-in `$skill-installer` workflow.
- Because the skill lives at the repository root, the installer must use repository path `.` and explicit destination name `keylink-image`.
- Do not document a nonexistent `codex skills install` shell subcommand. Verify current behavior against the official Codex Skills documentation before changing installation instructions.
- The built-in installer is for first installation and stops when the destination exists. Keep `install.ps1` and `install.sh` documented as repeatable local installation and update paths.
- Keep the macOS Terminal one-liner pinned to the raw `install.sh` on this repository's `main` branch. The script must validate the downloaded package before replacing an installation.
- Keep `install.sh` compatible with the Bash 3.2 version shipped by older macOS releases. Do not require Homebrew, GNU-only flags, Python, Node.js, or `realpath`.
- Windows and Unix installers must install the same runtime files, preserve secrets and unrelated directories, stage replacements, and back up an existing version before updating.

## Skill selection and provider preference

- OpenAI's documented implicit selection mechanism matches the `SKILL.md` description; there is no standalone skill priority field. Keep generic image-generation and image-editing verbs at the beginning of the description.
- This installed skill represents a preference for Keylink on image creation and editing requests, including requests that do not explicitly name Keylink. Keep the boundary excluding image-only analysis, OCR, and an explicitly selected competing provider.
- Keep `policy.allow_implicit_invocation: true` in `agents/openai.yaml`.
- Explicit `$keylink-image` invocation is the only guaranteed selection mechanism when another installed skill has overlapping triggers. Document the natural-language “use Keylink” alternative without promising absolute precedence.
- Once selected, do not invoke a built-in image generator in parallel or silently fall back to another provider. A provider change requires an explicit user request or approval after a Keylink failure.

## Routing invariants

1. Keep both `POST /v1/chat/completions` and `POST /v1/images/generations` supported.
2. With `-Route auto`, known image models currently default to direct Images Generations:
   - `gpt-image-2`
   - `gemini-3-pro-image`
   - `gemini-2.5-flash-image`
   - `gemini-3.1-flash-image`
3. An explicit `-EndpointMode chat` must continue to allow any model through Chat Completions. Do not silently change the requested model, endpoint, or route after an API failure.
4. Reference-image editing uses Chat Completions. Images Generations is text-to-image only until Keylink documents a compatible edit request.
5. The Codex/CCSwitch proxy address is dynamic. Read the active provider configuration on every run. Preserve the override order: `-ProxyBaseUrl`, `KEYLINK_PROXY_BASE_URL`, then Codex `config.toml`.
6. A local proxy may support Chat Completions but return 404 for Images Generations. In that case, explain the route limitation and use direct Keylink only after the required credential approval.

## Credential and safety invariants

- Never print, log, commit, cache in generated output, or include a real credential in an error message.
- CCSwitch access must remain explicit through `-UseCCSwitchCredential` and must open the database read-only.
- Read only the current provider where `app_type='codex'` and `is_current=1`.
- A CCSwitch credential may be sent only when both the saved provider host and request destination are `keylinkclub.com`.
- Keep the selected generation model independent from CCSwitch's current text model.
- Never forward a direct Keylink credential to a loopback proxy.
- Persistent credentials belong under the Codex secrets directory or another user-approved private location, never inside this repository.
- Installation replaces only `$CODEX_HOME/skills/keylink-image`; it must not modify `$CODEX_HOME/secrets` or CCSwitch data.

## Model and resolution discovery

- Treat `/v1/models` as the current source of available model IDs and capability metadata.
- `AdvertisedSizes` and `AdvertisedAspectRatios` are service-provided facts.
- `SuggestedSizes` and `SuggestedAspectRatios` are unverified fallbacks and must be labeled as such.
- Use pixel `Size` for Images Generations and `AspectRatio` for Chat Completions. Reject incompatible parameters instead of silently ignoring them.
- Verify the actual width and height of the saved result because chat output may not expose a fixed pixel contract.

## Where to make common changes

- Add or remove an auto-routed model in `scripts/generate_image.ps1`, then update `SKILL.md`, `references/api.md`, and the routing tests together.
- Adapt request fields or response extraction in `scripts/generate_image.ps1` and document the contract in `references/api.md`.
- Adapt model metadata parsing in `scripts/list_image_models.ps1` and add a representative mocked `/v1/models` response.
- Add failure guidance to `references/troubleshooting.md` only after the behavior has been observed or documented.
- Keep `README.md` user-facing. Put agent execution rules in `SKILL.md` and maintenance invariants in this file.

## Validation before release

Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_generate_image.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_list_image_models.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_install.ps1
python "$env:USERPROFILE\.codex\skills\.system\skill-creator\scripts\quick_validate.py" .
```

On macOS/Linux, also run:

```bash
bash ./tests/test_install.sh
python3 "$HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py" .
```

If `python` is not on `PATH`, use the Python executable returned by Codex's workspace-dependency loader. Also parse every PowerShell file with the PowerShell AST before release. Keep tests offline, use obvious fake credentials, and scan the repository for accidentally committed secrets.

## Known failure history

- Some image model IDs are rejected by Chat Completions even when Images Generations works.
- Some CCSwitch/Codex routes expose chat or responses endpoints but not `/v1/images/generations`.
- Approval infrastructure can fail before Keylink receives a request; do not misdiagnose that as an invalid key or model.
- An API key does not itself contain a model or resolution catalog; discover that information from `/v1/models`.
- Users may manually change the proxy address, so do not hardcode a localhost port.
