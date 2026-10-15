// Offline check of the two signatures pay.mjs asks for, with a throwaway key. Sends nothing.
// A wallet parses the JSON, drops EIP712Domain from the struct types, hashes and signs; the
// result must verify against the typed data the x402 client and the IMD docs describe.
import { x402Client } from '@x402/core/client';
import { ExactEvmScheme } from '@x402/evm/exact/client';
import { getTypesForEIP712Domain, hashTypedData, verifyTypedData } from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';

const walletJson = ({ domain, types, primaryType, message }) => JSON.stringify(
  { domain, types: { EIP712Domain: getTypesForEIP712Domain({ domain }), ...types }, primaryType, message },
  (_, v) => (typeof v === 'bigint' ? v.toString() : v),
);

const acct = privateKeyToAccount(generatePrivateKey());
let failed = false;

async function check(label, td) {
  const p = JSON.parse(walletJson(td));
  const { EIP712Domain, ...types } = p.types;
  const asWallet = { domain: p.domain, types, primaryType: p.primaryType, message: p.message };
  const signature = await acct.signTypedData(asWallet);
  const sameDigest = hashTypedData(asWallet) === hashTypedData(td);
  const verifies = await verifyTypedData({ address: acct.address, ...td, signature });
  if (!sameDigest || !verifies) failed = true;
  console.log(`${label} | domain fields: ${EIP712Domain.map((t) => t.name).join(',')} | same digest: ${sameDigest} | verifies: ${verifies}`);
  return signature;
}

const req = {
  scheme: 'exact', network: 'eip155:1', asset: '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7', amount: '500000000000000000',
  payTo: '0x4e0fa57bde726079356537e2f34d671e9f41adbc', maxTimeoutSeconds: 300, extra: { assetTransferMethod: 'permit2' },
};
const client = x402Client.fromConfig({
  schemes: [{ network: 'eip155:1', client: new ExactEvmScheme({ address: acct.address, signTypedData: (td) => check('permit2 ', td) }) }],
  spendControls: { allowedAssets: [{ network: 'eip155:1', asset: req.asset, maxAmountPerPayment: req.amount }] },
});
await client.createPaymentPayload({
  x402Version: 2, resource: { url: 'https://api.imd.fun/requests/TEST', description: 'x', mimeType: 'application/json' }, accepts: [req],
});

await check('approval', {
  domain: { name: 'IdentityMD Paid Action', version: '1', chainId: 1 },
  primaryType: 'QuoteApproval',
  types: { QuoteApproval: [
    { name: 'resource', type: 'string' }, { name: 'requesterScopeHash', type: 'bytes32' }, { name: 'quoteId', type: 'string' },
    { name: 'quoteHash', type: 'bytes32' }, { name: 'paymentHash', type: 'bytes32' }, { name: 'action', type: 'string' },
    { name: 'asset', type: 'address' }, { name: 'amount', type: 'uint256' }, { name: 'payTo', type: 'address' },
    { name: 'expiresAt', type: 'uint256' },
  ] },
  message: {
    resource: 'https://api.imd.fun/requests/TEST', requesterScopeHash: `0x${'11'.repeat(32)}`, quoteId: 'TEST',
    quoteHash: `0x${'22'.repeat(32)}`, paymentHash: `0x${'33'.repeat(32)}`, action: 'launch.open', asset: req.asset,
    amount: 500000000000000000n, payTo: req.payTo, expiresAt: 1791551609n,
  },
});

process.exit(failed ? 1 : 0);
