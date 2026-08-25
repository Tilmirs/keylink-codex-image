'use strict';

const assert = require('node:assert');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'keylink-node-test-'));
const tinyPng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+Xw3lWQAAAABJRU5ErkJggg==';
const requests = [];

function parseMultipart(body, contentType) {
  const boundary = contentType.match(/boundary=(?:"([^"]+)"|([^;]+))/i)?.[1] || contentType.match(/boundary=(?:"([^"]+)"|([^;]+))/i)?.[2];
  assert.ok(boundary, 'multipart request has a boundary');
  const marker = Buffer.from(`--${boundary}`);
  const fields = {};
  const files = {};
  let offset = 0;
  while (true) {
    const start = body.indexOf(marker, offset);
    if (start < 0) break;
    const partStart = start + marker.length;
    if (body.subarray(partStart, partStart + 2).equals(Buffer.from('--'))) break;
    const headerStart = body.indexOf(Buffer.from('\r\n'), partStart);
    if (headerStart < 0) break;
    const dataStart = body.indexOf(Buffer.from('\r\n\r\n'), headerStart);
    if (dataStart < 0) break;
    const headerText = body.subarray(partStart + 2, dataStart).toString('utf8');
    const dataEnd = body.indexOf(Buffer.from(`\r\n--${boundary}`), dataStart + 4);
    if (dataEnd < 0) break;
    const content = body.subarray(dataStart + 4, dataEnd);
    const name = headerText.match(/name="([^"]+)"/i)?.[1];
    const filename = headerText.match(/filename="([^"]*)"/i)?.[1];
    if (name && filename !== undefined) files[name] = { filename, contentType: headerText.match(/content-type:\s*([^\r\n]+)/i)?.[1], bytes: content };
    else if (name) fields[name] = content.toString('utf8');
    offset = dataEnd + 2;
  }
  return { fields, files };
}

function run(script, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path.join(root, 'scripts', script), ...args], { env: { ...process.env, ...env } });
    let stdout = ''; let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('close', (code) => code === 0 ? resolve(JSON.parse(stdout)) : reject(new Error(stderr || stdout)));
  });
}

const server = http.createServer((request, response) => {
  response.setHeader('content-type', 'application/json');
  if (request.url === '/v1/models') return response.end(JSON.stringify({ data: [
    { id: 'text-only' },
    { id: 'gpt-image-2', display_name: 'GPT Image 2', sizes: ['1024x1024'], aspect_ratios: ['1:1'], optional: { width: null, height: null } },
    { id: 'gemini-3-pro-image', display_name: 'Gemini 3 Pro Image' },
  ] }));
  if (request.url === '/v1/images/generations' || request.url === '/v1/images/edits') {
    const chunks = [];
    request.on('data', (chunk) => { chunks.push(chunk); });
    return request.on('end', () => {
      const body = Buffer.concat(chunks);
      if (request.url.endsWith('/edits')) {
        const form = parseMultipart(body, request.headers['content-type']);
        assert.equal(form.fields.model, 'gpt-image-2');
        assert.match(form.fields.prompt, /Preserve all content/);
        assert.equal(form.fields.n, '1');
        assert.equal(form.files.image.contentType, 'image/png');
        assert.ok(form.files.image.bytes.equals(Buffer.from(tinyPng, 'base64')));
        requests.push({ path: request.url, form });
        if (form.fields.prompt.includes('Trigger Images Edits fallback')) {
          response.statusCode = 404;
          return response.end(JSON.stringify({ error: { message: 'Images Edits endpoint is not supported' } }));
        }
        if (form.fields.prompt.includes('Trigger high-resolution model unavailable')) {
          response.statusCode = 404;
          return response.end(JSON.stringify({ error: { message: 'model gpt-image-2 is not available on this channel' } }));
        }
      } else {
        const payload = JSON.parse(body.toString('utf8'));
        assert.equal(payload.model, 'gpt-image-2');
        requests.push({ path: request.url, payload });
        if (payload.size && Math.max(...payload.size.split('x').map(Number)) >= 1600) {
          assert.equal(payload.model, 'gpt-image-2', 'high-resolution preserves the requested model ID');
        }
        if (payload.prompt.includes('Trigger high-resolution failure')) {
          response.statusCode = 400;
          return response.end(JSON.stringify({ error: { message: `model ${payload.model} does not support ${payload.size}; high-resolution unavailable` } }));
        }
      }
      response.end(JSON.stringify({ data: [{ b64_json: tinyPng }] }));
    });
  }
  if (request.url === '/v1/chat/completions') {
    let body = '';
    request.on('data', (chunk) => { body += chunk; });
    return request.on('end', () => {
      const payload = JSON.parse(body);
      requests.push(payload);
      const content = payload.messages?.find((message) => message.role === 'user')?.content;
      const hasImage = Array.isArray(content) && content.some((item) => item.type === 'image_url');
      if (hasImage) return response.end(JSON.stringify({ choices: [{ message: { content: `![edited](data:image/png;base64,${tinyPng})` } }] }));
      return response.end(JSON.stringify({ diagnostic: request.headers.authorization }));
    });
  }
  response.statusCode = 404; response.end('{}');
});

