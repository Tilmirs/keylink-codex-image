#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const common = require('./keylink_common');

// These are routing hints only.  The service catalog remains authoritative for
// actual availability and resolution support.
const knownImageModels = new Set([
  'gpt-image-2',
  'gemini-3-pro-image', 'gemini-2.5-flash-image', 'gemini-3.1-flash-image',
]);
const conservativeSizes = {
  square: ['1024x1024'],
  landscape: ['1536x1024', '1024x1024'],
  portrait: ['1024x1536', '1024x1024'],
};
const mimeTypes = { '.png': 'image/png', '.webp': 'image/webp', '.gif': 'image/gif', '.avif': 'image/avif', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg' };
const editInstruction = 'Edit the supplied image according to the user instruction. Preserve all content the user did not ask to change. Return the edited image itself, not a description or instructions.';

function fail(message) { throw new Error(message); }

function isKnownImageModel(model) {
  const normalized = String(model || '').toLowerCase();
  return knownImageModels.has(normalized);
}

function isGeminiImageModel(model) {
  return /^gemini-.+-image$/i.test(String(model || ''));
}

function preferredEndpointModes(model) {
  if (isGeminiImageModel(model)) return ['chat', 'images'];
  if (isKnownImageModel(model)) return ['images', 'chat'];
  // Unknown models stay on the documented Chat default.  Discovery should
  // establish image capability before the two-endpoint image retry policy is
  // used for a model.
  return ['chat'];
}

function parseSize(size) {
  const match = String(size || '').match(/^(\d+)x(\d+)$/);
  if (!match) return undefined;
  const width = Number(match[1]);
  const height = Number(match[2]);
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1) return undefined;
  return { width, height, area: width * height, orientation: width === height ? 'square' : (width > height ? 'landscape' : 'portrait') };
}

function conservativeFallbackSizes(size) {
  const parsed = parseSize(size);
  if (!parsed) return [];
  // Any request at or above the 2K-class boundary is an explicit high-resolution
  // request.  Do not silently turn it into a 1K image; surface the service error
  // so the caller can explain whether the current channel lacks 2K/4K support.
  if (Math.max(parsed.width, parsed.height) >= 1600) return [];
  return conservativeSizes[parsed.orientation].filter((candidate) => {
    const candidateSize = parseSize(candidate);
    return candidateSize && candidateSize.area < parsed.area;
  });
}

function isHighResolutionSize(size) {
  const parsed = parseSize(size);
  return Boolean(parsed && Math.max(parsed.width, parsed.height) >= 1600);
}

function resolutionTier(size) {
  const parsed = parseSize(size);
  if (!parsed) return undefined;
  const edge = Math.max(parsed.width, parsed.height);
  if (edge >= 3500) return '4K';
  if (edge >= 1600) return '2K';
  return '1K';
}

function suggestedModelFromError(error) {
  const details = `${error?.responseBody || ''} ${error?.message || ''}`;
  return details.match(/\b(gpt-image-[a-z0-9-]+)\b/i)?.[1];
}

function isUnsupportedSizeError(error) {
  const status = Number(error?.status);
  if (![400, 422].includes(status)) return false;
  const details = `${error?.responseBody || ''} ${error?.message || ''}`;
  const mentionsSize = /(size|resolution|dimension|pixel|\d{3,5}\s*x\s*\d{3,5}|\b(?:1k|2k|4k)\b)/i.test(details);
  const rejectsSize = /(unsupported|not supported|does not support|invalid|available sizes?|choose|use|不支持|改用)/i.test(details);
  return mentionsSize && rejectsSize;
}

