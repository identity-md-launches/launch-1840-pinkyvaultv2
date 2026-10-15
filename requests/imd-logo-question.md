# Question to IMD about the launch logo

Where: a new issue in https://github.com/Identity-md/worker/issues

## Title

```
Launch logo: where is it published, and can the requester replace it?
```

## Body

```
Launch #1166 (Pinky, Robinhood Chain) got a logo from a `token-logo` job the launch opened by itself:

- launch: 6e9ac2a3-b5e4-4e2d-bf78-b61a8e2af6be
- logo job: 3ddc4977-0765-4a6e-8208-3f9be567f0c5
- artifact: https://api.imd.fun/artifacts/db1c85a8b47d16296b5eada7d67911a848be75db045bc3757d4568f9008a4004
- token: 0xb125c461c00863aacad4cc99311d2f23d4342a6f

The drawing is good, but the project already has a mark and colours of its own, used on the site and everywhere else:

https://github.com/hexysdev/pinky/blob/main/brand/token-logo.png (512×512, mark inside the central circle, no text)

Three questions, since the docs don't mention logos:

1. Where does a launch's logo go? Only IMD's own pages, or also token lists, explorers or aggregators? Wallets (Rabby) and GMGN show PINKY with no icon at all, so it does not seem to reach them.
2. Can the requester replace it? `GET /launches/:id` returns `logo: {jobId, state, hash, cleared}`. Is `cleared` something the paying wallet can set, and is there a way to supply a file instead of a drawn one?
3. If not today: would a `logo` input on `launch.open` (a hash of an accepted file, like `inputs[]`) be in scope?

I'm the requester of the launch (payer 0x89d6584e733ece619c9c34f9a370e1dff5ecf8ef) and can sign a message from that wallet if that helps.
```
