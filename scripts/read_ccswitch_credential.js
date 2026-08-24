// Internal helper. The parent PowerShell script captures stdout; do not run this directly.
const { DatabaseSync } = require('node:sqlite');

const databasePath = process.argv[2];
if (!databasePath) throw new Error('database path required');

const db = new DatabaseSync(databasePath, { readOnly: true });
try {
  const row = db.prepare(
    "SELECT settings_config FROM providers WHERE app_type = 'codex' AND is_current = 1 LIMIT 1"
  ).get();
  if (!row) throw new Error('no current Codex provider in CCSwitch');

  let settings;
  try {
    settings = JSON.parse(row.settings_config);
  } catch {
    throw new Error('current CCSwitch provider settings are not valid JSON');
  }

  const config = String(settings?.config || '');
  const baseUrlMatch = config.match(/^\s*base_url\s*=\s*["']([^"']+)["']/im);
  let providerHost;
  try {
    providerHost = baseUrlMatch ? new URL(baseUrlMatch[1]).hostname.toLowerCase() : '';
  } catch {
    providerHost = '';
  }
  if (providerHost !== 'keylinkclub.com' && !providerHost.endsWith('.keylinkclub.com')) {
    throw new Error('current CCSwitch Codex provider is not configured for keylinkclub.com');
  }

  const key = settings?.auth?.OPENAI_API_KEY;
  if (typeof key !== 'string' || key.trim().length === 0) {
    throw new Error('current CCSwitch Codex provider has no OPENAI_API_KEY');
  }

  // Encode the value so accidental command tracing does not display it as plain text.
  process.stdout.write(Buffer.from(key.trim(), 'utf8').toString('base64'));
} finally {
  db.close();
}
