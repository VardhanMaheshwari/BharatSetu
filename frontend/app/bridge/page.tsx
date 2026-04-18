"use client";

import { useState, useEffect } from "react";
import { useAccount, useSignMessage, useSendTransaction, usePublicClient, useChainId } from "wagmi";
import { encodeFunctionData } from "viem";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { siweLogin, isLoggedIn } from "../../lib/siwe";
import { createTransfer, confirmLock, getTransfer, Transfer } from "../../lib/api";
import { subscribeToTransfer } from "../../lib/socket";

const LOCK_BRIDGE  = "0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519" as const; // Amoy
const MINT_BRIDGE  = "0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519" as const; // Sepolia (also wCCC token)
const TCCS_TOKEN   = "0x3CcbD8c7b63363998e63F73E92fF72c5813bE4eB" as const; // tCCS on Amoy

const AMOY_CHAIN_ID    = 80002;
const SEPOLIA_CHAIN_ID = 11155111;

const ERC20_APPROVE_ABI = [{
  name: "approve",
  type: "function",
  inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
  outputs: [{ name: "", type: "bool" }],
}] as const;

const LOCK_BRIDGE_ABI = [{
  name: "lockTokens",
  type: "function",
  inputs: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "transferId", type: "bytes32" },
  ],
  outputs: [],
}] as const;

const BURN_BRIDGE_ABI = [{
  name: "burnAndBridge",
  type: "function",
  inputs: [
    { name: "amount", type: "uint256" },
    { name: "transferId", type: "bytes32" },
  ],
  outputs: [],
}] as const;

type Direction = "amoy_to_sepolia" | "sepolia_to_amoy";
type Step = "connect" | "login" | "form" | "pending" | "done" | "error";

const STATE_LABELS: Record<string, string> = {
  init:      "Awaiting your MetaMask transaction…",
  locked:    "Lock submitted — waiting for on-chain confirmation…",
  confirmed: "Confirmed — relayer is processing your transfer…",
  minted:    "Tokens processed — finalising…",
  completed: "Transfer complete!",
  failed:    "Transfer failed.",
};

const DIRECTION_CONFIG = {
  amoy_to_sepolia: {
    label:       "Amoy → Sepolia",
    fromChain:   "Polygon Amoy",
    toChain:     "Ethereum Sepolia",
    chainId:     AMOY_CHAIN_ID,
    action:      "Lock & Bridge",
    description: "Lock tCCS on Amoy → receive wCCC on Sepolia",
  },
  sepolia_to_amoy: {
    label:       "Sepolia → Amoy",
    fromChain:   "Ethereum Sepolia",
    toChain:     "Polygon Amoy",
    chainId:     SEPOLIA_CHAIN_ID,
    action:      "Burn & Bridge",
    description: "Burn wCCC on Sepolia → receive tCCS on Amoy",
  },
};

