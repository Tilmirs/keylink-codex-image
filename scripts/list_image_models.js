#!/usr/bin/env node
'use strict';

const common = require('./keylink_common');
const known = new Set([
  'gpt-image-2', 'gpt-image-2-openai', 'gpt-image-2-2k', 'gpt-image-2-pro', 'gpt-image-2-4k',
  'gemini-3-pro-image', 'gemini-2.5-flash-image', 'gemini-3.1-flash-image',
]);
const conservativeSuggestedSizes = ['1024x1024', '1536x1024', '1024x1536'];

function evidence(id, json) {
  if (known.has(id.toLowerCase())) return 'known-model-id';
  if (/image[_-]?generation\s*"?\s*:\s*true/i.test(json) || /(output[_-]?modalities|modalities)[^\]}]*image/i.test(json)) return 'api-capability-metadata';
  if (/(^|[-_.])(image|imagen|flux|dall[-_.]?e)([-_.]|$)/i.test(id)) return 'model-id-pattern';
  return null;
}

function resolutions(model) {
  const json = JSON.stringify(model);
  const sizes = new Set([...json.matchAll(/(?<!\d)(\d{2,5}\s*[xX]\s*\d{2,5})(?!\d)/g)].map((m) => m[1].replace(/\s/g, '').toLowerCase()));
  const walk = (value) => {
    if (!value || typeof value !== 'object') return;
    const width = Number(value.width); const height = Number(value.height);
    if (value.width != null && value.height != null && Number.isInteger(width) && Number.isInteger(height) && width > 0 && height > 0) sizes.add(`${width}x${height}`);
    Object.values(value).forEach(walk);
  };
  walk(model);
  return { sizes: [...sizes].sort(), ratios: [...new Set([...json.matchAll(/(?<!\d)(\d{1,2}:\d{1,2})(?!\d)/g)].map((m) => m[1]))].sort() };
}

function resolutionTiers(sizes) {
  const tiers = { OneK: [], TwoK: [], FourK: [] };
  for (const size of sizes) {
    const match = size.match(/^(\d+)x(\d+)$/);
    if (!match) continue;
    const longEdge = Math.max(Number(match[1]), Number(match[2]));
    if (longEdge >= 3500) tiers.FourK.push(size);
    else if (longEdge >= 1800) tiers.TwoK.push(size);
    else tiers.OneK.push(size);
  }
  return tiers;
}

async function main() {
  const args = common.parseArgs(process.argv.slice(2));
  common.validateArgs(args, [
    'apiKey', 'apiKeyFile', 'baseUrl', 'proxyBaseUrl', 'endpoint', 'timeoutSec',
    'useCcswitchCredential', 'useCodexRoute', 'noAuth', 'includeAllModels', 'dryRun',
  ], ['useCcswitchCredential', 'useCodexRoute', 'noAuth', 'includeAllModels', 'dryRun']);
  if (args.noAuth && (args.apiKey || args.apiKeyFile || args.useCcswitchCredential)) throw new Error('Do not combine --no-auth with an API key source.');
  if (args.useCodexRoute && args.baseUrl) throw new Error('Do not combine --use-codex-route with --base-url.');
  if (args.proxyBaseUrl && args.baseUrl) throw new Error('Specify either --proxy-base-url or --base-url, not both.');
  const timeoutSec = common.timeout(args.timeoutSec, 60);
  const useProxy = args.useCodexRoute || args.proxyBaseUrl;
  const base = useProxy ? common.codexRouteBase(args.proxyBaseUrl) : common.directBase(args.baseUrl);
  const resolvedEndpoint = args.endpoint || common.endpoint(base, 'models');
  if (args.useCcswitchCredential && !common.isKeylink(resolvedEndpoint)) throw new Error('The CCSwitch credential can only be sent to keylinkclub.com.');
  if (args.dryRun) return console.log(JSON.stringify({ Endpoint: resolvedEndpoint, CredentialSource: args.useCcswitchCredential ? 'ccswitch-current-codex-provider' : 'configured-key-source' }, null, 2));
  const noAuth = args.noAuth || (args.useCodexRoute && common.isLoopback(resolvedEndpoint));
  const key = noAuth ? undefined : common.resolveKey(args);
  const headers = key ? { authorization: `Bearer ${key}` } : {};
  const response = await common.fetchJson(resolvedEndpoint, { method: 'GET', headers }, timeoutSec, key, 'Keylink model discovery failed');
  const raw = response.data || response.models || (Array.isArray(response) ? response : undefined);
  if (!Array.isArray(raw)) throw new Error('The models response did not contain data or models.');
  const models = [];
  for (const item of raw) {
    const id = typeof item === 'string' ? item : common.first(item.id, item.model, item.name);
    if (!id) continue;
    const proof = evidence(id, JSON.stringify(item));
    if (!args.includeAllModels && !proof) continue;
    const resolution = resolutions(item);
    const tiers = resolutionTiers(resolution.sizes);
    models.push({
      Id: id, DisplayName: typeof item === 'string' ? id : common.first(item.display_name, item.name, id),
      ImageCapable: Boolean(proof), ImageCapabilityEvidence: proof, CandidateEndpointModes: ['chat', 'images'],
      AdvertisedSizes: resolution.sizes, AdvertisedAspectRatios: resolution.ratios,
      AdvertisedResolutionTiers: tiers,
      ResolutionSource: resolution.sizes.length || resolution.ratios.length ? 'api-metadata' : 'not-advertised',
      // These are deliberately conservative, unverified candidates.  A model
      // with no advertised metadata must never be presented with 2048x2048 as
      // an assumed default; GPT Plus currently rejects that rectangle.
      SuggestedSizes: resolution.sizes.length ? [] : conservativeSuggestedSizes,
      SuggestedAspectRatios: resolution.ratios.length ? [] : ['1:1', '16:9', '9:16', '4:3', '3:4'],
      HighResolutionModelHint: /(^|[-_.])pro([-_.]|$)|gpt-image-2-openai/i.test(id) ? id : undefined,
    });
  }
  models.sort((a, b) => a.Id.localeCompare(b.Id));
  console.log(JSON.stringify({ Endpoint: resolvedEndpoint, TotalModelsReturned: raw.length, FilteredModelCount: models.length, Models: models, Note: 'Advertised values come from API metadata. Suggested values are unverified candidates when the API publishes no resolution metadata.' }, null, 2));
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
