// IMD launch #1166. With `vault` empty the page shows preview data.
export const config = {
  chainId: 4663,
  chainName: 'Robinhood Chain',
  rpc: 'https://rpc.mainnet.chain.robinhood.com',
  explorer: 'https://robinhoodchain.blockscout.com',
  imd: '0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127',
  vault: '0x3c81384aa1ca064316576a214e2fb30969992772',
  staking: '0x17fb2067652bcf4803e937cf323a248ff6b7cba3',
  token: '0xb125c461c00863aacad4cc99311d2f23d4342a6f',
  // Where the vault buys the oracle's answer, to show what a question costs before anyone signs.
  intake: '0x1397434cd35e8a9c8ac312a61d3a285eb31dea56',
  oracleAction: '0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000',
  // Opens Uniswap on Robinhood Chain with ETH → PINKY filled in.
  buy: 'https://app.uniswap.org/swap?chain=robinhood&inputCurrency=NATIVE&outputCurrency=0xb125c461c00863aacad4cc99311d2f23d4342a6f',
  // The same for IMD, which every bond is paid in.
  buyImd: 'https://app.uniswap.org/swap?chain=robinhood&inputCurrency=NATIVE&outputCurrency=0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127',
  verified: 'https://repo.sourcify.dev/4663/0xb125c461c00863aacad4cc99311d2f23d4342a6f',
  github: 'https://github.com/hexysdev/pinky',
  // The footer shows this link only when it is set.
  x: 'https://x.com/pinkybond_fun',
};
