import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadSigmaAuth } from './auth.mjs';
import { makeClient } from './sigma-rest.mjs';

const BASE = 'https://api.sigmacomputing.com';
const KEYS = [
  'SIGMA_BASE_URL', 'SIGMA_API_TOKEN', 'SIGMA_TOKEN_MINTED_AT',
  'SIGMA_AUTH_METHOD', 'SIGMA_CLIENT_ID', 'SIGMA_CLIENT_SECRET',
  'SIGMA_TOKEN_PROVIDER', 'SIGMA_PYTHON', 'SIGMA_AUTH_MODE', 'FAKE_SIGMA_BASE', 'FAKE_SIGMA_TOKEN',
];

function withCleanEnv(fn) {
  const saved = Object.fromEntries(KEYS.map((key) => [key, process.env[key]]));
  for (const key of KEYS) delete process.env[key];
  try {
    return fn();
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

test('unknown-age caller token is preserved without invoking the provider', () => {
  withCleanEnv(() => {
    process.env.SIGMA_BASE_URL = BASE;
    process.env.SIGMA_API_TOKEN = 'caller-token';
    const auth = loadSigmaAuth('/unused', {
      refresh: () => assert.fail('provider should not run for an age-unknown caller token'),
    });
    assert.equal(auth.token, 'caller-token');
  });
});

test('known-stale browser token refreshes without client credentials', () => {
  withCleanEnv(() => {
    process.env.SIGMA_BASE_URL = BASE;
    process.env.SIGMA_API_TOKEN = 'stale-token';
    process.env.SIGMA_TOKEN_MINTED_AT = '2026-10-05T19:00:00Z';
    const auth = loadSigmaAuth('/work', {
      now: Date.parse('2026-10-05T20:00:00Z'),
      refresh: () => ({
        base: BASE,
        token: 'browser-token',
        mintedAt: '2026-10-05T20:00:00Z',
        authMethod: 'browser',
      }),
    });
    assert.equal(auth.token, 'browser-token');
    assert.equal(auth.authMethod, 'browser');
  });
});

test('CLI token never refreshes proactively', () => {
  withCleanEnv(() => {
    process.env.SIGMA_BASE_URL = BASE;
    process.env.SIGMA_API_TOKEN = 'cli-token';
    process.env.SIGMA_TOKEN_MINTED_AT = '2000-01-01T00:00:00Z';
    process.env.SIGMA_AUTH_METHOD = 'sigma-cli';
    const auth = loadSigmaAuth('/unused', {
      refresh: () => assert.fail('provider should not run for a CLI token'),
    });
    assert.equal(auth.token, 'cli-token');
    assert.equal(auth.mintedAt, undefined);
  });
});

test('401 refreshes once regardless of SIGMA_CLIENT_ID', async () => {
  await withCleanEnv(async () => {
    const authorizations = [];
    const responses = [
      { status: 401, ok: false, text: async () => 'unauthorized' },
      { status: 200, ok: true, text: async () => '{"ok":true}' },
    ];
    let refreshes = 0;
    const client = makeClient('/work', {
      loadAuth: () => ({ base: BASE, token: 'caller-token' }),
      refreshAuth: () => {
        refreshes += 1;
        return { base: BASE, token: 'browser-token', authMethod: 'browser' };
      },
      fetchImpl: async (_url, options) => {
        authorizations.push(options.headers.Authorization);
        return responses.shift();
      },
    });

    const result = await client.api('GET', '/v2/whoami');
    assert.equal(result.ok, true);
    assert.equal(refreshes, 1);
    assert.deepEqual(authorizations, ['Bearer caller-token', 'Bearer browser-token']);
  });
});

// ---- CLI-only user: SIGMA_BASE_URL unset, the provider supplies the host ----
const CLI_BASE = 'https://aws-api.sigmacomputing.com';
const FAKE_JWT = 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl';

// A stand-in provider: writes auth.json the way get_token.py --workdir does.
function fakeProvider(dir, base) {
  const path = join(dir, 'provider.py');
  writeFileSync(path, [
    'import json, os, sys',
    "wd = sys.argv[sys.argv.index('--workdir') + 1]",
    'os.makedirs(wd, exist_ok=True)',
    "json.dump({'SIGMA_API_TOKEN': " + JSON.stringify(FAKE_JWT) + ", 'SIGMA_BASE_URL': " + JSON.stringify(base) + ",",
    "           'SIGMA_AUTH_METHOD': 'sigma-cli'},",
    "          open(os.path.join(wd, 'auth.json'), 'w'))",
    '',
  ].join('\n'));
  return path;
}

test('CLI-only: a missing SIGMA_BASE_URL is derived from the provider result', () => {
  withCleanEnv(() => {
    const dir = mkdtempSync(join(tmpdir(), 'sigma-auth-'));
    process.env.SIGMA_TOKEN_PROVIDER = fakeProvider(dir, CLI_BASE);
    const auth = loadSigmaAuth(join(dir, 'work'));
    assert.equal(auth.base, CLI_BASE);
    assert.equal(auth.token, FAKE_JWT);
    assert.equal(auth.authMethod, 'sigma-cli');
    assert.equal(auth.mintedAt, undefined);
    assert.equal(process.env.SIGMA_BASE_URL, CLI_BASE);
  });
});

test('CLI-only: the derived host is validated before the client sends anything', () => {
  withCleanEnv(() => {
    const dir = mkdtempSync(join(tmpdir(), 'sigma-auth-'));
    process.env.SIGMA_TOKEN_PROVIDER = fakeProvider(dir, 'https://api.evil.test');
    let sent = 0;
    assert.throws(
      () => makeClient(join(dir, 'work'), { fetchImpl: async () => { sent += 1; } }),
      /untrusted base URL/,
    );
    assert.equal(sent, 0);
    assert.equal(process.env.SIGMA_BASE_URL, undefined);
    assert.equal(process.env.SIGMA_API_TOKEN, undefined);
  });
});

test('CLI-only: a derived non-https host is refused', () => {
  withCleanEnv(() => {
    const dir = mkdtempSync(join(tmpdir(), 'sigma-auth-'));
    process.env.SIGMA_TOKEN_PROVIDER = fakeProvider(dir, 'http://aws-api.sigmacomputing.com');
    assert.throws(() => loadSigmaAuth(join(dir, 'work')), /untrusted base URL/);
    assert.equal(process.env.SIGMA_BASE_URL, undefined);
  });
});

test('CLI-only: the client built from a derived base reaches that host', async () => {
  await withCleanEnv(async () => {
    const dir = mkdtempSync(join(tmpdir(), 'sigma-auth-'));
    process.env.SIGMA_TOKEN_PROVIDER = fakeProvider(dir, CLI_BASE);
    const urls = [];
    const client = makeClient(join(dir, 'work'), {
      fetchImpl: async (url, options) => {
        urls.push([url, options.headers.Authorization]);
        return { status: 200, ok: true, text: async () => '{"ok":true}' };
      },
    });
    await client.api('GET', '/v2/whoami');
    assert.deepEqual(urls, [[`${CLI_BASE}/v2/whoami`, `Bearer ${FAKE_JWT}`]]);
  });
});

test('explicit SIGMA_BASE_URL wins over the provider-derived one', () => {
  withCleanEnv(() => {
    const dir = mkdtempSync(join(tmpdir(), 'sigma-auth-'));
    process.env.SIGMA_BASE_URL = BASE;
    process.env.SIGMA_TOKEN_PROVIDER = fakeProvider(dir, CLI_BASE);
    const auth = loadSigmaAuth(join(dir, 'work'));
    assert.equal(auth.base, BASE);
    assert.equal(process.env.SIGMA_BASE_URL, BASE);
  });
});

test('a caller token with no base URL is not silently replaced by the CLI identity', () => {
  withCleanEnv(() => {
    process.env.SIGMA_API_TOKEN = 'caller-token';
    assert.throws(
      () => loadSigmaAuth('/unused', { refresh: () => assert.fail('provider must not run') }),
      /SIGMA_BASE_URL/,
    );
  });
});

test('a real fake CLI through the real provider reaches the derived host', async () => {
  await withCleanEnv(async () => {
    const provider = join(import.meta.dirname, '../../../scripts/get_token.py');
    const { existsSync } = await import('node:fs');
    if (!existsSync(provider)) return; // provider not vendored next to this template
    const dir = mkdtempSync(join(tmpdir(), 'sigma-auth-'));
    const bindir = join(dir, 'bin');
    mkdirSync(bindir);
    writeFileSync(join(bindir, 'sigma'), [
      '#!/bin/bash',
      'if [ "$1 $2" = "auth --help" ]; then echo "Commands: login token status"; exit 0; fi',
      'if [ "$1 $2" = "auth status" ]; then',
      '  { echo "Profile:   example-profile"; echo "Base URL:  ${FAKE_SIGMA_BASE}"; echo "Auth:      OK (token acquired)"; } >&2',
      '  exit 0',
      'fi',
      `if [ "$1 $2" = "auth token" ]; then printf '%s\\n' "\${FAKE_SIGMA_TOKEN}"; exit 0; fi`,
      'exit 3',
      '',
    ].join('\n'));
    chmodSync(join(bindir, 'sigma'), 0o755);
    // The real provider, minus its network /v2/whoami verification.
    const wrapper = join(dir, 'provider.py');
    writeFileSync(wrapper, [
      'import importlib.util, sys',
      `spec = importlib.util.spec_from_file_location('gt', ${JSON.stringify(provider)})`,
      'gt = importlib.util.module_from_spec(spec); spec.loader.exec_module(gt)',
      'gt._verify_token = lambda r: r',
      'sys.exit(gt.main(sys.argv[1:]))',
      '',
    ].join('\n'));
    const savedHome = process.env.HOME;
    const savedPath = process.env.PATH;
    process.env.HOME = dir;
    process.env.PATH = `${bindir}:${process.env.PATH}`;
    process.env.SIGMA_TOKEN_PROVIDER = wrapper;
    process.env.SIGMA_AUTH_MODE = 'sigma-cli';
    process.env.FAKE_SIGMA_BASE = CLI_BASE;
    process.env.FAKE_SIGMA_TOKEN = FAKE_JWT;
    try {
      const urls = [];
      const client = makeClient(join(dir, 'work'), {
        fetchImpl: async (url, options) => {
          urls.push([url, options.headers.Authorization]);
          return { status: 200, ok: true, text: async () => '{}' };
        },
      });
      await client.api('GET', '/v2/whoami');
      assert.deepEqual(urls, [[`${CLI_BASE}/v2/whoami`, `Bearer ${FAKE_JWT}`]]);
    } finally {
      process.env.HOME = savedHome;
      process.env.PATH = savedPath;
    }
  });
});
