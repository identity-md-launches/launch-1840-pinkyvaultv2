// Builds the second oracle test: a log-sum filtered on both `from` and `to`.
// Window 84170000–84990000 holds three IMD transfers out of the owner wallet: 0.5 to the IMD
// payee, then 5 and 5 to the vault. Filtered on the vault as well, the answer must be 10 IMD;
// 10.5 would mean the oracle ignored `to`.
import { writeFileSync } from 'node:fs';
import { encodeFunctionData, stringToHex } from 'viem';

const OWNER = '0x89d6584e733ece619c9c34f9a370e1dff5ecf8ef';
const VAULT = '0x3c81384aa1ca064316576a214e2fb30969992772';
const IMD = '0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127';
const INTAKE = '0x1397434cd35e8a9c8ac312a61d3a285eb31dea56';
const ACTION = '0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000';
const PRICE = 500000000000000000n;

const recipe = { kind: 'log-sum', address: IMD, event: 'event Transfer(address indexed from, address indexed to, uint256 value)', sumArg: 'value', abs: false, filter: { from: OWNER, to: VAULT } };
const body = {
  v: 1,
  question: `What is the sum of the value argument of every Transfer(address indexed from, address indexed to, uint256 value) event emitted by the token contract ${IMD} whose from argument is ${OWNER} and whose to argument is ${VAULT} in the window?`,
  chainId: 4663,
  window: { fromBlock: 84170000, toBlock: 84990000 },
  answerType: 'uint256',
  evidence: 'chain',
  definitions: { recipe: `${JSON.stringify(recipe)} - write recipe exactly this, event text included.` },
  panelSize: 5, quorum: 4, toleranceBps: 0, validForSeconds: 86400,
};
const json = JSON.stringify(body);
writeFileSync(new URL('../requests/oracle-test2.body.json', import.meta.url), json);

const erc20 = [{ type: 'function', name: 'approve', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }], stateMutability: 'nonpayable' }];
const intake = [{ type: 'function', name: 'request', stateMutability: 'nonpayable', outputs: [{ type: 'bytes32' }], inputs: [
  { type: 'bytes32' }, { type: 'bytes' }, { type: 'tuple', components: [{ name: 'target', type: 'address' }, { name: 'selector', type: 'bytes4' }] }, { type: 'address' }, { type: 'uint256' },
] }];
writeFileSync(new URL('oracle-test2.calldata.json', import.meta.url), JSON.stringify({
  chainId: 4663, from: OWNER, imd: IMD, intake: INTAKE,
  approve: encodeFunctionData({ abi: erc20, functionName: 'approve', args: [INTAKE, PRICE] }),
  request: encodeFunctionData({ abi: intake, functionName: 'request', args: [ACTION, stringToHex(json), { target: '0x0000000000000000000000000000000000000000', selector: '0x00000000' }, IMD, PRICE] }),
  expectedSumWei: '10000000000000000000',
  expectedLabel: '10000000000000000000 wei (10 IMD). 10.5 IMD would mean the filter on "to" was ignored.',
  body: json,
}, null, 2));
console.log(json.length, 'bytes');
