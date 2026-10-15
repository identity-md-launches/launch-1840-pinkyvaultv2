// Pays for an IMD launch.open with x402 + Permit2. The wallet stays in the browser: this server
// builds the request, asks the page for two typed-data signatures and submits them.
//
//   node pay.mjs            serve the page on http://127.0.0.1:8788/
//   node pay.mjs --dry      quote and read the 402 challenge, print it, sign nothing
import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { randomBytes, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { x402Client } from '@x402/core/client';
import { encodePaymentSignatureHeader } from '@x402/core/http';
import { ExactEvmScheme } from '@x402/evm/exact/client';
import { getTypesForEIP712Domain, sha256, stringToBytes } from 'viem';

const API = 'https://api.imd.fun';
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const INPUT = ROOT + 'requests/launch.input.json';
const PRIVATE = ROOT + 'requests/launch.private.json';

// What a launch costs and where it goes, from the IMD docs. A challenge that says otherwise is not signed.
const EXPECT = {
  from: '0x89d6584e733ece619c9c34f9a370e1dff5ecf8ef',
  network: 'eip155:1',
  asset: '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7',
  amount: '500000000000000000',
  payTo: '0x4e0fa57bde726079356537e2f34d671e9f41adbc',
  permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
};

const state = { stage: 'idle', log: [], pending: null, order: null, result: null, error: null };
let resolvePending = null;
let saved = {};

const say = (line) => { state.log.push(`${new Date().toISOString().slice(11, 19)}  ${line}`); console.log(line); };
const save = async (patch) => { saved = { ...saved, ...patch }; await writeFile(PRIVATE, JSON.stringify(saved, null, 2)); };
const lower = (s) => String(s).toLowerCase();

// canonical JSON: sorted keys, no whitespace
const canon = (v) => v === null ? 'null' : Array.isArray(v) ? `[${v.map(canon).join(',')}]`
  : typeof v === 'object' ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}`
  : JSON.stringify(v);

async function api(method, path, { token, headers = {}, body } = {}) {
  const res = await fetch(API + path, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}), ...headers },
    body,
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: res.status, json, text };
}

// eth_signTypedData_v4 wants the EIP712Domain type spelled out and no bigints. viem's own
// serializeTypedData drops the domain when that type is missing, which signs a different digest.
function walletJson({ domain, types, primaryType, message }) {
  return JSON.stringify(
    { domain, types: { EIP712Domain: getTypesForEIP712Domain({ domain }), ...types }, primaryType, message },
    (_, v) => (typeof v === 'bigint' ? v.toString() : v),
  );
}

function askWallet(kind, typedData) {
  return new Promise((resolve) => {
    state.pending = { id: randomUUID(), kind, typedData: walletJson(typedData) };
    resolvePending = resolve;
  });
}

function checkChallenge(ch) {
  const req = ch?.accepts?.[0];
  const problems = [];
  if (!req) return ['the 402 has no accepts[0]'];
  if (req.scheme !== 'exact') problems.push(`scheme ${req.scheme}`);
  if (req.network !== EXPECT.network) problems.push(`network ${req.network}`);
  if (lower(req.asset) !== EXPECT.asset) problems.push(`asset ${req.asset}`);
  if (String(req.amount) !== EXPECT.amount) problems.push(`amount ${req.amount}`);
  if (lower(req.payTo) !== EXPECT.payTo) problems.push(`payTo ${req.payTo}`);
  if (req.extra?.assetTransferMethod !== 'permit2') problems.push(`transfer method ${req.extra?.assetTransferMethod}`);
  if (ch.quote?.action !== 'launch.open') problems.push(`action ${ch.quote?.action}`);
  return problems;
}

async function quoteAndChallenge() {
  const input = JSON.parse(await readFile(INPUT, 'utf8'));
  const token = randomBytes(32).toString('hex');
  const requestKey = randomUUID();
  await save({ token, requestKey, startedAt: new Date().toISOString() });

  const q = await api('POST', '/requests/quote', { token, body: JSON.stringify({ requestKey, action: 'launch.open', input }) });
  if (q.status !== 201 && q.status !== 200) throw new Error(`quote refused (${q.status}): ${q.text.slice(0, 600)}`);
  const order = q.json.order;
  await save({ orderId: order.id, expiresAt: order.quote.expiresAt });
  state.order = { id: order.id, expiresAt: order.quote.expiresAt, input };
  say(`quote ${order.id}, valid until ${new Date(order.quote.expiresAt * 1000).toISOString().slice(11, 19)} UTC`);

  const c = await api('POST', `/requests/${order.id}/submit`, { token });
  if (c.status !== 402) throw new Error(`expected a 402 challenge, got ${c.status}: ${c.text.slice(0, 600)}`);
  const problems = checkChallenge(c.json);
  if (problems.length) throw new Error(`the challenge is not what a launch should cost — not signing: ${problems.join('; ')}`);
  say('challenge matches: 0.5 IMD on Ethereum to the IMD payee, Permit2');
  return { token, order, ch: c.json };
}

async function run(account) {
  if (lower(account) !== EXPECT.from) throw new Error(`connected ${account}, expected ${EXPECT.from}`);
  state.stage = 'quoting';
  const { token, order, ch } = await quoteAndChallenge();
  const req = ch.accepts[0];

  state.stage = 'signing';
  const signer = { address: account, signTypedData: (td) => askWallet('payment', td) };
  // IMD is not one of the client's default assets: allow exactly this token, capped at the launch price.
  const client = x402Client.fromConfig({
    schemes: [{ network: req.network, client: new ExactEvmScheme(signer) }],
    spendControls: { allowedAssets: [{ network: EXPECT.network, asset: EXPECT.asset, maxAmountPerPayment: EXPECT.amount }] },
  });
  say('waiting for signature 1 of 2: the Permit2 payment');
  const { extensions, ...generated } = await client.createPaymentPayload({ x402Version: 2, resource: ch.resource, accepts: [req] });
  const payment = JSON.parse(JSON.stringify({ ...generated, accepted: req }));

  const q = ch.quote;
  say('waiting for signature 2 of 2: approval of this quote');
  const quoteSignature = await askWallet('approval', {
    domain: { name: 'IdentityMD Paid Action', version: '1', chainId: Number(q.payment.network.slice(7)) },
    primaryType: 'QuoteApproval',
    types: { QuoteApproval: [
      { name: 'resource', type: 'string' },
      { name: 'requesterScopeHash', type: 'bytes32' },
      { name: 'quoteId', type: 'string' },
      { name: 'quoteHash', type: 'bytes32' },
      { name: 'paymentHash', type: 'bytes32' },
      { name: 'action', type: 'string' },
      { name: 'asset', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'payTo', type: 'address' },
      { name: 'expiresAt', type: 'uint256' },
    ] },
    message: {
      resource: ch.resourceUrl,
      requesterScopeHash: `0x${ch.requesterScopeHash}`,
      quoteId: q.id,
      quoteHash: `0x${q.quoteHash}`,
      paymentHash: sha256(stringToBytes(canon(payment))),
      action: q.action,
      asset: q.payment.asset,
      amount: BigInt(q.payment.amount),
      payTo: q.payment.payTo,
      expiresAt: BigInt(q.expiresAt),
    },
  });

  const header = encodePaymentSignatureHeader(payment);
  const body = JSON.stringify({ quoteSignature });
  await save({ submit: { header, body } });

  state.stage = 'submitting';
  let sent;
  for (let attempt = 1; ; attempt++) {
    try {
      // The same bytes every time: a retry reuses the order and never charges twice.
      sent = await api('POST', `/requests/${order.id}/submit`, { token, headers: { 'PAYMENT-SIGNATURE': header }, body });
      break;
    } catch (e) {
      if (attempt === 4) throw new Error(`submit did not get through: ${e.message}. The signed request is saved; restart with the same order.`);
      say(`submit attempt ${attempt} failed (${e.message}) — sending the same bytes again`);
      await new Promise((ok) => setTimeout(ok, 3000));
    }
  }
  await save({ submitted: { status: sent.status, body: sent.json ?? sent.text.slice(0, 2000) } });
  say(`submitted: HTTP ${sent.status} ${sent.text.slice(0, 300)}`);
  if (sent.status !== 200 && sent.status !== 202) throw new Error(`submit refused (${sent.status}): ${sent.text.slice(0, 600)}`);

  state.stage = 'settling';
  for (let i = 0; i < 90; i++) {
    const r = await api('GET', `/requests/${order.id}`, { token });
    const status = r.json?.status;
    if (status && status !== state.result?.status) say(`order status: ${status}`);
    state.result = { status, payment: r.json?.payment, admission: r.json?.admission };
    if (status === 'admitted' || status === 'payment_failed' || status === 'expired') {
      await save({ final: r.json });
      state.stage = status === 'admitted' ? 'done' : 'failed';
      return;
    }
    await new Promise((ok) => setTimeout(ok, 4000));
  }
  state.stage = 'unknown';
  say('still not settled after six minutes — the order id and token are saved; read it later');
}

if (process.argv.includes('--dry')) {
  const { ch } = await quoteAndChallenge();
  console.log(JSON.stringify({ accepts: ch.accepts, resource: ch.resource, resourceUrl: ch.resourceUrl, quoteAction: ch.quote.action, quoteExpiresAt: ch.quote.expiresAt }, null, 2));
  process.exit(0);
}

const json = (res, code, obj) => res.writeHead(code, { 'Content-Type': 'application/json' }).end(JSON.stringify(obj));
const readBody = (req) => new Promise((ok) => { let s = ''; req.on('data', (d) => { s += d; }); req.on('end', () => ok(s ? JSON.parse(s) : {})); });

createServer(async (req, res) => {
  const path = new URL(req.url, 'http://x').pathname;
  try {
    if (req.method === 'GET' && path === '/') {
      return res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }).end(await readFile(new URL('./pay.html', import.meta.url)));
    }
    if (req.method === 'GET' && path === '/api/config') {
      return json(res, 200, { expect: EXPECT, input: JSON.parse(await readFile(INPUT, 'utf8')) });
    }
    if (req.method === 'GET' && path === '/api/state') return json(res, 200, state);
    if (req.method === 'POST' && path === '/api/start') {
      if (!['idle', 'failed'].includes(state.stage)) return json(res, 409, { error: `already ${state.stage}` });
      const { account } = await readBody(req);
      Object.assign(state, { stage: 'starting', log: [], pending: null, result: null, error: null });
      run(account).catch((e) => { state.stage = 'failed'; state.error = e.message; state.pending = null; say(`STOPPED: ${e.message}`); });
      return json(res, 200, { ok: true });
    }
    if (req.method === 'POST' && path === '/api/signed') {
      const { id, signature } = await readBody(req);
      if (!state.pending || state.pending.id !== id || !/^0x[0-9a-fA-F]{130}$/.test(signature ?? '')) return json(res, 400, { error: 'no such pending signature' });
      const done = resolvePending;
      state.pending = null;
      resolvePending = null;
      done(signature);
      return json(res, 200, { ok: true });
    }
    res.writeHead(404).end('not found');
  } catch (e) {
    json(res, 500, { error: e.message });
  }
}).listen(8788, '127.0.0.1', () => console.log('http://127.0.0.1:8788/'));
