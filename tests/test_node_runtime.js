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
  ] }));
  if (request.url === '/v1/images/generations') {
    let body = '';
    request.on('data', (chunk) => { body += chunk; });
    return request.on('end', () => {
      assert.equal(JSON.parse(body).model, 'gpt-image-2');
      response.end(JSON.stringify({ data: [{ b64_json: tinyPng }] }));
    });
  }
  if (request.url === '/v1/chat/completions') return response.end(JSON.stringify({ diagnostic: request.headers.authorization }));
  response.statusCode = 404; response.end('{}');
});

(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const output = path.join(temp, 'result.png');
  try {
    const models = await run('list_image_models.js', ['--base-url', base], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(models.FilteredModelCount, 1);
    assert.deepEqual(models.Models[0].AdvertisedSizes, ['1024x1024']);
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
    const generated = await run('generate_image.js', ['--prompt', 'test', '--model', 'gpt-image-2', '--size', '1024x1024', '--base-url', base, '--output-path', output], { KEYLINK_IMAGE_API_KEY: 'fake-test-key' });
    assert.equal(generated.OutputPath, output);
    assert.ok(fs.statSync(output).size > 0);
    console.log('All Keylink cross-platform Node runtime tests passed.');
  } finally {
    server.close();
    fs.rmSync(temp, { recursive: true, force: true });
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
