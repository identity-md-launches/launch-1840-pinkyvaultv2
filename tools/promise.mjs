// Prints a promise as the vault stores it.   node promise.mjs [id]
import { createPublicClient, formatUnits, http, parseAbi } from 'viem';

const VAULT = '0x3c81384aa1ca064316576a214e2fb30969992772';
const IMD = '0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127';
const STATUS = ['Active', 'Closed', 'Asked', 'Kept', 'Broken', 'Refunded'];
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36';

const client = createPublicClient({
  transport: http('https://rpc.mainnet.chain.robinhood.com', { batch: true, fetchOptions: { headers: { 'User-Agent': UA } } }),
});
const vault = parseAbi([
  'function count() view returns (uint256)',
  'function promises(uint256) view returns (address maker, address token, uint256 maxOut, uint256 bond, uint64 startBlock, uint64 endBlock, uint64 endTime, uint64 closedAt, uint64 askedAt, uint8 attempts, uint8 status, bool paid, address asker, address intake, bytes32 requestId, uint256 observedOut)',
  'function bodyOf(uint256) view returns (string)',
]);
const erc20 = parseAbi(['function balanceOf(address) view returns (uint256)']);

const count = await client.readContract({ address: VAULT, abi: vault, functionName: 'count' });
const id = BigInt(process.argv[2] ?? count);
if (count === 0n) { console.log('no promises yet'); process.exit(0); }

const [p, block, held] = await Promise.all([
  client.readContract({ address: VAULT, abi: vault, functionName: 'promises', args: [id] }),
  client.getBlock(),
  client.readContract({ address: IMD, abi: erc20, functionName: 'balanceOf', args: [VAULT] }),
]);
const [maker, token, maxOut, bond, startBlock, endBlock, endTime, closedAt, askedAt, attempts, status, paid, asker, , requestId, observedOut] = p;
const left = Number(endTime) - Number(block.timestamp);

console.log(`promise #${id} of ${count}: ${STATUS[status]}${paid ? ' (paid)' : ''}`);
console.log(`  maker     ${maker}`);
console.log(`  token     ${token}`);
console.log(`  maxOut    ${maxOut}`);
console.log(`  bond      ${formatUnits(bond, 18)} IMD (vault holds ${formatUnits(held, 18)})`);
console.log(`  blocks    ${startBlock} .. ${endBlock || '(not closed)'}; head ${block.number}`);
console.log(`  deadline  ${new Date(Number(endTime) * 1000).toISOString()} (${left > 0 ? `${left} s left` : `${-left} s ago`})`);
if (closedAt) console.log(`  closed    ${new Date(Number(closedAt) * 1000).toISOString()}`);
if (askedAt) console.log(`  asked     ${new Date(Number(askedAt) * 1000).toISOString()}, attempt ${attempts}, by ${asker}`);
if (askedAt) console.log(`  request   ${requestId}`);
if (status >= 3 && status <= 4) console.log(`  observed  ${observedOut}`);
