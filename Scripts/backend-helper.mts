/**
 * =============================================================================
 *                  SP BOUCHER | SOFTWARE & RESEARCH
 *             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
 * =============================================================================
 *
 * Project          : SP Drive pour macOS
 * File             : Scripts/backend-helper.mts
 * Description      : Test-only helper for the local SP Drive backend: a
 *                    software WebAuthn authenticator with a persisted ES256 key
 *                    registers the test account, opens device sessions and
 *                    approves device-link codes over the real HTTP API. The
 *                    server-side verification is the production code path.
 *                    Never used against production.
 * Module           : Scripts
 * Repository       : https://git.spboucher.ai/sp-drive-macos
 * Created          : 2026-11-18
 * Last Modified    : 2026-11-18
 *
 * Author           : Simon-Pierre Boucher
 * Position         : Professor of Finance
 * Institution      : Université du Québec en Outaouais (UQO)
 * Organization     : SP Boucher
 * Website          : https://spboucher.ai
 * Git              : https://git.spboucher.ai
 *
 * Preferred Contact: support@spboucher.ai
 * Development      : dev@spboucher.ai
 * Support          : support@spboucher.ai
 * Security/Admin   : admin@spboucher.ai
 *
 * Copyright (c) 2026
 * Simon-Pierre Boucher
 * All rights reserved where applicable. This file is governed by the
 * applicable project license, copyright notices and relevant law.
 * Existing third-party rights and notices remain unaffected.
 *
 * License          : None specified (no license file in this repository)
 *
 * Do not embed credentials, private keys, access tokens,
 * certificates or confidential personal information.
 *
 * =============================================================================
 * END OF SP BOUCHER SOURCE HEADER
 * =============================================================================
 */

import { createHash, createPrivateKey, createSign, generateKeyPairSync, randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

const BASE = process.env.SPDRIVE_BASE!, ORIGIN = process.env.SPD_ORIGIN!, RP = process.env.SPD_RP_ID!, STATE = process.env.SPDRIVE_STATE!;
const b64u = (b: Buffer | Uint8Array) => Buffer.from(b).toString('base64url');
function cbor(v: unknown): Buffer {
  const head = (major: number, n: number) => n < 24 ? Buffer.from([(major << 5) | n]) : n < 256 ? Buffer.from([(major << 5) | 24, n]) : Buffer.from([(major << 5) | 25, n >> 8, n & 255]);
  if (typeof v === 'number') return v >= 0 ? head(0, v) : head(1, -1 - v);
  if (Buffer.isBuffer(v)) return Buffer.concat([head(2, v.length), v]);
  if (typeof v === 'string') { const b = Buffer.from(v); return Buffer.concat([head(3, b.length), b]); }
  if (v instanceof Map) return Buffer.concat([head(5, v.size), ...[...v].flatMap(([k, x]) => [cbor(k), cbor(x)])]);
  throw new Error('cbor: unsupported');
}
interface Cred { id: string; jwk: any; userHandle: string; counter: number }
const file = (email: string) => `${STATE}/passkey-${email.replace(/[^a-z0-9]/gi, '_')}.json`;
const load = (email: string): Cred => JSON.parse(readFileSync(file(email), 'utf8'));
const save = (email: string, c: Cred) => writeFileSync(file(email), JSON.stringify(c), { mode: 0o600 });
const authData = (flags: number, counter: number, attested?: Buffer) => { const c = Buffer.alloc(4); c.writeUInt32BE(counter); return Buffer.concat([createHash('sha256').update(RP).digest(), Buffer.from([flags]), c, ...(attested ? [attested] : [])]); };

function assertion(email: string, challenge: string) {
  const c = load(email); c.counter++; save(email, c);
  const ad = authData(0x05, c.counter);
  const clientDataJSON = Buffer.from(JSON.stringify({ type: 'webauthn.get', challenge, origin: ORIGIN, crossOrigin: false }));
  const signature = createSign('sha256').update(Buffer.concat([ad, createHash('sha256').update(clientDataJSON).digest()])).sign(createPrivateKey({ key: c.jwk, format: 'jwk' }));
  return { id: c.id, rawId: c.id, type: 'public-key', clientExtensionResults: {}, authenticatorAttachment: 'platform',
    response: { clientDataJSON: b64u(clientDataJSON), authenticatorData: b64u(ad), signature: b64u(signature), userHandle: c.userHandle } };
}
let cookie = '';
async function call(method: string, path: string, body?: unknown, auth?: string) {
  const r = await fetch(`${BASE}/api/v1${path}`, { method, headers: { 'content-type': 'application/json', 'x-spd-csrf': '1', origin: ORIGIN, ...(cookie ? { cookie } : {}), ...(auth ? { authorization: `Bearer ${auth}` } : {}) }, body: method === 'GET' ? undefined : JSON.stringify(body ?? {}) });
  const set = r.headers.getSetCookie?.() ?? [];
  for (const s of set) { const kv = s.split(';')[0]!; if (kv.startsWith('spd=')) cookie = kv; }
  const j: any = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${method} ${path}: ${r.status} ${JSON.stringify(j)}`);
  return j;
}
const [cmd, email, arg] = process.argv.slice(2);
if (cmd === 'register') {
  const o = await call('POST', '/auth/register/options', { invite: arg, displayName: 'Testeur' });
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const jwk = publicKey.export({ format: 'jwk' });
  const id = randomBytes(32);
  const cose = cbor(new Map<number, unknown>([[1, 2], [3, -7], [-1, 1], [-2, Buffer.from(jwk.x!, 'base64url')], [-3, Buffer.from(jwk.y!, 'base64url')]]));
  const len = Buffer.alloc(2); len.writeUInt16BE(id.length);
  const ad = authData(0x45, 0, Buffer.concat([Buffer.alloc(16), len, id, cose]));
  save(email!, { id: b64u(id), jwk: privateKey.export({ format: 'jwk' }), userHandle: o.options.user.id, counter: 0 });
  const clientDataJSON = Buffer.from(JSON.stringify({ type: 'webauthn.create', challenge: o.options.challenge, origin: ORIGIN, crossOrigin: false }));
  await call('POST', '/auth/register/verify', { invite: arg, challengeId: o.challengeId, label: 'Clé de test', response: { id: b64u(id), rawId: b64u(id), type: 'public-key', clientExtensionResults: {}, authenticatorAttachment: 'platform',
    response: { clientDataJSON: b64u(clientDataJSON), attestationObject: b64u(cbor(new Map<string, unknown>([['fmt', 'none'], ['attStmt', new Map()], ['authData', ad]]))), transports: ['internal'] } } });
} else if (cmd === 'token') {
  if (!existsSync(file(email!))) throw new Error('account not registered');
  const o = await call('POST', '/auth/login/options');
  const r = await call('POST', '/auth/login/verify', { challengeId: o.challengeId, response: assertion(email!, o.options.challenge), client: { kind: 'native', name: arg ?? 'Mac de test' } });
  process.stdout.write(`${r.token}\n`);
} else if (cmd === 'approve') {
  const o = await call('POST', '/auth/login/options');
  await call('POST', '/auth/login/verify', { challengeId: o.challengeId, response: assertion(email!, o.options.challenge) }); // browser session, passkey just used
  await call('POST', '/auth/device/decide', { code: arg, approve: true });
  process.stdout.write('approved\n');
} else { console.error('usage: register|token|approve'); process.exit(2); }
