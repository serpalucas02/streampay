# 💸 StreamPay

Real-time token payments: lock an ERC-20 amount and **stream it to someone linearly over time**. The recipient can withdraw whatever has accrued at any second, and either party can cancel and split the rest fairly. Think "salary by the second" — a money-streaming primitive like [Sablier](https://sablier.com) or [Superfluid](https://superfluid.finance).

> Full-stack portfolio project: Solidity contract (Foundry) + Next.js frontend (wagmi/viem) with a live counter that ticks up second by second.

---

## Live demo

- 🌐 **App:** _(deploy `web/` to Vercel — see below)_
- 📜 **StreamPay (verified):** [`0x110b…e9f1`](https://sepolia.etherscan.io/address/0x110bf7728138a8d401d9b4bbff09ec956869e9f1#code)
- 🪙 **Test token sUSD (verified):** [`0x39A5…2cB7`](https://sepolia.etherscan.io/address/0x39a5042cfb5cc1af57d8648799feac555a492cb7#code)

On **Ethereum Sepolia**. The app has a built-in faucet — connect, grab test `sUSD`, then stream it to any address.

---

## What makes it interesting

- **Money that flows.** A stream pays out continuously; the recipient pulls the accrued amount whenever they want. The UI shows the streamed balance **incrementing live**, computed client-side from the on-chain rate (no transactions to watch it).
- **Any ERC-20.** The payer picks the token when creating a stream — the contract is token-agnostic.
- **Fair cancellation.** Cancel mid-stream and the recipient keeps exactly what accrued; the sender gets the unstreamed remainder back, in one call.

---

## How it works

The accrued amount isn't stored — it's **computed on read** from time, the same idea as a vesting curve:

```
streamed = deposit * elapsed / duration   (0 before start, full deposit at/after stop)
```

```solidity
function createStream(token, recipient, deposit, duration); // lock funds, open the stream
function withdraw(streamId);                                 // recipient pulls accrued (pull pattern)
function cancel(streamId);                                   // settle: recipient keeps accrued, sender refunded
```

---

## Architecture

```
src/StreamPay.sol         The protocol: create / withdraw / cancel + accrual views
src/MockToken.sol         Faucet-style ERC-20 for the demo
script/Deploy.s.sol       Deploys StreamPay + MockToken
test/StreamPay.t.sol      Foundry suite (unit + fuzz + reentrancy attack), 100% coverage
web/                      Next.js frontend (App Router)
  lib/wagmi.ts            Chains, connectors, transports
  lib/contract.ts         Addresses + ABIs (typed via `as const`)
  app/page.tsx            Connect, faucet, create-stream form, live stream cards
```

The frontend holds no state of its own: it writes to the contract, waits, and re-reads it.

---

## Design decisions

**Accrual computed on read (not stored).** A stream's "streamed so far" is a pure function of `block.timestamp`, so it's always current and costs no gas to update — the contract only stores the deposit, what's been withdrawn, and the time window.

**`Math.mulDiv` for the proportion.** `deposit * elapsed / duration` is done with OpenZeppelin's `mulDiv`: full precision, no overflow on the intermediate product, and it lands **exactly** on the deposit at `stopTime` — no rounding dust left stuck in the contract.

**Find streams via events, not on-chain enumeration.** Listing a user's streams is a UI concern, so the contract emits `StreamCreated` (indexed by sender and recipient) and the frontend reads it off-chain via RPC — far cheaper than maintaining on-chain arrays for every account.

**Token-agnostic.** Streams carry their own token address, so one deployment works for any ERC-20.

---

## Security

- **`SafeERC20`** for every token movement (handles non-standard ERC-20s).
- **`ReentrancyGuard` + strict CEI** on `withdraw` and `cancel` (state settled before any transfer).
- **Pull pattern** — recipients withdraw; the contract never pushes.
- **Access control** — only the recipient withdraws; only the sender or recipient can cancel.
- Custom errors + input validation (zero address, zero deposit/duration, no self-stream).
- A test (`testReentrancyGuardBlocksMaliciousToken`) deploys a malicious ERC-20 that tries to **reenter `withdraw`** on its transfer hook and asserts the guard blocks it.

---

## Run it locally

Needs [Foundry](https://book.getfoundry.sh/) and Node.js.

```bash
forge test           # run the suite
forge coverage       # coverage report

cd web && npm install && npm run dev   # http://localhost:3000
```

The app is wired to **Sepolia** by default; for local anvil dev, point `EXPECTED_CHAIN` (`app/page.tsx`) and the addresses (`lib/contract.ts`) to your local deployment.

### Deploy

```bash
cp .env.example .env   # fill DEPLOYER_PRIVATE_KEY (+ ETHERSCAN_API_KEY to verify)
source .env
forge script script/Deploy.s.sol --rpc-url sepolia --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify
```

### Frontend on Vercel

Import the repo, set **Root Directory = `web`**, deploy. No env vars needed.

---

## Tests

```
src/StreamPay.sol   100% lines · 100% statements · 100% branches · 100% funcs   (32 tests)
```

Happy paths, every revert, time-based accrual, a fuzz test on the accrual invariant, and the reentrancy attack.

---

## Gas

| Operation | Gas |
|-----------|-----|
| `createStream` | ~177,000 |
| `withdraw` | ~90,000 |
| `cancel` | ~82,000 |
| accrual views | 0 — read off-chain |

---

## Tech stack

Solidity 0.8.24 · Foundry · OpenZeppelin (SafeERC20, ReentrancyGuard, Math) · Next.js · wagmi · viem · TypeScript · Tailwind CSS
