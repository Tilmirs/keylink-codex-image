const { DatabaseSync } = require('node:sqlite');

const [databasePath, apiKey] = process.argv.slice(2);
if (!databasePath || !apiKey) throw new Error('database path and test key required');

const db = new DatabaseSync(databasePath);
try {
  db.exec(`
    CREATE TABLE providers (
      id TEXT NOT NULL,
      app_type TEXT NOT NULL,
      name TEXT NOT NULL,
      settings_config TEXT NOT NULL,
      is_current BOOLEAN NOT NULL DEFAULT 0,
      PRIMARY KEY (id, app_type)
    )
  `);
  const insert = db.prepare(
    'INSERT INTO providers (id, app_type, name, settings_config, is_current) VALUES (?, ?, ?, ?, ?)'
  );
  const keylinkConfig = 'model_provider = "custom"\n[model_providers.custom]\nbase_url = "https://keylinkclub.com"\n';
  insert.run('old-provider', 'codex', 'Old provider', JSON.stringify({ auth: { OPENAI_API_KEY: 'wrong-key' }, config: keylinkConfig }), 0);
  insert.run('current-provider', 'codex', 'Current provider', JSON.stringify({ auth: { OPENAI_API_KEY: apiKey }, config: keylinkConfig }), 1);
  insert.run('other-app', 'claude', 'Other app', JSON.stringify({ auth: { OPENAI_API_KEY: 'wrong-app-key' }, config: keylinkConfig }), 1);
} finally {
  db.close();
}