function mimeFromBytes(bytes, fallbackPath) {
  bytes = Buffer.from(bytes).subarray(0, 16);
  if (bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.toString('ascii', 0, 6) === 'GIF87a' || bytes.toString('ascii', 0, 6) === 'GIF89a') return 'image/gif';
  if (bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  if (bytes.toString('ascii', 4, 8) === 'ftyp' && ['avif', 'avis'].includes(bytes.toString('ascii', 8, 12))) return 'image/avif';
  return mimeTypes[path.extname(fallbackPath || '').toLowerCase()];
}
function imageMime(filePath) { return mimeFromBytes(fs.readFileSync(filePath), filePath); }
function imagePayload(response, key) {
  const first = Array.isArray(response.data) ? response.data[0] : undefined;
  if (first?.b64_json) return { kind: 'base64', value: first.b64_json };
  if (first?.url) return { kind: 'url', value: first.url };
  const json = JSON.stringify(response);
  const data = json.match(/data:image\/[A-Za-z0-9.+-]+;base64,([A-Za-z0-9+/=_-]+)/);
  if (data) return { kind: 'base64', value: data[1] };
  const urls = [...json.matchAll(/https?:\\?\/\\?\/[^"'\s<>\)]+/g)].map((match) => match[0].replaceAll('\\/', '/').replace(/\\$/, ''));
  const likely = urls.find((url) => /(\.(png|jpe?g|webp|gif|avif)(\?|$)|\/images?\/|image=)/i.test(url)) || (urls.length === 1 ? urls[0] : undefined);
  if (likely) return { kind: 'url', value: likely };
  const preview = key ? json.slice(0, 1000).split(key).join('<redacted>') : json.slice(0, 1000);
  fail(`The API response did not contain a supported image payload. Response preview: ${preview}`);
}

function parseImageDataUrl(value) {
  const match = String(value).match(/^data:(image\/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=_-]+)$/i);
  if (!match) fail('Reference image data URL must contain a base64-encoded image.');
  const mime = match[1].toLowerCase();
  const bytes = Buffer.from(match[2].replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  if (!bytes.length) fail('Reference image data URL is empty.');
  return { bytes, mime, filename: `reference.${mime.split('/')[1].replace('jpeg', 'jpg')}` };
}

function filenameFromUrl(value, mime) {
  try {
    const name = path.basename(new URL(value).pathname);
    if (name && name !== '.' && name !== '/') return name;
  } catch { /* use a safe fallback */ }
  return `reference.${mime?.split('/')[1]?.replace('jpeg', 'jpg') || 'png'}`;
}

async function fetchReferenceImage(value, timeoutSec) {
  if (String(value).startsWith('data:')) return parseImageDataUrl(value);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutSec * 1000);
  try {
    const response = await fetch(value, { signal: controller.signal });
    if (!response.ok) fail(`Reference image download failed: HTTP ${response.status}`);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (!bytes.length) fail('Reference image download returned an empty file.');
    const headerMime = response.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase();
    const mime = headerMime?.startsWith('image/') ? headerMime : mimeFromBytes(bytes, filenameFromUrl(value));
    if (!mime) fail('Reference image URL did not return a supported image content type.');
    return { bytes, mime, filename: filenameFromUrl(value, mime) };
  } finally { clearTimeout(timer); }
}

async function buildReferenceImage(args, inputImageValue, timeoutSec) {
  if (args.inputImagePath) {
    const input = path.resolve(args.inputImagePath);
    const bytes = fs.readFileSync(input);
    if (!bytes.length) fail(`Input image is empty: ${input}`);
    return { bytes, mime: imageMime(input), filename: path.basename(input) || 'reference.png' };
  }
  return fetchReferenceImage(inputImageValue, timeoutSec);
}

function appendFormField(form, name, value) {
  if (value !== undefined && value !== null && String(value).length) form.append(name, String(value));
}

function buildImagesEditForm(reference, args, prompt) {
  const form = new FormData();
  appendFormField(form, 'model', args.model);
  appendFormField(form, 'prompt', prompt);
  appendFormField(form, 'n', 1);
  for (const [arg, field] of [['size', 'size'], ['quality', 'quality'], ['background', 'background'], ['outputFormat', 'output_format'], ['responseFormat', 'response_format']]) {
    appendFormField(form, field, args[arg]);
  }
  const blob = new Blob([reference.bytes], { type: reference.mime });
  form.append('image', blob, reference.filename);
  return form;
}

function gcd(a, b) {
  while (b) [a, b] = [b, a % b];
  return a;
}

function aspectRatioFromSize(size) {
  const match = String(size || '').match(/^(\d+)x(\d+)$/);
  if (!match) return undefined;
  const width = Number(match[1]);
  const height = Number(match[2]);
  const divisor = gcd(width, height);
  return `${width / divisor}:${height / divisor}`;
}

function buildChatPayload(args, inputImageValue, hasInputImage) {
  const aspectRatio = args.aspectRatio || aspectRatioFromSize(args.size);
  const content = [{ type: 'text', text: args.prompt }];
  if (inputImageValue) content.push({ type: 'image_url', image_url: { url: inputImageValue } });
  const messages = [];
  if (hasInputImage) messages.push({ role: 'system', content: editInstruction });
  if (aspectRatio) messages.push({ role: 'system', content: JSON.stringify({ imageConfig: { aspectRatio } }) });
  messages.push({ role: 'user', content });
  const payload = { model: args.model, messages };
  if (aspectRatio) payload.extra_body = { imageConfig: { aspectRatio } };
  return payload;
}

function buildImagesPayload(args, inputImageValue, hasInputImage, size) {
  const requestArgs = { ...args, size };
  const payload = hasInputImage
    ? { model: requestArgs.model, prompt: `${editInstruction}\nUser instruction: ${requestArgs.prompt}`, n: 1 }
    : { model: requestArgs.model, prompt: requestArgs.prompt, n: 1 };
  for (const [arg, field] of [['size', 'size'], ['quality', 'quality'], ['background', 'background'], ['outputFormat', 'output_format'], ['responseFormat', 'response_format']]) {
    if (requestArgs[arg]) payload[field] = requestArgs[arg];
  }
  if (args.dryRun && hasInputImage) {
    if (args.inputImagePath) {
      const input = path.resolve(args.inputImagePath);
      payload.image = { field: 'image', filename: path.basename(input) || 'reference.png', contentType: imageMime(input), bytes: fs.statSync(input).size };
    } else {
      payload.image = { field: 'image', source: inputImageValue };
    }
  }
  return payload;
}

function modelRetryGuidance(model) {
  if (String(model || '').toLowerCase() === 'gpt-image-2') {
    return 'Ask the user whether to try one of the discovered Gemini image models.';
  }
  return 'Ask the user whether to try another discovered image model; recommend gpt-image-2 when it is available.';
}

async function main() {
  const args = common.parseArgs(process.argv.slice(2));
  common.validateArgs(args, [
    'prompt', 'model', 'endpointMode', 'route', 'aspectRatio', 'size', 'quality', 'background', 'outputFormat',
    'responseFormat', 'inputImageUrl', 'inputImagePath', 'apiKey', 'apiKeyFile', 'baseUrl', 'proxyBaseUrl',
    'endpoint', 'outputPath', 'timeoutSec', 'overwrite', 'useCodexRoute', 'useCcswitchCredential', 'noAuth', 'dryRun',
  ], ['overwrite', 'useCodexRoute', 'useCcswitchCredential', 'noAuth', 'dryRun']);
  if (!args.prompt || !args.model) fail('--prompt and --model are required.');
  if (args.inputImageUrl && args.inputImagePath) fail('Specify either --input-image-url or --input-image-path, not both.');
  if (args.noAuth && (args.apiKey || args.apiKeyFile || args.useCcswitchCredential)) fail('Do not combine --no-auth with an API key source.');
  if (args.useCodexRoute && args.route) fail('Do not combine --use-codex-route with --route.');
  if (args.useCodexRoute && args.baseUrl) fail('Do not combine --use-codex-route with --base-url.');
  if (args.proxyBaseUrl && args.route === 'direct') fail('--proxy-base-url cannot be used with --route direct.');
  if (args.proxyBaseUrl && args.endpoint) fail('Specify either --proxy-base-url or --endpoint, not both.');
  if (args.aspectRatio && !/^\d+:\d+$/.test(args.aspectRatio)) fail('--aspect-ratio must use W:H notation.');
  if (args.responseFormat && !['url', 'b64_json'].includes(args.responseFormat)) fail('--response-format must be url or b64_json.');
  const requestedTimeoutSec = common.timeout(args.timeoutSec, 300);
  // Native 4K generation/editing can take several minutes.  Keep an explicit
  // longer timeout, but never let a 3840-class request expire before 8 minutes.
  const timeoutSec = resolutionTier(args.size) === '4K'
    ? Math.max(requestedTimeoutSec, 480)
    : requestedTimeoutSec;

  const hasInputImage = Boolean(args.inputImageUrl || args.inputImagePath);
  const endpointModeWasExplicit = args.endpointMode !== undefined;
  const mode = args.endpointMode || preferredEndpointModes(args.model)[0];
  if (!['chat', 'images'].includes(mode)) fail('--endpoint-mode must be chat or images.');
  if (endpointModeWasExplicit && mode === 'chat' && args.size) fail('Chat mode uses --aspect-ratio; --size is only for images mode.');
  if (endpointModeWasExplicit && mode === 'images' && args.aspectRatio) fail('Images mode uses --size; --aspect-ratio is only for chat mode.');
  if (!endpointModeWasExplicit && args.size && args.aspectRatio) fail('Automatic endpoint mode accepts either --size or --aspect-ratio, not both.');
  const requestedModel = args.model;
  const requestedSize = args.size;
  // Preserve the user-selected model ID, including for high-resolution
  // requests.  The service/channel decides whether that model accepts the
  // requested size; a rejection is surfaced rather than silently switching IDs.
  const effectiveArgs = { ...args, model: requestedModel };

  const canTryBothEndpoints = !endpointModeWasExplicit && !args.endpoint;
  const attemptModes = canTryBothEndpoints ? preferredEndpointModes(requestedModel) : [mode];
  let route = args.useCodexRoute ? 'codex' : (args.route || 'auto');
  if (args.endpoint) route = 'custom';
  if (route === 'auto') {
    if (args.baseUrl || canTryBothEndpoints || mode === 'images') route = 'direct';
    else { try { common.codexRouteBase(args.proxyBaseUrl); route = 'codex'; } catch { route = 'direct'; } }
  }
  if (!['direct', 'codex', 'custom'].includes(route)) fail('--route must be auto, direct, or codex.');
  const base = route === 'codex' ? common.codexRouteBase(args.proxyBaseUrl) : common.directBase(args.baseUrl);
  const endpointForMode = (endpointMode) => args.endpoint || common.endpoint(base,
    endpointMode === 'chat' ? 'chat/completions' : (hasInputImage ? 'images/edits' : 'images/generations'));
  const resolvedEndpoint = endpointForMode(mode);
  if (args.useCcswitchCredential && (route === 'codex' || !common.isKeylink(resolvedEndpoint))) fail('The CCSwitch credential can only be sent directly to keylinkclub.com.');

  let inputImageValue;
  if (args.inputImageUrl) {
    let inputUrl;
    try { inputUrl = new URL(args.inputImageUrl); } catch { fail('--input-image-url must be a valid HTTP(S) or image data URL.'); }
    if (!['http:', 'https:', 'data:'].includes(inputUrl.protocol) || (inputUrl.protocol === 'data:' && !args.inputImageUrl.startsWith('data:image/'))) {
      fail('--input-image-url must be a valid HTTP(S) or image data URL.');
    }
    inputImageValue = args.inputImageUrl;
  } else if (args.inputImagePath) {
    const input = path.resolve(args.inputImagePath);
    if (!fs.existsSync(input) || !fs.statSync(input).isFile()) fail(`Input image does not exist or is not a file: ${input}`);
    if (fs.statSync(input).size === 0) fail(`Input image is empty: ${input}`);
    const mime = imageMime(input);
    if (!mime) fail('Input image must be PNG, JPEG, WebP, GIF, or AVIF.');
    const value = args.dryRun ? `<omitted:${fs.statSync(input).size}-bytes>` : fs.readFileSync(input).toString('base64');
    inputImageValue = `data:${mime};base64,${value}`;
  }

  let activeSize = args.size;
  const payloadForMode = (endpointMode, size) => endpointMode === 'chat'
    ? buildChatPayload({ ...effectiveArgs, size }, inputImageValue, hasInputImage)
    : buildImagesPayload(effectiveArgs, inputImageValue, hasInputImage, size);
  const payload = payloadForMode(mode, activeSize);
  if (args.dryRun) {
    const attempts = attemptModes.map((endpointMode) => ({
      EndpointMode: endpointMode,
      Endpoint: endpointForMode(endpointMode),
      RequestFormat: endpointMode === 'images' && hasInputImage ? 'multipart/form-data' : 'application/json',
      Payload: payloadForMode(endpointMode, activeSize),
    }));
    return console.log(JSON.stringify({
      Operation: hasInputImage ? 'edit' : 'generate', EndpointMode: mode, Route: route, Endpoint: resolvedEndpoint,
      RequestFormat: attempts[0].RequestFormat, AttemptOrder: attemptModes, Attempts: attempts,
      RequestedModel: requestedModel, Model: effectiveArgs.model, RequestedSize: requestedSize,
      Size: activeSize, ResolutionTier: resolutionTier(activeSize), RequestedTimeoutSec: requestedTimeoutSec,
      TimeoutSec: timeoutSec, Payload: payload,
    }, null, 2));
  }

  const noAuth = args.noAuth || (route === 'codex' && common.isLoopback(resolvedEndpoint) && !args.apiKey && !args.apiKeyFile);
  const key = noAuth ? undefined : common.resolveKey(args);
  let reference;
  if (attemptModes.includes('images') && hasInputImage) {
    reference = await buildReferenceImage(args, inputImageValue, timeoutSec);
  }
  let activeMode = mode;
  let activeEndpoint = resolvedEndpoint;
  let activePayload = payload;
  let fallbackFromEndpoint;
  let fallbackReason;
  let sizeFallbackFrom;
  let sizeFallbackReason;
  let suggestedModel;
  let image;
  let imageBytes;
  const endpointAttempts = [];

  const downloadImage = async (candidate, endpoint) => {
    if (candidate.kind === 'base64') {
      const bytes = Buffer.from(candidate.value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
      if (!bytes.length) fail('The API returned an empty base64 image.');
      return bytes;
    }
    const downloadHeaders = {};
    if (key && new URL(candidate.value).host === new URL(endpoint).host) downloadHeaders.authorization = `Bearer ${key}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutSec * 1000);
    try {
      const download = await fetch(candidate.value, { headers: downloadHeaders, signal: controller.signal });
      if (!download.ok) fail(`Image download failed: HTTP ${download.status}`);
      const bytes = Buffer.from(await download.arrayBuffer());
      if (!bytes.length) fail('Image download returned an empty file.');
      return bytes;
    } finally { clearTimeout(timer); }
  };

  const sendImages = async (size, endpoint) => {
    const requestArgs = { ...effectiveArgs, size };
    const requestPayload = buildImagesPayload(effectiveArgs, inputImageValue, hasInputImage, size);
    const requestHeaders = {};
    if (key) requestHeaders.authorization = `Bearer ${key}`;
    if (hasInputImage) {
      return common.fetchJson(endpoint, {
        method: 'POST',
        headers: requestHeaders,
        body: buildImagesEditForm(reference, requestArgs, requestPayload.prompt),
      }, timeoutSec, key, 'Keylink request failed');
    }
    requestHeaders['content-type'] = 'application/json; charset=utf-8';
    return common.fetchJson(endpoint, {
      method: 'POST', headers: requestHeaders, body: JSON.stringify(requestPayload),
    }, timeoutSec, key, 'Keylink request failed');
  };

  const tryImages = async () => {
    const endpoint = endpointForMode('images');
    const sizeCandidates = conservativeFallbackSizes(activeSize);
    while (true) {
      activePayload = buildImagesPayload(effectiveArgs, inputImageValue, hasInputImage, activeSize);
      try {
        const response = await sendImages(activeSize, endpoint);
        const candidate = imagePayload(response, key);
        const bytes = await downloadImage(candidate, endpoint);
        return { mode: 'images', endpoint, payload: activePayload, image: candidate, bytes };
      } catch (error) {
        suggestedModel ||= suggestedModelFromError(error);
        if (isUnsupportedSizeError(error) && sizeCandidates.length) {
          const nextSize = sizeCandidates.shift();
          sizeFallbackFrom ||= activeSize;
          sizeFallbackReason ||= `The service rejected ${activeSize}; retried at ${nextSize}.`;
          activeSize = nextSize;
          continue;
        }
        throw error;
      }
    }
  };

  const tryChat = async () => {
    const endpoint = endpointForMode('chat');
    activePayload = buildChatPayload({ ...effectiveArgs, size: activeSize }, inputImageValue, hasInputImage);
    const chatHeaders = {};
    if (key) chatHeaders.authorization = `Bearer ${key}`;
    chatHeaders['content-type'] = 'application/json; charset=utf-8';
    const response = await common.fetchJson(endpoint, {
      method: 'POST', headers: chatHeaders, body: JSON.stringify(activePayload),
    }, timeoutSec, key, 'Keylink request failed');
    const candidate = imagePayload(response, key);
    const bytes = await downloadImage(candidate, endpoint);
    return { mode: 'chat', endpoint, payload: activePayload, image: candidate, bytes };
  };

  let selected;
  for (const endpointMode of attemptModes) {
    try {
      selected = endpointMode === 'images' ? await tryImages() : await tryChat();
      endpointAttempts.push({ EndpointMode: endpointMode, Endpoint: selected.endpoint, Status: 'succeeded' });
      break;
    } catch (error) {
      suggestedModel ||= suggestedModelFromError(error);
      endpointAttempts.push({ EndpointMode: endpointMode, Endpoint: endpointForMode(endpointMode), Status: 'failed', Error: error.message });
    }
  }

  if (!selected) {
    if (attemptModes.length === 1) {
      const error = endpointAttempts[0].Error;
      const highResolutionMessage = isHighResolutionSize(activeSize)
        ? `High-resolution ${resolutionTier(activeSize)} request (${activeSize}) failed on model ${effectiveArgs.model}; no lower-resolution fallback was attempted. `
        : '';
      fail(`${highResolutionMessage}${error}`);
    }
    const errors = endpointAttempts.map((attempt) =>
      `${attempt.EndpointMode === 'chat' ? 'Chat' : (hasInputImage ? 'Images Edits' : 'Images Generations')} endpoint (${attempt.Endpoint}) failed: ${attempt.Error}`);
    const highResolutionMessage = isHighResolutionSize(activeSize)
      ? `High-resolution ${resolutionTier(activeSize)} request (${activeSize}) failed. `
      : '';
    fail(`${highResolutionMessage}Both Keylink endpoints failed for model ${effectiveArgs.model}. ${errors.join(' | ')} ${modelRetryGuidance(effectiveArgs.model)}`);
  }

  activeMode = selected.mode;
  activeEndpoint = selected.endpoint;
  activePayload = selected.payload;
  image = selected.image;
  imageBytes = selected.bytes;
  const failedAttempt = endpointAttempts.find((attempt) => attempt.Status === 'failed');
  if (failedAttempt) {
    fallbackFromEndpoint = failedAttempt.Endpoint;
    fallbackReason = `${failedAttempt.EndpointMode} attempt failed: ${failedAttempt.Error}`;
  }
  const extension = String(args.outputFormat || 'png').replace(/^\./, '');
  const output = path.resolve(args.outputPath || `keylink-image-${new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15)}.${extension}`);
  if (fs.existsSync(output) && !args.overwrite) fail(`Output file already exists: ${output}. Use --overwrite to replace it.`);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, imageBytes);
  const bytes = fs.statSync(output).size;
  if (!bytes) fail(`The saved image is empty: ${output}`);
  console.log(JSON.stringify({
    OutputPath: output, NextEditInputPath: output, Bytes: bytes, Operation: hasInputImage ? 'edit' : 'generate',
    RequestedModel: requestedModel, Model: effectiveArgs.model, EndpointMode: activeMode, Route: route, Endpoint: activeEndpoint,
    FallbackFromEndpoint: fallbackFromEndpoint, FallbackReason: fallbackReason,
    AttemptOrder: attemptModes, EndpointAttempts: endpointAttempts,
    RequestedSize: requestedSize, Size: activeMode === 'images' ? activeSize : undefined, SizeFallbackFrom: sizeFallbackFrom,
    SizeFallbackReason: sizeFallbackReason, SuggestedModel: suggestedModel,
    RequestedResolutionTier: resolutionTier(requestedSize), ResolutionTier: activeMode === 'images' ? resolutionTier(activeSize) : undefined,
    PixelSizeContract: activeMode === 'images' ? 'requested' : 'not-guaranteed',
    RequestedTimeoutSec: requestedTimeoutSec, TimeoutSec: timeoutSec,
  }, null, 2));
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