export default function BridgePage() {
  const { address, isConnected } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const { sendTransactionAsync } = useSendTransaction();
  const publicClient = usePublicClient();
  const chainId = useChainId();

  const [step, setStep] = useState<Step>("connect");
  const [direction, setDirection] = useState<Direction>("amoy_to_sepolia");
  const [amount, setAmount] = useState("");
  const [transferId, setTransferId] = useState<string | null>(null);
  const [transfer, setTransfer] = useState<Transfer | null>(null);
  const [error, setError] = useState<string | null>(null);

  const dirConfig = DIRECTION_CONFIG[direction];
  const onWrongChain = step === "form" && chainId !== dirConfig.chainId;

  // Restore step on page load
  useEffect(() => {
    if (!isConnected) { setStep("connect"); return; }
    if (!isLoggedIn()) { setStep("login"); return; }

    const savedId = localStorage.getItem("activeTransferId");
    if (savedId) {
      getTransfer(savedId).then(({ data: t }) => {
        setTransferId(savedId);
        setTransfer(t);
        if (t.state === "completed" || t.state === "failed") {
          setStep("done");
          localStorage.removeItem("activeTransferId");
        } else {
          setStep("pending");
        }
      }).catch(() => {
        localStorage.removeItem("activeTransferId");
        setStep("form");
      });
    } else {
      setStep("form");
    }
  }, [isConnected]);

  // Real-time updates
  useEffect(() => {
    if (!transferId) return;
    const token = localStorage.getItem("jwt") ?? "";
    const unsubscribe = subscribeToTransfer(transferId, token, (event) => {
      const state = (event as { state?: string }).state;
      if (state) {
        setTransfer((prev) => prev ? { ...prev, state: state as Transfer["state"] } : null);
        if (state === "completed" || state === "failed") {
          setStep("done");
          localStorage.removeItem("activeTransferId");
        }
      }
    });
    return unsubscribe;
  }, [transferId]);

  const handleLogin = async () => {
    if (!address) return;
    try {
      await siweLogin(address, (msg) => signMessageAsync({ account: address, message: msg }));
      setStep("form");
    } catch (e) {
      setError((e as Error).message);
      setStep("error");
    }
  };

  const handleSubmit = async () => {
    setError(null);
    const log = (s: string, d?: unknown) =>
      console.log(`[Bridge] ${s}` + (d !== undefined ? `: ${JSON.stringify(d)}` : ""));

    try {
      // Both directions use TCCS_TOKEN — for amoy_to_sepolia it's what gets locked,
      // for sepolia_to_amoy it's what the relayer unlocks on Amoy via LockBridge.unlock()
      const tokenAddress = TCCS_TOKEN;

      log("1 createTransfer", { token: tokenAddress, amount, direction });
      const { data } = await createTransfer(tokenAddress, amount, direction);
      log("1 createTransfer OK", { id: data.id, state: data.state });
      setTransferId(data.id);
      localStorage.setItem("activeTransferId", data.id);
      setStep("pending");

      const amountWei = BigInt(amount) * BigInt(10 ** 18);
      const transferIdBytes = `0x${data.id.replace(/-/g, "").padEnd(64, "0")}` as `0x${string}`;
      log("transferIdBytes", transferIdBytes);

      if (direction === "amoy_to_sepolia") {
        const amoyFees = {
          gas: BigInt(120000),
          maxFeePerGas: BigInt(50_000_000_000),
          maxPriorityFeePerGas: BigInt(30_000_000_000),
        };

        log("2 approve — waiting MetaMask");
        const approveTx = await sendTransactionAsync({
          to: TCCS_TOKEN,
          data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [LOCK_BRIDGE, amountWei] }),
          ...amoyFees,
        });
        log("2 approve submitted", { tx: approveTx });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx });
        log("2 approve mined");

        log("3 lockTokens — waiting MetaMask");
        const txHash = await sendTransactionAsync({
          to: LOCK_BRIDGE,
          data: encodeFunctionData({ abi: LOCK_BRIDGE_ABI, functionName: "lockTokens", args: [TCCS_TOKEN, amountWei, transferIdBytes] }),
          ...amoyFees,
        });
        log("3 lockTokens submitted", { tx: txHash });
        await publicClient!.waitForTransactionReceipt({ hash: txHash });
        log("3 lockTokens mined");

        log("4 confirmLock", { id: data.id, tx: txHash });
        await confirmLock(data.id, txHash);
        log("4 confirmLock OK");

      } else {
        // sepolia_to_amoy: burn wCCC on Sepolia
        const sepoliaFees = {
          gas: BigInt(100000),
          maxFeePerGas: BigInt(20_000_000_000),
          maxPriorityFeePerGas: BigInt(2_000_000_000),
        };

        log("2 burnAndBridge — waiting MetaMask");
        const txHash = await sendTransactionAsync({
          to: MINT_BRIDGE,
          data: encodeFunctionData({ abi: BURN_BRIDGE_ABI, functionName: "burnAndBridge", args: [amountWei, transferIdBytes] }),
          ...sepoliaFees,
        });
        log("2 burnAndBridge submitted", { tx: txHash });
        await publicClient!.waitForTransactionReceipt({ hash: txHash });
        log("2 burnAndBridge mined");

        log("3 confirmLock (burn confirmed)", { id: data.id, tx: txHash });
        await confirmLock(data.id, txHash);
        log("3 confirmLock OK");
      }

      const { data: t } = await getTransfer(data.id);
      log("getTransfer OK", { state: t.state });
      setTransfer(t);
    } catch (e) {
      console.error("[Bridge] ERROR", e);
      setError((e as Error).message);
      setStep("error");
    }
  };

  return (
    <div className="page">
      <h1>Bridge Carbon Credits</h1>

      {step === "connect" && (
        <section className="card">
          <h2>Step 1 — Connect Wallet</h2>
          <ConnectButton />
        </section>
      )}

      {step === "login" && (
        <section className="card">
          <h2>Step 2 — Sign In</h2>
          <p>Sign a message with MetaMask to authenticate.</p>
          <button onClick={handleLogin}>Sign In with Ethereum</button>
        </section>
      )}

      {step === "form" && (
        <section className="card">
          <h2>Step 3 — Bridge Tokens</h2>

          <div style={{ display: "flex", gap: "8px", marginBottom: "16px" }}>
            {(["amoy_to_sepolia", "sepolia_to_amoy"] as Direction[]).map((d) => (
              <button
                key={d}
                onClick={() => setDirection(d)}
                style={{
                  flex: 1,
                  padding: "8px",
                  fontWeight: direction === d ? "bold" : "normal",
                  border: direction === d ? "2px solid #0070f3" : "1px solid #ccc",
                  borderRadius: "6px",
                  cursor: "pointer",
                  background: direction === d ? "#e8f0fe" : "transparent",
                }}
              >
                {DIRECTION_CONFIG[d].label}
              </button>
            ))}
          </div>

          <p style={{ color: "#666", fontSize: "14px", marginBottom: "12px" }}>
            {dirConfig.description}
          </p>

          {onWrongChain && (
            <div style={{ background: "#fff3cd", border: "1px solid #ffc107", borderRadius: "6px", padding: "10px", marginBottom: "12px", color: "#856404" }}>
              ⚠️ Switch MetaMask to <strong>{dirConfig.fromChain}</strong> (chain ID {dirConfig.chainId}) to continue.
            </div>
          )}

          <label>Amount</label>
          <input
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="100"
            type="number"
          />
          <button onClick={handleSubmit} disabled={!amount || onWrongChain}>
            {dirConfig.action}
          </button>
        </section>
      )}

      {step === "pending" && transfer && (
        <section className="card">
          <h2>Transfer in Progress</h2>
          <p><strong>ID:</strong> {transfer.id}</p>
          <p><strong>Status:</strong> {STATE_LABELS[transfer.state] ?? transfer.state}</p>
          {transfer.lock_tx_hash && (
            <p><strong>Lock Tx:</strong> {transfer.lock_tx_hash}</p>
          )}
          {transfer.mint_tx_hash && (
            <p><strong>Mint Tx:</strong> {transfer.mint_tx_hash}</p>
          )}
          <div className="progress-bar">
            <div
              className="progress-fill"
              style={{ width: `${stateProgress(transfer.state)}%` }}
            />
          </div>
        </section>
      )}

      {step === "done" && transfer && (
        <section className="card success">
          <h2>{transfer.state === "completed" ? "🎉 Transfer Complete!" : "❌ Transfer Failed"}</h2>
          <p>Transfer ID: {transfer.id}</p>
          {transfer.mint_tx_hash && <p>Mint Tx: {transfer.mint_tx_hash}</p>}
          <button onClick={() => {
            localStorage.removeItem("activeTransferId");
            setStep("form");
            setTransfer(null);
            setTransferId(null);
          }}>
            New Transfer
          </button>
        </section>
      )}

      {step === "error" && (
        <section className="card error">
          <h2>Error</h2>
          <p>{error}</p>
          <button onClick={() => setStep(isLoggedIn() ? "form" : "login")}>Retry</button>
        </section>
      )}
    </div>
  );
}

function stateProgress(state: string): number {
  const map: Record<string, number> = {
    init: 20, locked: 40, confirmed: 60, minted: 80, completed: 100, failed: 100,
  };
  return map[state] ?? 0;
}
