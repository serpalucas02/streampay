"use client";

import { useCallback, useEffect, useState } from "react";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useSwitchChain,
  usePublicClient,
  useWriteContract,
} from "wagmi";
import { sepolia } from "wagmi/chains";
import { formatUnits, parseUnits, isAddress, BaseError, UserRejectedRequestError } from "viem";
import {
  STREAMPAY_ADDRESS,
  TOKEN_ADDRESS,
  START_BLOCK,
  TOKEN_DECIMALS,
  TOKEN_SYMBOL,
  streamPayAbi,
  tokenAbi,
} from "@/lib/contract";
import { PRODUCTION_TOKENS } from "@/lib/tokens";

const EXPECTED_CHAIN = sepolia;

const DURATIONS = [
  { label: "5 minutes", secs: 300 },
  { label: "1 hour", secs: 3600 },
  { label: "1 day", secs: 86400 },
  { label: "30 days", secs: 2592000 },
];

type StreamRow = {
  id: bigint;
  sender: string;
  recipient: string;
  deposit: bigint;
  withdrawn: bigint;
  startTime: number;
  stopTime: number;
  active: boolean;
  role: "in" | "out";
};

// Linear accrual, mirrors the contract: 0 before start, full deposit at/after stop.
function computeStreamed(deposit: bigint, start: number, stop: number, nowSec: number): bigint {
  if (nowSec <= start) return BigInt(0);
  if (nowSec >= stop) return deposit;
  const elapsed = BigInt(nowSec - start);
  const duration = BigInt(stop - start);
  return (deposit * elapsed) / duration;
}

function fmt(wei: bigint, decimals = 4): string {
  return Number(formatUnits(wei, TOKEN_DECIMALS)).toLocaleString("en-US", {
    maximumFractionDigits: decimals,
  });
}

// Parse the amount field to wei, returning null if it's empty or malformed.
function safeParse(v: string): bigint | null {
  try {
    return v.trim() ? parseUnits(v, TOKEN_DECIMALS) : null;
  } catch {
    return null;
  }
}

