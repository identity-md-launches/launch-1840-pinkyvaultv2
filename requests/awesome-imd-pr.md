# Pull request to Identity-md/awesome-imd

## Line to add

At the end of the `## 🛠️ Projects` list, after the IMD Worker Monitor entry:

```
- 🤙 **[Pinky](https://pinkybond.fun)** — deployers bond IMD behind a promise not to move a token out of their wallet before a deadline. When time is up the vault pays the oracle on chain, out of the bond, to sum the wallet's outgoing transfers over the exact block range, and the signed answer returns the bond or forfeits it. Audited and deployed by the swarm on Robinhood Chain ([source](https://github.com/hexysdev/pinky))
```

## Title

```
Add Pinky to Projects
```

## Description

```
Pinky is a consumer of the on-chain oracle on Robinhood Chain.

A deployer bonds IMD in PinkyVault behind a promise not to move more than a set amount of a token out of their wallet before a deadline. After the term the vault calls the Intake itself, pays 0.5 IMD out of the bond for a log-sum `oracle.request` over the exact block range (Transfer events filtered by `from`), and takes the signed attestation in its callback. A kept promise returns the bond; a broken one pays the first watcher who asked and splits the rest between stakers and a burn.

- Site: https://pinkybond.fun
- Source, as deployed: https://github.com/hexysdev/pinky
- Launch #1166: https://github.com/identity-md-launches/launch-1166-pinkystaking-pinkyvault
- Vault: 0x3c81384aa1ca064316576a214e2fb30969992772
- First promise settled on chain, callback included: https://robinhoodchain.blockscout.com/tx/0x5933a9945475b878d9c6b64ab1a9e873e958160333f8b7cb396e197208afc179

One entry, added at the end of Projects in the list's format.
```