(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const output = path.join(temp, 'result.png');
  const input = path.join(temp, 'uploaded image');
  const editedOutput = path.join(temp, 'edited.png');
  fs.writeFileSync(input, Buffer.from(tinyPng, 'base64'));
  try {
    const models = await run('list_image_models.js', ['--base-url', base], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(models.FilteredModelCount, 2);
    const gptModel = models.Models.find((model) => model.Id === 'gpt-image-2');
    const geminiModel = models.Models.find((model) => model.Id === 'gemini-3-pro-image');
    assert.deepEqual(gptModel.AdvertisedSizes, ['1024x1024']);
    assert.deepEqual(gptModel.AdvertisedResolutionTiers.OneK, ['1024x1024']);
    assert.ok(!gptModel.SuggestedSizes.includes('2048x2048'), 'unadvertised 2K is not suggested as a default');
    assert.deepEqual(geminiModel.SuggestedSizes, ['1024x1024', '1536x1024', '1024x1536'], 'Gemini uses the same conservative defaults');
    await assert.rejects(
      run('generate_image.js', ['--prompt', 'test', '--model', 'gpt-image-2', '--szie', '1024x1024', '--dry-run'], {}),
      /Unknown option: --szie/
    );
    await assert.rejects(
      run('generate_image.js', ['--prompt', 'test', '--model', 'gpt-image-2', '--route', 'direct', '--proxy-base-url', base, '--dry-run'], {}),
      /proxy-base-url cannot be used with --route direct/
    );
    await assert.rejects(
      run('list_image_models.js', ['--timeout-sec', 'invalid', '--dry-run'], {}),
      /timeout-sec must be an integer/
    );
    await assert.rejects(
      run('generate_image.js', ['--prompt', 'test', '--model', 'chat-image-model', '--endpoint-mode', 'chat', '--base-url', base], { KEYLINK_IMAGE_API_KEY: 'secret-preview-test-key' }),
      (error) => error.message.includes('<redacted>') && !error.message.includes('secret-preview-test-key')
    );
    const edited = await run('generate_image.js', [
      '--prompt', 'Change only the cell membrane to translucent silver.', '--model', 'gpt-image-2',
      '--input-image-path', input, '--base-url', base, '--output-path', editedOutput,
    ], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(edited.EndpointMode, 'images');
    assert.equal(edited.Operation, 'edit');
    assert.ok(fs.statSync(editedOutput).size > 0);
    const editRequest = requests.find((request) => request.path === '/v1/images/edits');
    assert.ok(editRequest, 'multipart image edit request was received');
    const fallbackStart = requests.length;
    const fallback = await run('generate_image.js', [
      '--prompt', 'Trigger Images Edits fallback: change only the cell membrane.', '--model', 'gpt-image-2',
      '--input-image-path', input, '--size', '1024x1024', '--base-url', base,
      '--output-path', path.join(temp, 'fallback-chat.png'),
    ], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(fallback.EndpointMode, 'chat');
    assert.equal(fallback.FallbackFromEndpoint, `${base}/v1/images/edits`);
    assert.match(fallback.FallbackReason, /HTTP 404/);
    assert.equal(requests[fallbackStart].path, '/v1/images/edits');
    assert.equal(requests[fallbackStart + 1].messages[0].role, 'system');
    assert.match(requests[fallbackStart + 1].messages[0].content, /Preserve all content/);
    assert.equal(requests[fallbackStart + 1].extra_body.imageConfig.aspectRatio, '1:1');
    const explicitChat = await run('generate_image.js', [
      '--prompt', 'Change only the cell membrane to translucent silver.', '--model', 'gpt-image-2', '--endpoint-mode', 'chat',
      '--input-image-path', input, '--base-url', base, '--output-path', path.join(temp, 'edited-chat.png'),
    ], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(explicitChat.EndpointMode, 'chat');
    const chatEditRequest = requests.at(-1);
    assert.match(chatEditRequest.messages[0].content, /Preserve all content/);
    const editContent = chatEditRequest.messages.find((message) => message.role === 'user').content;
    assert.equal(editContent[0].text, 'Change only the cell membrane to translucent silver.');
    assert.match(editContent[1].image_url.url, /^data:image\/png;base64,/);
    const generated = await run('generate_image.js', ['--prompt', 'test', '--model', 'gpt-image-2', '--size', '1024x1024', '--base-url', base, '--output-path', output], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(generated.OutputPath, output);
    assert.equal(generated.NextEditInputPath, output);
    assert.ok(fs.statSync(output).size > 0);
    const highResolution = await run('generate_image.js', [
      '--prompt', 'high-resolution test', '--model', 'gpt-image-2', '--size', '2560x1440', '--base-url', base,
      '--output-path', path.join(temp, 'high-resolution.png'),
    ], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(highResolution.RequestedModel, 'gpt-image-2');
    assert.equal(highResolution.Model, 'gpt-image-2');
    assert.equal(highResolution.Size, '2560x1440');
    const fourK = await run('generate_image.js', [
      '--prompt', '4K high-resolution test', '--model', 'gpt-image-2', '--size', '3840x2160', '--base-url', base,
      '--output-path', path.join(temp, 'four-k.png'),
    ], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(fourK.RequestedModel, 'gpt-image-2');
    assert.equal(fourK.Model, 'gpt-image-2');
    assert.equal(fourK.Size, '3840x2160');
    assert.equal(fourK.ResolutionTier, '4K');
    const fourKEdit = await run('generate_image.js', [
      '--prompt', 'Edit this reference at 4K while preserving the composition.', '--model', 'gpt-image-2',
      '--size', '3840x2160', '--input-image-path', input, '--base-url', base,
      '--output-path', path.join(temp, 'four-k-edit.png'),
    ], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(fourKEdit.Model, 'gpt-image-2');
    assert.equal(fourKEdit.Size, '3840x2160');
    assert.equal(fourKEdit.Operation, 'edit');
    const fourKEditRequest = requests.filter((request) => request.path === '/v1/images/edits').at(-1);
    assert.equal(fourKEditRequest.form.fields.model, 'gpt-image-2');
    assert.equal(fourKEditRequest.form.fields.size, '3840x2160');
    assert.ok(fourKEditRequest.form.files.image, `4K edit file fields: ${JSON.stringify(Object.keys(fourKEditRequest.form.files))}`);
    assert.ok(fourKEditRequest.form.files.image.bytes.equals(Buffer.from(tinyPng, 'base64')));
    await assert.rejects(
      run('generate_image.js', [
        '--prompt', 'Trigger high-resolution model unavailable', '--model', 'gpt-image-2', '--size', '3840x2160',
        '--input-image-path', input, '--base-url', base, '--output-path', path.join(temp, 'four-k-model-failure.png'),
      ], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' }),
      /High-resolution 4K request \(3840x2160\).*selected model\/channel is unavailable.*model gpt-image-2 is not available/
    );
    await assert.rejects(
      run('generate_image.js', [
        '--prompt', 'Trigger high-resolution failure', '--model', 'gpt-image-2', '--size', '2560x1440', '--base-url', base,
        '--output-path', path.join(temp, 'high-resolution-failure.png'),
      ], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' }),
      /High-resolution 2K request \(2560x1440\).*no lower-resolution fallback was attempted/
    );
    console.log('All Keylink cross-platform Node runtime tests passed.');
  } finally {
    server.close();
    fs.rmSync(temp, { recursive: true, force: true });
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