function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export default function Home() {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const publicClient = usePublicClient();
  const { writeContractAsync } = useWriteContract();

  const [streams, setStreams] = useState<StreamRow[]>([]);
  const [balance, setBalance] = useState<bigint>(BigInt(0));
  const [claimableBal, setClaimableBal] = useState<bigint>(BigInt(0));
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<string | null>(null); // a label for whatever action is running
  const [now, setNow] = useState(0); // current time in seconds, drives the live counters

  // form
  const [recipient, setRecipient] = useState("");
  const [amount, setAmount] = useState("");
  const [durationSecs, setDurationSecs] = useState(DURATIONS[1].secs);

  const wrongNetwork = isConnected && chainId !== EXPECTED_CHAIN.id;

  // Form validation — all checked up front so we never send a tx that's bound to fail.
  const parsedAmount = safeParse(amount);
  const isSelf = !!address && isAddress(recipient) && recipient.toLowerCase() === address.toLowerCase();
  const recipientOk = isAddress(recipient) && !isSelf;
  const amountOk = parsedAmount !== null && parsedAmount > BigInt(0);
  const enoughBalance = parsedAmount !== null && parsedAmount <= balance;
  const canCreate = recipientOk && amountOk && enoughBalance;

  // Tick the clock once a second so the streamed amounts update live (pure client-side, no RPC).
  // The wall clock is an external system; syncing the first tick on mount is intentional.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setNow(Math.floor(Date.now() / 1000));
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  const refresh = useCallback(async () => {
    if (!publicClient || !address) {
      setStreams([]);
      setBalance(BigInt(0));
      setClaimableBal(BigInt(0));
      return;
    }
    setLoading(true);
    try {
      setBalance(
        (await publicClient.readContract({
          address: TOKEN_ADDRESS,
          abi: tokenAbi,
          functionName: "balanceOf",
          args: [address],
        })) as bigint,
      );
      setClaimableBal(
        (await publicClient.readContract({
          address: STREAMPAY_ADDRESS,
          abi: streamPayAbi,
          functionName: "claimable",
          args: [address, TOKEN_ADDRESS],
        })) as bigint,
      );

      // Streams are found off-chain via the StreamCreated event (cheaper than on-chain enumeration).
      const [incoming, outgoing] = await Promise.all([
        publicClient.getContractEvents({
          address: STREAMPAY_ADDRESS,
          abi: streamPayAbi,
          eventName: "StreamCreated",
          args: { recipient: address },
          fromBlock: START_BLOCK,
          toBlock: "latest",
        }),
        publicClient.getContractEvents({
          address: STREAMPAY_ADDRESS,
          abi: streamPayAbi,
          eventName: "StreamCreated",
          args: { sender: address },
          fromBlock: START_BLOCK,
          toBlock: "latest",
        }),
      ]);

      const roles = new Map<string, "in" | "out">();
      for (const l of incoming) roles.set((l.args.streamId as bigint).toString(), "in");
      for (const l of outgoing) roles.set((l.args.streamId as bigint).toString(), "out");

      const rows: StreamRow[] = [];
      for (const [idStr, role] of roles) {
        const id = BigInt(idStr);
        const s = (await publicClient.readContract({
          address: STREAMPAY_ADDRESS,
          abi: streamPayAbi,
          functionName: "getStream",
          args: [id],
        })) as {
          sender: string;
          recipient: string;
          deposit: bigint;
          withdrawn: bigint;
          startTime: bigint;
          stopTime: bigint;
          active: boolean;
        };
        rows.push({
          id,
          sender: s.sender,
          recipient: s.recipient,
          deposit: s.deposit,
          withdrawn: s.withdrawn,
          startTime: Number(s.startTime),
          stopTime: Number(s.stopTime),
          active: s.active,
          role,
        });
      }
      rows.sort((a, b) => Number(b.id - a.id));
      setStreams(rows);
    } finally {
      setLoading(false);
    }
  }, [publicClient, address]);

  // Load on-chain data on connect / account / network change.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    refresh();
  }, [refresh]);

  async function run(label: string, fn: () => Promise<void>) {
    setBusy(label);
    try {
      await fn();
      await refresh();
    } catch (err) {
      // Ignore wallet rejections; only log real failures.
      if (!(err instanceof BaseError && err.walk((e) => e instanceof UserRejectedRequestError))) {
        console.error(err);
      }
    } finally {
      setBusy(null);
    }
  }

  function getTestTokens() {
    run("faucet", async () => {
      const hash = await writeContractAsync({
        address: TOKEN_ADDRESS,
        abi: tokenAbi,
        functionName: "mint",
        args: [address!, parseUnits("1000", TOKEN_DECIMALS)],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
    });
  }

  function createStream() {
    if (!canCreate || parsedAmount === null) return;
    run("create", async () => {
      // 1) approve the contract to pull the deposit
      const approveHash = await writeContractAsync({
        address: TOKEN_ADDRESS,
        abi: tokenAbi,
        functionName: "approve",
        args: [STREAMPAY_ADDRESS, parsedAmount],
      });
      await publicClient!.waitForTransactionReceipt({ hash: approveHash });
      // 2) open the stream
      const createHash = await writeContractAsync({
        address: STREAMPAY_ADDRESS,
        abi: streamPayAbi,
        functionName: "createStream",
        args: [TOKEN_ADDRESS, recipient as `0x${string}`, parsedAmount, BigInt(durationSecs)],
      });
      await publicClient!.waitForTransactionReceipt({ hash: createHash });
      setRecipient("");
      setAmount("");
    });
  }

  function withdraw(id: bigint) {
    run(`withdraw-${id}`, async () => {
      const hash = await writeContractAsync({
        address: STREAMPAY_ADDRESS,
        abi: streamPayAbi,
        functionName: "withdraw",
        args: [id],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
    });
  }

  function cancel(id: bigint) {
    run(`cancel-${id}`, async () => {
      const hash = await writeContractAsync({
        address: STREAMPAY_ADDRESS,
        abi: streamPayAbi,
        functionName: "cancel",
        args: [id],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
    });
  }

  function claim() {
    run("claim", async () => {
      const hash = await writeContractAsync({
        address: STREAMPAY_ADDRESS,
        abi: streamPayAbi,
        functionName: "claim",
        args: [TOKEN_ADDRESS],
      });
      await publicClient!.waitForTransactionReceipt({ hash });
    });
  }

  const incoming = streams.filter((s) => s.role === "in");
  const outgoing = streams.filter((s) => s.role === "out");

  return (
    <div className="flex flex-1 flex-col bg-gradient-to-b from-sky-50 via-white to-blue-100 text-slate-900">
      <header className="flex flex-wrap items-center justify-between gap-3 px-4 py-4 sm:px-6">
        <span className="text-xl font-bold">💸 StreamPay</span>
        {isConnected ? (
          <button
            onClick={() => disconnect()}
            className="rounded-full bg-blue-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-500"
          >
            {shortAddr(address!)} · Disconnect
          </button>
        ) : (
          <button
            onClick={() => connect({ connector: connectors[0] })}
            className="rounded-full bg-blue-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-500"
          >
            Connect wallet
          </button>
        )}
      </header>

      <main className="mx-auto w-full max-w-4xl flex-1 px-4 py-10 sm:px-6">
        <div className="mb-10 text-center">
          <h1 className="text-3xl font-extrabold tracking-tight sm:text-4xl">
            <span className="bg-gradient-to-r from-blue-700 to-sky-500 bg-clip-text text-transparent">
              Stream payments by the second
            </span>
          </h1>
          <p className="mx-auto mt-3 max-w-xl text-slate-600">
            Lock an ERC-20 amount and let it flow to someone linearly over time. They can withdraw whatever has accrued
            at any moment — and either side can cancel and split the rest fairly.
          </p>
        </div>

        {!isConnected && (
          <p className="text-center text-slate-600">Connect your wallet to start streaming.</p>
        )}

        {wrongNetwork && (
          <Banner>
            Wrong network.{" "}
            <button onClick={() => switchChain({ chainId: EXPECTED_CHAIN.id })} className="font-semibold underline">
              Switch to {EXPECTED_CHAIN.name}
            </button>
          </Banner>
        )}

        {isConnected && !wrongNetwork && (
          <div className="space-y-8">
            {claimableBal > BigInt(0) && (
              <div className="flex flex-col items-start gap-3 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 sm:flex-row sm:items-center sm:justify-between">
                <span className="text-sm text-emerald-900">
                  You have <strong>{fmt(claimableBal)} {TOKEN_SYMBOL}</strong> ready to claim (from cancelled streams).
                </span>
                <button
                  onClick={claim}
                  disabled={busy === "claim"}
                  className="rounded-lg bg-emerald-600 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                >
                  {busy === "claim" ? "Claiming…" : "Claim"}
                </button>
              </div>
            )}

            {/* faucet + create form */}
            <section className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-sm">
              <div className="mb-4 flex flex-col items-start gap-2 sm:flex-row sm:items-center sm:justify-between">
                <span className="text-sm text-slate-500">
                  Balance: <strong>{fmt(balance)} {TOKEN_SYMBOL}</strong>
                </span>
                <button
                  onClick={getTestTokens}
                  disabled={busy === "faucet"}
                  className="rounded-lg bg-emerald-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                >
                  {busy === "faucet" ? "Minting…" : `Get 1000 test ${TOKEN_SYMBOL}`}
                </button>
              </div>

              <h2 className="mb-3 font-semibold">Create a stream</h2>
              <div className="grid gap-3 sm:grid-cols-2">
                <input
                  value={recipient}
                  onChange={(e) => setRecipient(e.target.value)}
                  placeholder="Recipient address (0x…)"
                  className="rounded-lg border border-slate-300 px-3 py-2 text-sm outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100 sm:col-span-2"
                />
                <select
                  defaultValue={TOKEN_SYMBOL}
                  aria-label="Token to stream"
                  className="rounded-lg border border-slate-300 px-3 py-2 text-sm outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                >
                  <option value={TOKEN_SYMBOL}>{TOKEN_SYMBOL} (test token)</option>
                  {PRODUCTION_TOKENS.map((t) => (
                    <option key={t.symbol} value={t.symbol} disabled>
                      {t.symbol} · mainnet only
                    </option>
                  ))}
                </select>
                <input
                  value={amount}
                  onChange={(e) => {
                    const v = e.target.value;
                    if (v === "" || /^\d*\.?\d*$/.test(v)) setAmount(v); // digits + one optional dot only
                  }}
                  placeholder={`Amount (${TOKEN_SYMBOL})`}
                  inputMode="decimal"
                  className="rounded-lg border border-slate-300 px-3 py-2 text-sm outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                />
                <select
                  value={durationSecs}
                  onChange={(e) => setDurationSecs(Number(e.target.value))}
                  className="rounded-lg border border-slate-300 px-3 py-2 text-sm outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                >
                  {DURATIONS.map((d) => (
                    <option key={d.secs} value={d.secs}>
                      over {d.label}
                    </option>
                  ))}
                </select>
                <button
                  onClick={createStream}
                  disabled={busy === "create" || !canCreate}
                  className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-500 disabled:opacity-50"
                >
                  {busy === "create" ? "Creating…" : "Start streaming"}
                </button>
              </div>
              {recipient && !isAddress(recipient) ? (
                <p className="mt-2 text-xs text-rose-500">Enter a valid recipient address.</p>
              ) : isSelf ? (
                <p className="mt-2 text-xs text-rose-500">You can&apos;t stream to your own address.</p>
              ) : amountOk && !enoughBalance ? (
                <p className="mt-2 text-xs text-rose-500">
                  Not enough {TOKEN_SYMBOL} — your balance is {fmt(balance)}.
                </p>
              ) : (
                <p className="mt-2 text-xs text-slate-400">Creating a stream takes two signatures: approve, then create.</p>
              )}
              <p className="mt-3 border-t border-slate-100 pt-3 text-xs text-slate-400">
                Demo token: <strong>{TOKEN_SYMBOL}</strong> — a mintable test token, since real stablecoins aren&apos;t
                available on a testnet. The contract is token-agnostic: in production the same deployment works with any
                ERC-20 ({PRODUCTION_TOKENS.map((t) => t.symbol).join(", ")}, …).
              </p>
            </section>

            {loading && <p className="text-center text-slate-500">Loading your streams…</p>}

            <StreamList
              title="Incoming — money flowing to you"
              empty="No incoming streams yet."
              rows={incoming}
              now={now}
              busy={busy}
              onAction={withdraw}
              actionLabel="Withdraw"
            />
            <StreamList
              title="Outgoing — money you're streaming"
              empty="You're not streaming to anyone yet."
              rows={outgoing}
              now={now}
              busy={busy}
              onAction={cancel}
              actionLabel="Cancel"
            />
          </div>
        )}
      </main>
    </div>
  );
}

function StreamList({
  title,
  empty,
  rows,
  now,
  busy,
  onAction,
  actionLabel,
}: {
  title: string;
  empty: string;
  rows: StreamRow[];
  now: number;
  busy: string | null;
  onAction: (id: bigint) => void;
  actionLabel: "Withdraw" | "Cancel";
}) {
  return (
    <section>
      <h2 className="mb-3 font-semibold">{title}</h2>
      {rows.length === 0 ? (
        <p className="text-sm text-slate-400">{empty}</p>
      ) : (
        <div className="space-y-4">
          {rows.map((s) => (
            <StreamCard key={s.id.toString()} s={s} now={now} busy={busy} onAction={onAction} actionLabel={actionLabel} />
          ))}
        </div>
      )}
    </section>
  );
}

function StreamCard({
  s,
  now,
  busy,
  onAction,
  actionLabel,
}: {
  s: StreamRow;
  now: number;
  busy: string | null;
  onAction: (id: bigint) => void;
  actionLabel: "Withdraw" | "Cancel";
}) {
  // Active streams tick live; settled ones freeze at what the recipient actually received.
  const streamed = s.active ? computeStreamed(s.deposit, s.startTime, s.stopTime, now) : s.withdrawn;
  const withdrawable = s.active ? streamed - s.withdrawn : BigInt(0);
  const pct = s.deposit > BigInt(0) ? Number((streamed * BigInt(10000)) / s.deposit) / 100 : 0;
  const counterpart = actionLabel === "Withdraw" ? s.sender : s.recipient;
  const actionId = `${actionLabel.toLowerCase()}-${s.id}`;
  const running = busy === actionId;

  return (
    <div className="rounded-2xl border border-slate-200/70 bg-white p-5 shadow-sm">
      <div className="mb-2 flex items-center justify-between">
        <span className="text-sm font-medium">
          Stream #{s.id.toString()}{" "}
          <span className="text-slate-400">
            · {actionLabel === "Withdraw" ? "from" : "to"} {shortAddr(counterpart)}
          </span>
        </span>
        <span
          className={`rounded-full px-2 py-0.5 text-xs font-medium ${
            s.active ? "bg-blue-100 text-blue-700" : "bg-slate-100 text-slate-500"
          }`}
        >
          {s.active ? "Active" : "Done"}
        </span>
      </div>

      {/* the live counter */}
      <div className="mb-1 break-words font-mono text-xl font-bold text-blue-700 sm:text-2xl">
        {fmt(streamed, 6)} <span className="text-base text-slate-400">/ {fmt(s.deposit)} {TOKEN_SYMBOL}</span>
      </div>

      <div className="my-3 h-2 w-full overflow-hidden rounded-full bg-slate-100">
        <div className="h-full rounded-full bg-blue-500 transition-all" style={{ width: `${pct}%` }} />
      </div>

      <div className="flex flex-col items-start gap-2 text-sm text-slate-500 sm:flex-row sm:items-center sm:justify-between">
        <span>Withdrawn: {fmt(s.withdrawn)} {TOKEN_SYMBOL}</span>
        {s.active && (
          <button
            onClick={() => onAction(s.id)}
            disabled={running || (actionLabel === "Withdraw" && withdrawable === BigInt(0))}
            className={`rounded-lg px-4 py-2 text-sm font-semibold text-white disabled:opacity-50 ${
              actionLabel === "Withdraw" ? "bg-blue-600 hover:bg-blue-500" : "bg-rose-500 hover:bg-rose-600"
            }`}
          >
            {running
              ? "…"
              : actionLabel === "Withdraw"
                ? `Withdraw ${fmt(withdrawable, 4)}`
                : "Cancel"}
          </button>
        )}
      </div>
    </div>
  );
}

function Banner({ children }: { children: React.ReactNode }) {
  return (
    <div className="mx-auto mb-6 max-w-xl rounded-lg bg-amber-100 px-4 py-3 text-center text-sm text-amber-900">
      {children}
    </div>
  );
}
