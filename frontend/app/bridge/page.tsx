"use client";

import { useState, useEffect, useRef } from "react";
import { useAccount, useSignMessage, useSendTransaction, usePublicClient, useChainId, useBalance, useSwitchChain } from "wagmi";
import { encodeFunctionData, formatUnits, keccak256, concat, toBytes } from "viem";
import bs58 from "bs58";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { siweLogin, isLoggedIn } from "../../lib/siwe";
import { createTransfer, confirmLock, getTransfer, getConfig, cancelTransfer, retryTransfer, Transfer, BridgeConfig } from "../../lib/api";
import { subscribeToTransfer } from "../../lib/socket";

// Solana
import { useConnection, useWallet } from "@solana/wallet-adapter-react";
import { WalletMultiButton } from "@solana/wallet-adapter-react-ui";
import { Connection, PublicKey, Transaction as SolanaTransaction, SystemProgram, Transaction } from "@solana/web3.js";

const ERC20_APPROVE_ABI = [{
  name: "approve", type: "function",
  inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
  outputs: [{ name: "", type: "bool" }],
}] as const;

const LOCK_BRIDGE_ABI = [{
  name: "lockTokens", type: "function",
  inputs: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "transferId", type: "bytes32" },
  ],
  outputs: [],
}] as const;

const BURN_BRIDGE_ABI = [{
  name: "burnAndBridge", type: "function",
  inputs: [{ name: "amount", type: "uint256" }, { name: "transferId", type: "bytes32" }],
  outputs: [],
}] as const;

const LOCK_CBDC_ABI = [{
  name: "lockCBDC", type: "function",
  inputs: [{ name: "amount", type: "uint256" }, { name: "transferId", type: "bytes32" }],
  outputs: [],
}] as const;

const LOCK_CBDC_INSTRUCTION_ABI = [{
  name: "lockCBDCWithInstruction", type: "function",
  inputs: [{ name: "amount", type: "uint256" }, { name: "transferId", type: "bytes32" }, { name: "instructionPayload", type: "bytes" }],
  outputs: [],
}] as const;

const LOCK_ASSET_ABI = [{
  name: "lockAsset", type: "function",
  inputs: [
    { name: "tokenContract", type: "address" },
    { name: "tokenId", type: "uint256" },
    { name: "transferId", type: "bytes32" },
    { name: "instructionPayload", type: "bytes" },
  ],
  outputs: [],
}] as const;

const ERC721_APPROVE_ABI = [{
  name: "approve", type: "function",
  inputs: [{ name: "to", type: "address" }, { name: "tokenId", type: "uint256" }],
  outputs: [],
}] as const;

const ETH_VAULT_LOCK_ABI = [{
  name: "lock", type: "function",
  inputs: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "crossChainId", type: "bytes32" },
    { name: "destWallet", type: "bytes" },
    { name: "timeoutSec", type: "uint256" },
  ],
  outputs: [],
}] as const;

type Direction = "amoy_to_sepolia" | "sepolia_to_amoy" | "cbdc_to_stablecoin" | "token_to_instruction" | "asset_to_instruction" | "eth_to_sol" | "sol_to_eth" | "eth_nft_to_sol" | "sol_nft_to_eth";
type ChainKey = "amoy" | "sepolia" | "anvil" | "solana";
type Step = "connect" | "login" | "form" | "pending" | "done" | "error";

const CHAIN_META: Record<ChainKey, { label: string; sub: string; cls: string }> = {
  amoy:    { label: "Polygon",   sub: "tCCS",  cls: "amoy" },
  sepolia: { label: "Ethereum",  sub: "wCCC",  cls: "sepolia" },
  anvil:   { label: "CBDC",      sub: "INRDC", cls: "anvil" },
  solana:  { label: "Solana",    sub: "SPL",   cls: "solana" },
};

// Which destination chains are valid for each source chain
const VALID_DEST: Record<ChainKey, ChainKey[]> = {
  amoy:    ["sepolia"],
  sepolia: ["solana", "amoy"],
  anvil:   ["amoy"],
  solana:  ["sepolia"],
};

function deriveDirection(from: ChainKey, to: ChainKey, cbdcMode: "token" | "instruction" | "asset", nft: boolean): Direction {
  if (from === "amoy"    && to === "sepolia") return "amoy_to_sepolia";
  if (from === "sepolia" && to === "amoy")    return "sepolia_to_amoy";
  if (from === "sepolia" && to === "solana")  return nft ? "eth_nft_to_sol" : "eth_to_sol";
  if (from === "solana"  && to === "sepolia") return nft ? "sol_nft_to_eth" : "sol_to_eth";
  if (from === "anvil"   && to === "amoy") {
    if (cbdcMode === "instruction") return "token_to_instruction";
    if (cbdcMode === "asset")       return "asset_to_instruction";
    return "cbdc_to_stablecoin";
  }
  return "amoy_to_sepolia";
}

type StepDef = {
  key: string;
  label: string;
  desc: string;
  eta: string | null;
  chain?: string;         // badge label
  chainCls?: string;      // badge color class
  txField?: "lock" | "mint"; // which tx hash to show as link
};

const STEPS_FORWARD: StepDef[] = [
  { key: "init",      label: "Approve & Lock",       desc: "Approve tCCS spend + lock tokens in LockBridge on Amoy",    eta: null,      chain: "Polygon Amoy",     chainCls: "amoy",    txField: "lock" },
  { key: "locked",    label: "Awaiting Confirmation", desc: "Waiting for 3 block confirmations on Amoy",                eta: "~1 min",  chain: "Polygon Amoy",     chainCls: "amoy" },
  { key: "confirmed", label: "Relayer Processing",    desc: "Relayer detected lock — minting wCCC on Sepolia",          eta: "~30 sec", chain: "Eth Sepolia",      chainCls: "sepolia" },
  { key: "minted",    label: "Minted",                desc: "wCCC tokens minted to your Sepolia wallet",                eta: null,      chain: "Eth Sepolia",      chainCls: "sepolia", txField: "mint" },
  { key: "completed", label: "Complete",              desc: "Bridge transfer finished",                                 eta: null },
];

const STEPS_REVERSE: StepDef[] = [
  { key: "init",      label: "Burn & Bridge",         desc: "Burn wCCC on MintBridge (Sepolia) — no approval needed",  eta: null,      chain: "Eth Sepolia",      chainCls: "sepolia", txField: "lock" },
  { key: "locked",    label: "Awaiting Confirmation", desc: "Waiting for 3 block confirmations on Sepolia",            eta: "~45 sec", chain: "Eth Sepolia",      chainCls: "sepolia" },
  { key: "confirmed", label: "Relayer Processing",    desc: "Relayer detected burn — unlocking tCCS on Amoy",          eta: "~30 sec", chain: "Polygon Amoy",     chainCls: "amoy" },
  { key: "minted",    label: "Tokens Released",       desc: "tCCS tokens unlocked to your Amoy wallet",               eta: null,      chain: "Polygon Amoy",     chainCls: "amoy",    txField: "mint" },
  { key: "completed", label: "Complete",              desc: "Bridge transfer finished",                                eta: null },
];

const STEPS_CBDC: StepDef[] = [
  { key: "init",      label: "Compliance Check + Lock", desc: "KYC/OFAC verified — approve INRDC + lock in CBDC Vault", eta: null,      chain: "Anvil CBDC",       chainCls: "anvil",   txField: "lock" },
  { key: "locked",    label: "Awaiting Confirmation",   desc: "Waiting for 3 block confirmations on local chain",       eta: "~15 sec", chain: "Anvil CBDC",       chainCls: "anvil" },
  { key: "confirmed", label: "Hub Relay Processing",    desc: "2-of-3 relayers signing approval — minting INRX",        eta: "~30 sec", chain: "Polygon Amoy",     chainCls: "amoy" },
  { key: "minted",    label: "Stablecoin Minted",       desc: "INRX tokens minted to your Polygon Amoy wallet",        eta: null,      chain: "Polygon Amoy",     chainCls: "amoy",    txField: "mint" },
  { key: "completed", label: "Complete",                desc: "CBDC → Stablecoin conversion finished",                  eta: null },
];

const STEPS_TOKEN_INSTRUCTION: StepDef[] = [
  { key: "init",      label: "Compliance Check + Lock", desc: "KYC/OFAC verified — approve INRDC + lock with payload",  eta: null,      chain: "Anvil CBDC",       chainCls: "anvil",   txField: "lock" },
  { key: "locked",    label: "Awaiting Confirmation",   desc: "Waiting for 3 block confirmations on local chain",       eta: "~15 sec", chain: "Anvil CBDC",       chainCls: "anvil" },
  { key: "confirmed", label: "Hub Relay Processing",    desc: "2-of-3 relayers signing — executing instruction",        eta: "~30 sec", chain: "Polygon Amoy",     chainCls: "amoy" },
  { key: "minted",    label: "Instruction Executed",    desc: "Instruction executed on Polygon Amoy",                   eta: null,      chain: "Polygon Amoy",     chainCls: "amoy",    txField: "mint" },
  { key: "completed", label: "Complete",                desc: "Token → Instruction bridge finished",                    eta: null },
];

const STEPS_ASSET_INSTRUCTION: StepDef[] = [
  { key: "init",      label: "Compliance Check + Lock", desc: "KYC/OFAC verified — approve ERC721 + lock asset",        eta: null,      chain: "Anvil CBDC",       chainCls: "anvil",   txField: "lock" },
  { key: "locked",    label: "Awaiting Confirmation",   desc: "Waiting for 3 block confirmations on local chain",       eta: "~15 sec", chain: "Anvil CBDC",       chainCls: "anvil" },
  { key: "confirmed", label: "Hub Relay Processing",    desc: "2-of-3 relayers signing — executing asset instruction",  eta: "~30 sec", chain: "Polygon Amoy",     chainCls: "amoy" },
  { key: "minted",    label: "Instruction Executed",    desc: "Asset instruction executed on Polygon Amoy",             eta: null,      chain: "Polygon Amoy",     chainCls: "amoy",    txField: "mint" },
  { key: "completed", label: "Complete",                desc: "Asset → Instruction bridge finished",                    eta: null },
];

const STEPS_ETH_TO_SOL: StepDef[] = [
  { key: "init",         label: "Lock on Ethereum",       desc: "Approve wCCC + lock in EthVault on Sepolia",            eta: null,      chain: "Eth Sepolia",      chainCls: "sepolia", txField: "lock" },
  { key: "locked",       label: "Awaiting Confirmation",  desc: "Waiting for 3 block confirmations on Sepolia",          eta: "~45 sec", chain: "Eth Sepolia",      chainCls: "sepolia" },
  { key: "hub_recorded", label: "Hub Indexed",            desc: "Relayer detected TokenLocked event on Sepolia",         eta: null,      chain: "BharatSetu Hub",   chainCls: "hub" },
  { key: "validating",   label: "Relayer Signing",        desc: "Relayer verifying lock proof — preparing Solana mint",  eta: "~10 sec", chain: "BharatSetu Hub",   chainCls: "hub" },
  { key: "consensus_b",  label: "Mint Authorized",        desc: "Relayer threshold met — submitting mint to Solana",     eta: null,      chain: "BharatSetu Hub",   chainCls: "hub" },
  { key: "minting_b",    label: "Minting on Solana",      desc: "mint_wrapped instruction sent to MintBridge program",   eta: "~10 sec", chain: "Solana Devnet",    chainCls: "solana" },
  { key: "committed_b",  label: "Solana Confirmed",       desc: "Wrapped SPL token minted to your Solana wallet",        eta: null,      chain: "Solana Devnet",    chainCls: "solana", txField: "mint" },
  { key: "completed",    label: "Complete",               desc: "ETH → SOL bridge transfer finished",                   eta: null },
];

const STEPS_SOL_TO_ETH: StepDef[] = [
  { key: "init",         label: "Lock on Solana",         desc: "Lock SPL token in LockVault program",                  eta: null,      chain: "Solana Devnet",    chainCls: "solana", txField: "lock" },
  { key: "hub_recorded", label: "Hub Indexed",            desc: "Hub indexer detected Solana lock event",               eta: null,      chain: "BharatSetu Hub",   chainCls: "hub" },
  { key: "validating",   label: "Relayer Signing",        desc: "Relayer verifying Solana lock proof",                  eta: "~30 sec", chain: "BharatSetu Hub",   chainCls: "hub" },
  { key: "consensus_b",  label: "Unlock Authorized",      desc: "Threshold met — submitting unlock to EthVault",        eta: null,      chain: "BharatSetu Hub",   chainCls: "hub" },
  { key: "minting_b",    label: "Unlocking on Ethereum",  desc: "EthVault releasing wCCC tokens to Sepolia wallet",     eta: "~15 sec", chain: "Eth Sepolia",      chainCls: "sepolia" },
  { key: "completed",    label: "Complete",               desc: "SOL → ETH bridge transfer finished",                   eta: null },
];

const CHANNEL_STATE_ORDER = ["init", "locked", "hub_recorded", "validating", "consensus_b", "minting_b", "committed_b", "committed_a", "completed", "rolling_back", "rolled_back"];
const STATE_ORDER = ["init", "locked", "confirmed", "minted", "completed"];

// A step is "done" only when the current state is strictly past it in the order.
// A step is "active" when it exactly matches current state.
// This prevents future steps from lighting up green prematurely.
function stepStatus(stepKey: string, currentState: string, channelMode = false): "done" | "active" | "pending" {
  const order = channelMode ? CHANNEL_STATE_ORDER : STATE_ORDER;
  const si = order.indexOf(stepKey);
  const ci = order.indexOf(currentState);
  if (ci === -1 || currentState === "failed" || currentState === "rolled_back") {
    return si === 0 ? "active" : "pending";
  }
  if (si < ci) return "done";
  if (si === ci) return "active";
  return "pending";
}

function truncate(addr: string) {
  return addr ? `${addr.slice(0, 6)}…${addr.slice(-4)}` : "";
}

function chainInfo(id: number) {
  if (id === 80002)    return { name: "Polygon Amoy",     cls: "amoy",    symbol: "POL" };
  if (id === 11155111) return { name: "Ethereum Sepolia", cls: "sepolia", symbol: "ETH" };
  if (id === 31337)    return { name: "Anvil (CBDC)",     cls: "anvil",   symbol: "ETH" };
  return { name: `Chain ${id}`, cls: "unknown", symbol: "?" };
}

export default function BridgePage() {
  const { address, isConnected } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const { sendTransactionAsync } = useSendTransaction();
  const publicClient = usePublicClient();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();

  const [step, setStep]               = useState<Step>("connect");
  const [fromChain, setFromChain]     = useState<ChainKey>("sepolia");
  const [toChain, setToChain]         = useState<ChainKey>("solana");
  const [cbdcMode, setCbdcMode]       = useState<"token" | "instruction" | "asset">("token");
  const [nftMode, setNftMode]         = useState(false);
  const direction: Direction = deriveDirection(fromChain, toChain, cbdcMode, nftMode);
  const [amount, setAmount]           = useState("");
  const [instructionPayload, setInstructionPayload] = useState("");
  const [assetContract, setAssetContract]           = useState("");
  const [assetTokenId, setAssetTokenId]             = useState("");
  const [transferId, setTransferId]   = useState<string | null>(null);
  const [transfer, setTransfer]       = useState<Transfer | null>(null);
  const [config, setConfig]           = useState<BridgeConfig | null>(null);
  const [error, setError]             = useState<string | null>(null);
  const [errorContext, setErrorContext] = useState<"login" | "tx">("tx");
  const [submitting, setSubmitting]   = useState(false);
  const [copied, setCopied]           = useState(false);
  const { connection } = useConnection();
  const { publicKey, connected: solConnected, sendTransaction: sendSolanaTransaction } = useWallet();
  const solanaAddress = publicKey?.toBase58() || "";
  const [elapsed, setElapsed]         = useState(0);
  const [startedAt, setStartedAt]     = useState<number | null>(null);
  const [visualState, setVisualState] = useState<string | null>(null); // simulated intermediate state
  const visualSimRef = useRef<ReturnType<typeof setTimeout>[]>([]);
  const transferDirectionRef = useRef<string>(direction); // tracks current transfer direction for WS closure — updated on each render
  // Keep ref in sync every render (cheap, no effect needed)
  transferDirectionRef.current = transfer?.direction ?? direction;

  useEffect(() => {
    let cancelled = false;
    const load = () => {
      getConfig()
        .then(({ data }) => { if (!cancelled) setConfig(data); })
        .catch(() => { if (!cancelled) setTimeout(load, 3000); }); // retry every 3s if Phoenix not ready
    };
    load();
    return () => { cancelled = true; };
  }, []);

  const isAnvilMode = direction === "cbdc_to_stablecoin" || direction === "token_to_instruction" || direction === "asset_to_instruction";

  const expectedChain =
    direction === "amoy_to_sepolia" ? (config?.amoy_chain_id ?? 80002) :
    isAnvilMode                     ? (config?.anvil_chain_id ?? 31337) :
    (config?.sepolia_chain_id ?? 11155111);

  const onWrongChain = step === "form" && !!config && chainId !== expectedChain;

  const tokenAddress = config
    ? (direction === "amoy_to_sepolia"                ? config.tccs_token
      : direction === "cbdc_to_stablecoin"            ? (config.mock_cbdc_token ?? "")
      : direction === "token_to_instruction"          ? (config.mock_cbdc_token ?? "")
      : direction === "asset_to_instruction"          ? undefined  // ERC721 — no ERC20 balance
      : direction === "eth_to_sol"                    ? (config.wccc_token ?? config.mint_bridge)  // wCCC on Sepolia = MintBridge
      : config.mint_bridge) as `0x${string}`
    : undefined;

  const { data: balanceData } = useBalance({
    address: address,
    token: tokenAddress,
    query: { enabled: !!address && !!tokenAddress && !onWrongChain },
  });

  const balanceFormatted = balanceData
    ? parseFloat(formatUnits(balanceData.value, balanceData.decimals)).toFixed(4)
    : null;

  const amountNum = parseFloat(amount) || 0;
  const insufficientBalance = !!balanceData && amountNum > 0
    && amountNum > parseFloat(formatUnits(balanceData.value, balanceData.decimals));
  const chain = chainInfo(chainId);
  const steps = direction === "amoy_to_sepolia"      ? STEPS_FORWARD
    : direction === "cbdc_to_stablecoin"              ? STEPS_CBDC
    : direction === "token_to_instruction"            ? STEPS_TOKEN_INSTRUCTION
    : direction === "asset_to_instruction"            ? STEPS_ASSET_INSTRUCTION
    : direction === "eth_to_sol"                      ? STEPS_ETH_TO_SOL
    : direction === "sol_to_eth"                      ? STEPS_SOL_TO_ETH
    : STEPS_REVERSE;

  const isChannelMode = direction === "eth_to_sol" || direction === "sol_to_eth" ||
                        direction === "eth_nft_to_sol" || direction === "sol_nft_to_eth";
  const channelStateOrder = CHANNEL_STATE_ORDER;

  // Restore in-progress transfer
  useEffect(() => {
    if (!isConnected) { setStep("connect"); return; }
    if (!isLoggedIn()) { setStep("login"); return; }
    const savedId = localStorage.getItem("activeTransferId");
    if (savedId) {
      getTransfer(savedId).then(({ data: t }) => {
        // If restored transfer is expired/failed with no lock tx, it's stale — skip it
        const isStale = t.state === "failed" && !t.lock_tx_hash && !t.mint_tx_hash;
        if (isStale) {
          localStorage.removeItem("activeTransferId");
          setStep("form");
          return;
        }
        clearSim();
        setVisualState(null);
        setTransferId(savedId);
        setTransfer(t);
        // Restore chain selectors from saved direction
        const dir = t.direction as Direction;
        if (dir === "amoy_to_sepolia")   { setFromChain("amoy");    setToChain("sepolia"); }
        else if (dir === "sepolia_to_amoy") { setFromChain("sepolia"); setToChain("amoy"); }
        else if (dir === "eth_to_sol" || dir === "eth_nft_to_sol") { setFromChain("sepolia"); setToChain("solana"); setNftMode(dir.includes("nft")); }
        else if (dir === "sol_to_eth" || dir === "sol_nft_to_eth") { setFromChain("solana");  setToChain("sepolia"); setNftMode(dir.includes("nft")); }
        else if (dir === "cbdc_to_stablecoin") { setFromChain("anvil"); setToChain("amoy"); setCbdcMode("token"); }
        else if (dir === "token_to_instruction") { setFromChain("anvil"); setToChain("amoy"); setCbdcMode("instruction"); }
        else if (dir === "asset_to_instruction") { setFromChain("anvil"); setToChain("amoy"); setCbdcMode("asset"); }
        setStep(t.state === "completed" || t.state === "failed" ? "done" : "pending");
        if (t.state === "completed" || t.state === "failed") localStorage.removeItem("activeTransferId");
      }).catch(() => { localStorage.removeItem("activeTransferId"); setStep("form"); });
    } else {
      setStep("form");
    }
  }, [isConnected]);

  // Stable refs — avoid recreating on every render
  const setVisualStateRef = useRef(setVisualState);
  setVisualStateRef.current = setVisualState;

  const clearSim = useRef(() => {
    visualSimRef.current.forEach(clearTimeout);
    visualSimRef.current = [];
  }).current;

  const runSim = useRef((states: string[], intervalMs: number) => {
    visualSimRef.current.forEach(clearTimeout);
    visualSimRef.current = [];
    setVisualStateRef.current(states[0]);
    states.slice(1).forEach((s, i) => {
      const t = setTimeout(() => setVisualStateRef.current(s), (i + 1) * intervalMs);
      visualSimRef.current.push(t);
    });
  }).current;

  // Real-time WebSocket updates
  useEffect(() => {
    if (!transferId) return;
    const token = localStorage.getItem("jwt") ?? "";
    return subscribeToTransfer(transferId, token, async (event) => {
      const state = (event as { state?: string }).state;
      if (!state) return;

      if (state === "completed" || state === "failed") {
        clearSim();
        setVisualState(null);
        try {
          const { data: fresh } = await getTransfer(transferId);
          setTransfer(fresh);
        } catch {
          setTransfer((prev) => prev ? { ...prev, state: state as Transfer["state"] } : null);
        }
        setStep("done");
        localStorage.removeItem("activeTransferId");

      } else if (state === "locked") {
        setTransfer((prev) => prev ? { ...prev, state: "locked" as Transfer["state"] } : null);
        const dir = transferDirectionRef.current;
        if (dir === "eth_to_sol" || dir === "sol_to_eth") {
          runSim(["locked", "hub_recorded", "validating", "consensus_b", "minting_b", "committed_b"], 1800);
        }

      } else {
        setTransfer((prev) => prev ? { ...prev, state: state as Transfer["state"] } : null);
      }
    });
  }, [transferId]); // eslint-disable-line react-hooks/exhaustive-deps

  // Elapsed timer
  useEffect(() => {
    if (step !== "pending") { setElapsed(0); setStartedAt(null); return; }
    if (!startedAt) setStartedAt(Date.now());
    const id = setInterval(() => setElapsed(Math.floor((Date.now() - (startedAt ?? Date.now())) / 1000)), 1000);
    return () => clearInterval(id);
  }, [step, startedAt]);

  // Poll every 3s — fallback when WS misses events; does NOT touch visualState (avoids restart loop)
  useEffect(() => {
    if (step !== "pending" || !transferId) return;
    const poll = setInterval(async () => {
      try {
        const { data: t } = await getTransfer(transferId);

        if (t.state === "completed" || t.state === "failed") {
          clearSim();
          setVisualState(null);
          setTransfer(t);
          setStep("done");
          localStorage.removeItem("activeTransferId");
          return;
        }

        // Update transfer from DB — trust DB state for progress
        setTransfer(t);

        // If sim hasn't started (no WS) and DB is past init, kick off sim
        setVisualState((vis) => {
          if (vis !== null) return vis; // sim already running
          const isChannel = t.direction === "eth_to_sol" || t.direction === "sol_to_eth";
          if (isChannel && (t.state === "locked" || t.state === "hub_recorded" || t.state === "confirmed")) {
            runSim(["locked", "hub_recorded", "validating", "consensus_b", "minting_b", "committed_b"], 1800);
          }
          return vis;
        });
      } catch { /* ignore */ }
    }, 3000);
    return () => clearInterval(poll);
    // clearSim and runSim are stable refs — safe to omit
  }, [step, transferId]); // eslint-disable-line react-hooks/exhaustive-deps

  const handleLogin = async () => {
    if (!address) return;
    try {
      await siweLogin(address, (msg) => signMessageAsync({ account: address, message: msg }));
      setStep("form");
    } catch (e) {
      const msg = (e as Error).message;
      setErrorContext("login");
      setError(msg === "Failed to fetch" ? "Cannot reach the backend server. Make sure it is running." : msg);
      setStep("error");
    }
  };

  const handleSubmit = async () => {
    if (!config) return;
    setSubmitting(true);
    setError(null);

    const sessionId = `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    const log = (step: string, data?: unknown) => {
      const payload = { session: sessionId, step, direction, chainId, wallet: address, ...((data && typeof data === "object") ? data : { data }) };
      console.log(`[Bridge][${step}]`, payload);
      fetch("/api/bridge-log", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) }).catch(() => {});
    };

    const { lock_bridge, mint_bridge, tccs_token, wccc_token, cbdc_vault, asset_vault, mock_cbdc_token, mock_asset_contract, eth_vault, nft_vault } = config;
    const wccc = wccc_token ?? mint_bridge;  // wCCC on Sepolia = MintBridge contract

    try {
      const sourceToken = direction === "asset_to_instruction"
        ? (mock_asset_contract ?? "")
        : direction === "cbdc_to_stablecoin" || direction === "token_to_instruction"
          ? (mock_cbdc_token ?? "")
          : direction === "eth_to_sol"
            ? wccc
            : tccs_token;

      const extra = direction === "token_to_instruction"
        ? { instruction_payload: instructionPayload }
        : direction === "asset_to_instruction"
          ? { asset_contract: assetContract || (mock_asset_contract ?? ""), asset_token_id: assetTokenId, instruction_payload: instructionPayload }
          : undefined;

      log("transfer:creating", { sourceToken, amount, direction });
      const { data } = await createTransfer(sourceToken, amount, direction, extra);
      log("transfer:created", { transferId: data.id, state: data.state });
      setTransferId(data.id);
      localStorage.setItem("activeTransferId", data.id);
      clearSim();
      setVisualState(null);
      setTransfer({ id: data.id, state: "init", direction, wallet: address!, token_address: sourceToken, amount, nonce_hash: "", compliance_status: "approved", source_chain: null, dest_chain: null, transfer_type: null, instruction_payload: null, asset_contract: null, asset_token_id: null, lock_tx_hash: null, mint_tx_hash: null, failure_reason: null, channel_id: null, cross_chain_id: null, solana_signature: null, solana_mint_sig: null, nft_metadata_uri: null, commit_tx_b: null, rollback_reason: null, inserted_at: "" });
      setStep("pending");

      const amountWei = BigInt(Math.floor(parseFloat(amount) * 10 ** 18));
      const transferIdBytes = `0x${data.id.replace(/-/g, "").padEnd(64, "0")}` as `0x${string}`;

      if (direction === "amoy_to_sepolia") {
        const fees = { gas: BigInt(120000), maxFeePerGas: BigInt(100_000_000_000), maxPriorityFeePerGas: BigInt(50_000_000_000) };
        const approveTx = await sendTransactionAsync({
          to: tccs_token as `0x${string}`,
          data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [lock_bridge as `0x${string}`, amountWei] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx, confirmations: 1, timeout: 180_000 });
        const txHash = await sendTransactionAsync({
          to: lock_bridge as `0x${string}`,
          data: encodeFunctionData({ abi: LOCK_BRIDGE_ABI, functionName: "lockTokens", args: [tccs_token as `0x${string}`, amountWei, transferIdBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1, timeout: 180_000 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);

      } else if (direction === "cbdc_to_stablecoin") {
        const fees = { gas: BigInt(150000) };
        const approveTx = await sendTransactionAsync({
          to: mock_cbdc_token as `0x${string}`,
          data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [cbdc_vault as `0x${string}`, amountWei] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx, confirmations: 1, timeout: 180_000 });
        const txHash = await sendTransactionAsync({
          to: cbdc_vault as `0x${string}`,
          data: encodeFunctionData({ abi: LOCK_CBDC_ABI, functionName: "lockCBDC", args: [amountWei, transferIdBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1, timeout: 180_000 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);

      } else if (direction === "token_to_instruction") {
        const fees = { gas: BigInt(200000) };
        const payloadBytes = instructionPayload.startsWith("0x")
          ? instructionPayload as `0x${string}`
          : `0x${Buffer.from(instructionPayload).toString("hex")}` as `0x${string}`;
        const approveTx = await sendTransactionAsync({
          to: mock_cbdc_token as `0x${string}`,
          data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [cbdc_vault as `0x${string}`, amountWei] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx, confirmations: 1, timeout: 180_000 });
        const txHash = await sendTransactionAsync({
          to: cbdc_vault as `0x${string}`,
          data: encodeFunctionData({ abi: LOCK_CBDC_INSTRUCTION_ABI, functionName: "lockCBDCWithInstruction", args: [amountWei, transferIdBytes, payloadBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1, timeout: 180_000 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);

      } else if (direction === "asset_to_instruction") {
        const fees = { gas: BigInt(200000) };
        const tokenContract = (assetContract || mock_asset_contract) as `0x${string}`;
        const tokenId = BigInt(assetTokenId || 0);
        const payloadBytes = instructionPayload.startsWith("0x")
          ? instructionPayload as `0x${string}`
          : `0x${Buffer.from(instructionPayload).toString("hex")}` as `0x${string}`;
        const approveTx = await sendTransactionAsync({
          to: tokenContract,
          data: encodeFunctionData({ abi: ERC721_APPROVE_ABI, functionName: "approve", args: [asset_vault as `0x${string}`, tokenId] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx, confirmations: 1, timeout: 180_000 });
        const txHash = await sendTransactionAsync({
          to: asset_vault as `0x${string}`,
          data: encodeFunctionData({ abi: LOCK_ASSET_ABI, functionName: "lockAsset", args: [tokenContract, tokenId, transferIdBytes, payloadBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1, timeout: 180_000 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);

      } else if (direction === "eth_to_sol") {
        // Lock wCCC in EthVault on Sepolia, relayer mints wrapped SPL on Solana
        if (!eth_vault) throw new Error("ETH_VAULT_CONTRACT not configured");
        const fees = { gas: BigInt(300000), maxFeePerGas: BigInt(5_000_000_000), maxPriorityFeePerGas: BigInt(1_000_000_000) };
        // keccak256(transferId + timestamp) → unique per attempt, avoids AlreadyLocked
        const crossChainIdBytes = keccak256(concat([toBytes(data.id), toBytes(Date.now().toString())]));
        // decode base58 Solana pubkey → raw 32 bytes
        const solPubkeyBytes = solanaAddress ? bs58.decode(solanaAddress) : new Uint8Array(32);
        const destWalletBytes = `0x${Buffer.from(solPubkeyBytes).toString("hex").padStart(64, "0")}` as `0x${string}`;
        const timeoutSec = BigInt(3600); // 1 hour

        log("eth_to_sol:params", {
          wccc, eth_vault, amountWei: amountWei.toString(), crossChainIdBytes,
          destWalletBytes, solanaAddress, chainId,
          fees: { gas: 150000, maxFeePerGas: "5gwei", maxPriorityFeePerGas: "1gwei" },
        });

        log("approve:sending", { to: wccc, spender: eth_vault, amount: amountWei.toString() });
        let approveTx: `0x${string}`;
        try {
          approveTx = await sendTransactionAsync({
            to: wccc as `0x${string}`,
            data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [eth_vault as `0x${string}`, amountWei] }),
            ...fees,
          });
          log("approve:sent", { hash: approveTx });
        } catch (err) {
          log("approve:send_failed", { error: String(err), message: (err as Error).message });
          throw err;
        }

        log("approve:waiting_receipt", { hash: approveTx, confirmations: 2 });
        let approveReceipt: Awaited<ReturnType<typeof publicClient.waitForTransactionReceipt>>;
        try {
          approveReceipt = await publicClient!.waitForTransactionReceipt({ hash: approveTx, confirmations: 2, timeout: 180_000 });
          log("approve:confirmed", { hash: approveTx, status: approveReceipt.status, blockNumber: approveReceipt.blockNumber?.toString(), gasUsed: approveReceipt.gasUsed?.toString() });
        } catch (err) {
          log("approve:receipt_failed", { hash: approveTx, error: String(err) });
          throw err;
        }

        if (approveReceipt.status !== "success") {
          log("approve:reverted", { hash: approveTx, receipt: approveReceipt });
          throw new Error(`Approve tx reverted: ${approveTx}`);
        }

        log("lock:sending", { to: eth_vault, token: wccc, amount: amountWei.toString(), crossChainIdBytes, destWalletBytes, timeoutSec: timeoutSec.toString() });
        let txHash: `0x${string}`;
        try {
          txHash = await sendTransactionAsync({
            to: eth_vault as `0x${string}`,
            data: encodeFunctionData({ abi: ETH_VAULT_LOCK_ABI, functionName: "lock", args: [wccc as `0x${string}`, amountWei, crossChainIdBytes, destWalletBytes, timeoutSec] }),
            ...fees,
          });
          log("lock:sent", { hash: txHash });
        } catch (err) {
          log("lock:send_failed", { error: String(err), message: (err as Error).message });
          throw err;
        }

        log("lock:waiting_receipt", { hash: txHash, confirmations: 1 });
        let lockReceipt: Awaited<ReturnType<typeof publicClient.waitForTransactionReceipt>>;
        try {
          lockReceipt = await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1, timeout: 180_000 });
          log("lock:confirmed", { hash: txHash, status: lockReceipt.status, blockNumber: lockReceipt.blockNumber?.toString(), gasUsed: lockReceipt.gasUsed?.toString(), logs: lockReceipt.logs?.length });
        } catch (err) {
          log("lock:receipt_failed", { hash: txHash, error: String(err) });
          throw err;
        }

        if (lockReceipt.status !== "success") {
          log("lock:reverted", { hash: txHash, receipt: { status: lockReceipt.status, blockNumber: lockReceipt.blockNumber?.toString() } });
          throw new Error(`Lock tx reverted (status=0x0): ${txHash}`);
        }

        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        log("backend:confirm_lock", { transferId: data.id, txHash, crossChainIdBytes });
        await confirmLock(data.id, txHash, crossChainIdBytes);
        log("backend:confirm_lock_done", { transferId: data.id });

      } else {
        const fees = { gas: BigInt(80000), maxFeePerGas: BigInt(5_000_000_000), maxPriorityFeePerGas: BigInt(1_000_000_000) };
        const txHash = await sendTransactionAsync({
          to: mint_bridge as `0x${string}`,
          data: encodeFunctionData({ abi: BURN_BRIDGE_ABI, functionName: "burnAndBridge", args: [amountWei, transferIdBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1, timeout: 180_000 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);
      }

      const { data: t } = await getTransfer(data.id);
      setTransfer(t);
    } catch (e) {
      log("fatal_error", { error: String(e), message: (e as Error).message, stack: (e as Error).stack?.slice(0, 500) });
      console.error("[Bridge] ERROR", e);
      localStorage.removeItem("activeTransferId");
      setErrorContext("tx");
      const msg = (e as Error).message;
      setError(
        msg === "ofac_blocked" ? "This wallet is on the OFAC sanctions list and cannot use this bridge." :
        msg === "kyc_required" ? "KYC verification required. Your wallet has not been verified. Contact support." :
        msg
      );
      setStep("error");
    } finally {
      setSubmitting(false);
    }
  };

  const reset = () => {
    clearSim();
    setVisualState(null);
    localStorage.removeItem("activeTransferId");
    setStep("form"); setTransfer(null); setTransferId(null);
    setAmount(""); setInstructionPayload(""); setAssetContract(""); setAssetTokenId("");
    setError(null);
  };

  const handleCancel = async () => {
    if (!transferId) return;
    try {
      await cancelTransfer(transferId);
      reset();
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const handleRetry = async () => {
    if (!transferId) return;
    try {
      await retryTransfer(transferId);
      setTransfer((prev) => prev ? { ...prev, state: "confirmed", failure_reason: null } : null);
      setStep("pending");
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const explorerUrl = (dir: Direction, type: "lock" | "mint", hash: string): string => {
    if (type === "lock") {
      if (dir === "amoy_to_sepolia") return `https://amoy.polygonscan.com/tx/${hash}`;
      if (dir === "sol_to_eth")      return `https://explorer.solana.com/tx/${hash}?cluster=devnet`;
      return `https://sepolia.etherscan.io/tx/${hash}`;  // eth_to_sol, sepolia_to_amoy
    }
    if (dir === "amoy_to_sepolia")  return `https://sepolia.etherscan.io/tx/${hash}`;
    if (dir === "eth_to_sol")       return `https://explorer.solana.com/tx/${hash}?cluster=devnet`;
    if (dir === "sol_to_eth")       return `https://sepolia.etherscan.io/tx/${hash}`;
    return `https://amoy.polygonscan.com/tx/${hash}`;
  };

  const lockTxLabel = (dir: Direction) => {
    if (dir === "amoy_to_sepolia") return "Lock Tx";
    if (dir === "eth_to_sol")      return "Lock Tx (Sepolia)";
    if (dir === "sol_to_eth")      return "Lock Tx (Solana)";
    return "Burn Tx";
  };

  const mintTxLabel = (dir: Direction) => {
    if (dir === "amoy_to_sepolia") return "Mint Tx";
    if (dir === "eth_to_sol")      return "Mint Tx (Solana)";
    if (dir === "sol_to_eth")      return "Unlock Tx (Sepolia)";
    return "Unlock Tx";
  };

  const completionMsg = (t: Transfer) => {
    if (t.direction === "amoy_to_sepolia")    return `${t.amount} wCCC minted to your wallet on Sepolia.`;
    if (t.direction === "cbdc_to_stablecoin") return `${t.amount} INRX minted to your wallet on Polygon Amoy. CBDC locked in vault.`;
    if (t.direction === "eth_to_sol")         return `${t.amount} wCCC locked on Sepolia — wrapped SPL token minted to your Solana wallet.`;
    if (t.direction === "sol_to_eth")         return `${t.amount} wCCC unlocked to your wallet on Sepolia.`;
    return `${t.amount} tCCS unlocked to your wallet on Amoy.`;
  };

  return (
    <div className="page">
      <div className="page-title">Cross-Chain Bridge</div>
      <div className="page-subtitle">Move carbon credits across blockchains, trustlessly</div>

      {/* ── Step 1: Connect ── */}
      {step === "connect" && (
        <div className="card">
          <div className="card-title">
            <span style={{ color: "var(--primary)" }}>01</span> Connect Wallet
          </div>
          <p className="text-muted text-sm" style={{ marginBottom: "1.25rem" }}>
            Connect your MetaMask or WalletConnect wallet to get started.
          </p>
          <ConnectButton />
        </div>
      )}

      {/* ── Step 2: Login ── */}
      {step === "login" && (
        <div className="card" style={{ textAlign: "center" }}>
          <div style={{ fontSize: "2rem", marginBottom: "0.5rem" }}>🔐</div>
          <div className="card-title" style={{ justifyContent: "center" }}>Authenticate</div>
          <p className="text-muted text-sm" style={{ marginBottom: "1.5rem" }}>
            Sign a free off-chain message to prove wallet ownership.<br />No gas, no transaction.
          </p>

          <div style={{
            display: "inline-flex", alignItems: "center", gap: "0.6rem",
            background: "var(--surface2)", border: "1px solid var(--border)",
            borderRadius: 10, padding: "0.6rem 1rem", marginBottom: "1.5rem",
          }}>
            <span style={{ width: 8, height: 8, borderRadius: "50%", background: "var(--primary)", display: "inline-block" }} />
            <span style={{ fontFamily: "monospace", fontSize: "0.88rem" }}>{truncate(address ?? "")}</span>
          </div>

          <div>
            <button className="btn-primary" style={{ width: "100%" }} onClick={handleLogin}>
              Sign with Ethereum
            </button>
            <p style={{ fontSize: "0.72rem", color: "var(--muted)", marginTop: "0.75rem" }}>
              EIP-4361 · SIWE standard · read-only signature
            </p>
          </div>
        </div>
      )}

      {/* ── Step 3: Form ── */}
      {step === "form" && (
        <div className="card">
          <div className="card-title">
            <span style={{ color: "var(--primary)" }}>03</span> Bridge Tokens
          </div>

          {/* Wallet status */}
          <div className="wallet-bar">
            <div className="wallet-address">{truncate(address ?? "")}</div>
            <div className={`chain-badge ${chain.cls}`}>
              <span className="chain-dot" />
              {chain.name}
            </div>
            <span className="text-muted text-sm" style={{ marginLeft: "auto", fontSize: "0.75rem" }}>
              {isLoggedIn() ? <span style={{ color: "var(--primary)" }}>● Authenticated</span> : "Not signed in"}
            </span>
          </div>

          {/* ── Unified Chain Selector ── */}
          {(() => {
            const validDests = VALID_DEST[fromChain];
            const canSwap = VALID_DEST[toChain]?.includes(fromChain);

            const ChainPill = ({ ck, role }: { ck: ChainKey; role: "from" | "to" }) => {
              const m = CHAIN_META[ck];
              const clsBg: Record<string, string> = {
                amoy:    "rgba(130,80,255,0.12)",
                sepolia: "rgba(100,130,255,0.12)",
                anvil:   "rgba(255,165,0,0.12)",
                solana:  "rgba(150,80,255,0.12)",
              };
              const clsText: Record<string, string> = {
                amoy:    "#a060ff",
                sepolia: "#8080ff",
                anvil:   "#ffa040",
                solana:  "#c060ff",
              };
              return (
                <div style={{
                  flex: 1, padding: "0.75rem 1rem", borderRadius: 10,
                  background: clsBg[ck], border: `1.5px solid ${clsText[ck]}40`,
                }}>
                  <div style={{ fontSize: "0.65rem", color: "var(--muted)", fontWeight: 600, marginBottom: 4, textTransform: "uppercase", letterSpacing: "0.05em" }}>
                    {role === "from" ? "From" : "To"}
                  </div>
                  <div style={{ fontSize: "0.92rem", fontWeight: 700, color: clsText[ck] }}>{m.label}</div>
                  <div style={{ fontSize: "0.72rem", color: "var(--muted)", marginTop: 2 }}>{m.sub}</div>
                </div>
              );
            };

            // All 4 chains as source options
            const ALL_CHAINS: ChainKey[] = ["sepolia", "solana", "anvil", "amoy"];

            return (
              <div style={{ marginBottom: "1rem" }}>
                {/* From / To display with swap button */}
                <div style={{ display: "flex", alignItems: "stretch", gap: 10, marginBottom: "0.75rem" }}>
                  <ChainPill ck={fromChain} role="from" />
                  <div style={{ display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 3 }}>
                    <button
                      onClick={() => {
                        if (canSwap) { setFromChain(toChain); setToChain(fromChain); }
                      }}
                      title={canSwap ? "Swap direction" : "Direction not reversible"}
                      style={{
                        background: canSwap ? "var(--surface2)" : "var(--surface)",
                        border: `1px solid ${canSwap ? "var(--primary)" : "var(--border)"}`,
                        borderRadius: 8, cursor: canSwap ? "pointer" : "default",
                        fontSize: "1.1rem", color: canSwap ? "var(--primary)" : "var(--border)",
                        padding: "0.3rem 0.45rem", lineHeight: 1,
                      }}
                    >⇄</button>
                    {(fromChain === "anvil" || fromChain === "sepolia") && (
                      <span style={{ fontSize: "0.58rem", color: "var(--muted)", whiteSpace: "nowrap" }}>Hub</span>
                    )}
                  </div>
                  <ChainPill ck={toChain} role="to" />
                </div>

                {/* Source chain selector */}
                <div style={{ marginBottom: "0.5rem" }}>
                  <div style={{ fontSize: "0.68rem", color: "var(--muted)", fontWeight: 600, marginBottom: "0.35rem", textTransform: "uppercase", letterSpacing: "0.05em" }}>
                    Source Chain
                  </div>
                  <div style={{ display: "flex", gap: "0.4rem", flexWrap: "wrap" }}>
                    {ALL_CHAINS.map((ck) => {
                      const m = CHAIN_META[ck];
                      const active = fromChain === ck;
                      return (
                        <button key={ck} onClick={() => {
                          setFromChain(ck);
                          const dests = VALID_DEST[ck];
                          if (!dests.includes(toChain)) setToChain(dests[0]);
                        }} style={{
                          padding: "0.3rem 0.7rem", borderRadius: 6, cursor: "pointer",
                          fontSize: "0.75rem", fontWeight: active ? 700 : 400,
                          background: active ? "var(--primary)" : "var(--surface2)",
                          color: active ? "#000" : "var(--muted)",
                          border: `1px solid ${active ? "var(--primary)" : "var(--border)"}`,
                        }}>
                          {m.label}
                        </button>
                      );
                    })}
                  </div>
                </div>

                {/* Destination chain selector */}
                <div style={{ marginBottom: validDests.length > 1 ? "0.5rem" : 0 }}>
                  <div style={{ fontSize: "0.68rem", color: "var(--muted)", fontWeight: 600, marginBottom: "0.35rem", textTransform: "uppercase", letterSpacing: "0.05em" }}>
                    Destination Chain
                  </div>
                  <div style={{ display: "flex", gap: "0.4rem", flexWrap: "wrap" }}>
                    {validDests.map((ck) => {
                      const m = CHAIN_META[ck];
                      const active = toChain === ck;
                      return (
                        <button key={ck} onClick={() => setToChain(ck)} style={{
                          padding: "0.3rem 0.7rem", borderRadius: 6, cursor: "pointer",
                          fontSize: "0.75rem", fontWeight: active ? 700 : 400,
                          background: active ? "var(--primary)" : "var(--surface2)",
                          color: active ? "#000" : "var(--muted)",
                          border: `1px solid ${active ? "var(--primary)" : "var(--border)"}`,
                        }}>
                          {m.label}
                        </button>
                      );
                    })}
                  </div>
                </div>

                {/* CBDC sub-mode — only when Anvil→Amoy */}
                {fromChain === "anvil" && toChain === "amoy" && (
                  <div style={{ marginTop: "0.5rem" }}>
                    <div style={{ fontSize: "0.68rem", color: "var(--muted)", fontWeight: 600, marginBottom: "0.35rem", textTransform: "uppercase", letterSpacing: "0.05em" }}>
                      Bridge Type
                    </div>
                    <div style={{ display: "flex", gap: "0.4rem" }}>
                      {([
                        { key: "token",       label: "Token → Token",       sub: "INRDC → INRX" },
                        { key: "instruction", label: "Token → Instruction",  sub: "CBDC + payload" },
                        { key: "asset",       label: "Asset → Instruction",  sub: "ERC721 + payload" },
                      ] as { key: typeof cbdcMode; label: string; sub: string }[]).map(({ key, label }) => (
                        <button key={key} onClick={() => setCbdcMode(key)} style={{
                          flex: 1, padding: "0.3rem 0.5rem", borderRadius: 6, cursor: "pointer",
                          fontSize: "0.7rem", fontWeight: cbdcMode === key ? 700 : 400,
                          background: cbdcMode === key ? "var(--primary)" : "var(--surface2)",
                          color: cbdcMode === key ? "#000" : "var(--muted)",
                          border: `1px solid ${cbdcMode === key ? "var(--primary)" : "var(--border)"}`,
                          textAlign: "center",
                        }}>{label}</button>
                      ))}
                    </div>
                  </div>
                )}

                {/* NFT toggle — only Sepolia ↔ Solana */}
                {((fromChain === "sepolia" && toChain === "solana") || (fromChain === "solana" && toChain === "sepolia")) && (
                  <div style={{ marginTop: "0.5rem", display: "flex", alignItems: "center", gap: 10 }}>
                    <div style={{ fontSize: "0.68rem", color: "var(--muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: "0.05em" }}>
                      Asset Type
                    </div>
                    <div style={{ display: "flex", gap: "0.4rem" }}>
                      {[false, true].map((isNft) => (
                        <button key={String(isNft)} onClick={() => setNftMode(isNft)} style={{
                          padding: "0.25rem 0.65rem", borderRadius: 6, cursor: "pointer",
                          fontSize: "0.72rem", fontWeight: nftMode === isNft ? 700 : 400,
                          background: nftMode === isNft ? "var(--primary)" : "var(--surface2)",
                          color: nftMode === isNft ? "#000" : "var(--muted)",
                          border: `1px solid ${nftMode === isNft ? "var(--primary)" : "var(--border)"}`,
                        }}>
                          {isNft ? "NFT" : "Fungible Token"}
                        </button>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            );
          })()}

          {/* Wrong chain warning + auto-switch */}
          {onWrongChain && (
            <div className="warning-banner" style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <span>⚠ Switch to <strong>{CHAIN_META[fromChain].label}</strong></span>
              <button
                className="btn-secondary"
                style={{ padding: "0.3rem 0.9rem", fontSize: "0.8rem" }}
                onClick={() => switchChain({ chainId: expectedChain })}
              >
                Switch Network
              </button>
            </div>
          )}

          {/* Solana destination address — ETH→SOL only */}
          {(direction === "eth_to_sol" || direction === "eth_nft_to_sol") && (
            <div className="input-group" style={{ marginBottom: "0.75rem" }}>
              <div className="input-label" style={{ display: "flex", justifyContent: "space-between" }}>
                <span>Recipient Wallet ({CHAIN_META[toChain].label})</span>
                {toChain === "solana" && (
                  <div className="solana-adapter-wrapper">
                    <WalletMultiButton />
                  </div>
                )}
              </div>
              <div style={{ position: "relative" }}>
                <input
                  type="text"
                  className="input-field"
                  placeholder={toChain === "solana" ? "Connect Phantom wallet →" : "0x…"}
                  value={solanaAddress}
                  readOnly={toChain === "solana"}
                  style={{ paddingLeft: "0.75rem", background: toChain === "solana" ? "var(--surface2)" : "var(--surface)", width: "100%", boxSizing: "border-box" }}
                />
                {toChain === "solana" && !solConnected && (
                  <div style={{
                    position: "absolute", top: 0, left: 0, right: 0, bottom: 0,
                    display: "flex", alignItems: "center", justifyContent: "center",
                    background: "rgba(0,0,0,0.05)", borderRadius: 12, cursor: "pointer",
                    fontSize: "0.85rem", color: "var(--primary)"
                  }} onClick={() => (document.querySelector(".wallet-adapter-button") as HTMLButtonElement)?.click()}>
                    Connect Solana Wallet
                  </div>
                )}
              </div>
            </div>
          )}

          {/* Amount */}
          <div className="amount-wrap">
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <div className="amount-label">Amount to bridge</div>
              {balanceFormatted !== null && (
                <div style={{ fontSize: "0.75rem", color: "var(--muted)" }}>
                  Balance: <span style={{ color: "var(--text)" }}>{balanceFormatted}</span>
                  {" "}
                  <button
                    className="btn-secondary"
                    style={{ padding: "0.1rem 0.5rem", fontSize: "0.7rem", marginLeft: 4 }}
                    onClick={() => setAmount(formatUnits(balanceData!.value, balanceData!.decimals))}
                  >
                    Max
                  </button>
                </div>
              )}
            </div>
            <input
              className={`amount-input${insufficientBalance ? " input-error" : ""}`}
              type="number"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder="0"
            />
            <span className="amount-token">
              {direction === "amoy_to_sepolia" ? "tCCS"
                : direction === "cbdc_to_stablecoin" || direction === "token_to_instruction" ? "INRDC"
                : direction === "asset_to_instruction" ? "N/A"
                : "wCCC"}
            </span>
          </div>
          {insufficientBalance && (
            <div style={{ color: "var(--red)", fontSize: "0.78rem", marginTop: "-0.75rem", marginBottom: "0.75rem" }}>
              Insufficient balance
            </div>
          )}

          {/* Asset fields — Asset→Instruction mode */}
          {direction === "asset_to_instruction" && (
            <div style={{ marginBottom: "1rem" }}>
              <div className="amount-label" style={{ marginBottom: "0.4rem" }}>Asset Contract (ERC721)</div>
              <input
                className="amount-input"
                style={{ fontSize: "0.82rem" }}
                type="text"
                value={assetContract}
                onChange={(e) => setAssetContract(e.target.value)}
                placeholder={config?.mock_asset_contract ?? "0x… (leave blank for MockAsset)"}
              />
              <div className="amount-label" style={{ marginTop: "0.75rem", marginBottom: "0.4rem" }}>Token ID</div>
              <input
                className="amount-input"
                type="number"
                value={assetTokenId}
                onChange={(e) => setAssetTokenId(e.target.value)}
                placeholder="0"
              />
            </div>
          )}

          {/* Instruction payload — Token→Instruction and Asset→Instruction */}
          {(direction === "token_to_instruction" || direction === "asset_to_instruction") && (
            <div style={{ marginBottom: "1rem" }}>
              <div className="amount-label" style={{ marginBottom: "0.4rem" }}>
                Instruction Payload
                <span style={{ fontWeight: 400, color: "var(--muted)", marginLeft: 6, fontSize: "0.72rem" }}>
                  hex (0x…) or UTF-8 text
                </span>
              </div>
              <textarea
                style={{
                  width: "100%", minHeight: 80, padding: "0.5rem 0.75rem",
                  background: "var(--surface2)", border: "1px solid var(--border)",
                  borderRadius: 8, color: "var(--text)", fontSize: "0.8rem",
                  fontFamily: "monospace", resize: "vertical", boxSizing: "border-box",
                }}
                value={instructionPayload}
                onChange={(e) => setInstructionPayload(e.target.value)}
                placeholder='e.g. {"action":"settle","tradeId":"T-001"} or 0xdeadbeef'
              />
            </div>
          )}

          {!config && <p className="text-muted text-sm" style={{ marginBottom: "1rem" }}>Loading config…</p>}

          <button
            className="btn-primary"
            onClick={handleSubmit}
            disabled={(!amount && direction !== "asset_to_instruction") || !config || onWrongChain || insufficientBalance || submitting}
          >
            {submitting
              ? <span style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8 }}>
                  <span className="spinner" /> Processing…
                </span>
              : direction === "amoy_to_sepolia"       ? "Lock & Bridge →"
              : direction === "cbdc_to_stablecoin"    ? "Lock CBDC & Convert →"
              : direction === "token_to_instruction"  ? "Lock CBDC + Submit Instruction →"
              : direction === "asset_to_instruction"  ? "Lock Asset + Submit Instruction →"
              : direction === "eth_to_sol"            ? "Lock & Bridge →"
              : direction === "eth_nft_to_sol"        ? "Lock NFT & Bridge →"
              : "Burn & Bridge →"
            }
          </button>
        </div>
      )}

      {/* ── Pending ── */}
      {step === "pending" && transfer && (() => {
        const dir = transfer.direction as Direction;
        const isChannel = isChannelMode;
        // Use visualState for step rendering — gives smooth incremental progress
        // Fall back to real transfer.state if no sim running
        const displayState = visualState ?? transfer.state;
        const pct = stateProgressPct(displayState, steps);
        const activeStep = steps.find(s => stepStatus(s.key, displayState, isChannel) === "active");
        const elapsedStr = elapsed > 0
          ? elapsed < 60 ? `${elapsed}s` : `${Math.floor(elapsed / 60)}m ${elapsed % 60}s`
          : null;

        return (
        <div className="card" style={{ padding: 0, overflow: "hidden" }}>
          {/* Header */}
          <div style={{
            padding: "1.25rem 1.5rem 1rem",
            background: "linear-gradient(135deg, rgba(0,255,135,0.06) 0%, rgba(0,180,255,0.04) 100%)",
            borderBottom: "1px solid var(--border)",
          }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: "0.75rem" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <span className="spinner" style={{ width: 16, height: 16 }} />
                <span style={{ fontWeight: 700, fontSize: "1rem" }}>Transfer in Progress</span>
              </div>
              <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                {elapsedStr && (
                  <span style={{ fontSize: "0.72rem", color: "var(--muted)", fontVariantNumeric: "tabular-nums" }}>
                    ⏱ {elapsedStr}
                  </span>
                )}
                <span style={{
                  fontSize: "0.72rem", fontWeight: 600, padding: "2px 8px",
                  borderRadius: 99, background: "rgba(0,255,135,0.12)", color: "var(--primary)",
                  border: "1px solid rgba(0,255,135,0.3)",
                }}>
                  LIVE
                </span>
              </div>
            </div>

            {/* Progress bar */}
            <div style={{ position: "relative" }}>
              <div className="progress-bar" style={{ height: 6 }}>
                <div className="progress-fill" style={{ width: `${pct}%`, transition: "width 0.8s ease" }} />
              </div>
              <div style={{ display: "flex", justifyContent: "space-between", marginTop: 5, fontSize: "0.65rem", color: "var(--muted)" }}>
                {steps.map(s => (
                  <span key={s.key} style={{
                    color: stepStatus(s.key, displayState, isChannel) !== "pending" ? "var(--primary)" : "var(--muted)",
                    fontWeight: stepStatus(s.key, displayState, isChannel) === "active" ? 700 : 400,
                    transition: "color 0.3s",
                  }}>
                    {s.label.split(" ")[0]}
                  </span>
                ))}
              </div>
            </div>

            {/* Active step callout */}
            {activeStep && (
              <div style={{
                marginTop: "0.75rem", padding: "0.5rem 0.75rem",
                background: "rgba(0,255,135,0.06)", borderRadius: 8,
                border: "1px solid rgba(0,255,135,0.2)",
                fontSize: "0.78rem", display: "flex", alignItems: "center", gap: 8,
              }}>
                <span style={{ color: "var(--primary)" }}>▶</span>
                <span style={{ color: "var(--text)" }}><strong>{activeStep.label}</strong> — {activeStep.desc}</span>
                {activeStep.eta && (
                  <span style={{ marginLeft: "auto", color: "var(--primary)", whiteSpace: "nowrap", fontSize: "0.7rem" }}>
                    ETA {activeStep.eta}
                  </span>
                )}
              </div>
            )}
          </div>

          {/* Step list */}
          <div style={{ padding: "1rem 1.5rem" }}>
            <div className="stepper">
              {steps.map((s) => {
                const status = transfer.state === "failed" && s.key === "init"
                  ? "active"
                  : stepStatus(s.key, displayState, isChannel);
                const txHash = s.txField === "lock" ? transfer.lock_tx_hash : s.txField === "mint" ? transfer.mint_tx_hash : null;
                const txUrl  = txHash
                  ? explorerUrl(dir, s.txField === "lock" ? "lock" : "mint", txHash)
                  : "";

                return (
                  <div key={s.key} className={`step-item ${status === "pending" ? "inactive" : status}`} style={{ position: "relative" }}>
                    <div className="step-icon" style={{
                      background: status === "done" ? "var(--primary)" : status === "active" ? "transparent" : "transparent",
                      border: status === "active" ? "2px solid var(--primary)" : status === "done" ? "none" : "2px solid var(--border)",
                      color: status === "done" ? "#0a0a0a" : status === "active" ? "var(--primary)" : "var(--border)",
                      transition: "all 0.3s",
                    }}>
                      {status === "done" ? "✓" : status === "active" ? <span className="spinner" style={{ width: 10, height: 10 }} /> : "○"}
                    </div>
                    <div className="step-content" style={{ flex: 1 }}>
                      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                        <span className="step-title" style={{
                          color: status === "done" ? "var(--primary)" : status === "active" ? "var(--text)" : "var(--muted)",
                          transition: "color 0.3s",
                        }}>
                          {s.label}
                        </span>
                        {s.chain && status !== "pending" && (
                          <span style={{
                            fontSize: "0.62rem", padding: "1px 6px", borderRadius: 99, fontWeight: 600,
                            background: s.chainCls === "sepolia" ? "rgba(100,130,255,0.15)"
                              : s.chainCls === "amoy"    ? "rgba(130,80,255,0.15)"
                              : s.chainCls === "solana"  ? "rgba(150,80,255,0.15)"
                              : s.chainCls === "hub"     ? "rgba(0,200,150,0.15)"
                              : "rgba(255,165,0,0.15)",
                            color: s.chainCls === "sepolia" ? "#8080ff"
                              : s.chainCls === "amoy"    ? "#a060ff"
                              : s.chainCls === "solana"  ? "#c060ff"
                              : s.chainCls === "hub"     ? "var(--primary)"
                              : "#ffa040",
                            border: "1px solid currentColor",
                            opacity: 0.8,
                          }}>
                            {s.chain}
                          </span>
                        )}
                      </div>
                      <div className="step-desc" style={{
                        color: status === "pending" ? "var(--border)" : "var(--muted)",
                        transition: "color 0.3s",
                      }}>
                        {s.desc}
                      </div>
                      {txHash && status !== "pending" && (
                        <a className="step-tx" href={txUrl} target="_blank" rel="noreferrer"
                          style={{ display: "inline-flex", alignItems: "center", gap: 4, marginTop: 4 }}>
                          <span style={{ fontFamily: "monospace", fontSize: "0.72rem" }}>
                            {txHash.length > 20 ? `${txHash.slice(0, 16)}…${txHash.slice(-8)}` : txHash}
                          </span>
                          <span style={{ fontSize: "0.7rem" }}>↗</span>
                        </a>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          </div>

          {/* Metadata panel */}
          <div style={{ padding: "0 1.5rem 1.25rem" }}>
            <div className="divider" style={{ marginBottom: "1rem" }} />
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "0.5rem 1rem" }}>
              <div className="contract-row" style={{ gridColumn: "1/-1" }}>
                <span className="contract-label">Transfer ID</span>
                <span
                  className="contract-addr"
                  style={{ cursor: "pointer", fontSize: "0.72rem" }}
                  title="Click to copy"
                  onClick={() => { navigator.clipboard.writeText(transfer.id); setCopied(true); setTimeout(() => setCopied(false), 2000); }}
                >
                  {transfer.id.slice(0, 18)}… {copied
                    ? <span style={{ color: "var(--primary)", fontSize: "0.65rem" }}>Copied!</span>
                    : <span style={{ color: "var(--muted)", fontSize: "0.65rem" }}>⧉</span>}
                </span>
              </div>
              <div className="contract-row">
                <span className="contract-label">Amount</span>
                <span className="contract-addr" style={{ color: "var(--primary)", fontWeight: 700 }}>
                  {transfer.amount} {
                    dir === "amoy_to_sepolia" ? "tCCS" :
                    dir === "cbdc_to_stablecoin" || dir === "token_to_instruction" ? "INRDC" :
                    "wCCC"
                  }
                </span>
              </div>
              <div className="contract-row">
                <span className="contract-label">State</span>
                <span className="contract-addr" style={{ fontSize: "0.72rem", fontFamily: "monospace", color: "var(--muted)" }}>
                  {displayState}
                </span>
              </div>
              {dir === "eth_to_sol" && transfer.instruction_payload && (
                <div className="contract-row" style={{ gridColumn: "1/-1" }}>
                  <span className="contract-label">Solana Wallet</span>
                  <span className="contract-addr" style={{ fontSize: "0.7rem", fontFamily: "monospace", color: "var(--blue)" }}>
                    {transfer.instruction_payload.slice(0, 16)}…{transfer.instruction_payload.slice(-8)}
                  </span>
                </div>
              )}
              {transfer.lock_tx_hash && (
                <div className="contract-row">
                  <span className="contract-label">{lockTxLabel(dir)}</span>
                  <a className="contract-addr" style={{ color: "var(--blue)", fontSize: "0.72rem" }}
                    href={explorerUrl(dir, "lock", transfer.lock_tx_hash!)} target="_blank" rel="noreferrer">
                    {truncate(transfer.lock_tx_hash!)} ↗
                  </a>
                </div>
              )}
              {transfer.mint_tx_hash && (
                <div className="contract-row">
                  <span className="contract-label">{mintTxLabel(dir)}</span>
                  <a className="contract-addr" style={{ color: "var(--blue)", fontSize: "0.72rem" }}
                    href={explorerUrl(dir, "mint", transfer.mint_tx_hash!)} target="_blank" rel="noreferrer">
                    {truncate(transfer.mint_tx_hash!)} ↗
                  </a>
                </div>
              )}
            </div>

            {transfer.state === "init" && !transfer.lock_tx_hash && (
              <div style={{ marginTop: "1rem" }}>
                <button className="btn-secondary" style={{ width: "100%", opacity: 0.7 }} onClick={handleCancel}>
                  Cancel Transfer
                </button>
                <p style={{ color: "var(--muted)", fontSize: "0.72rem", textAlign: "center", marginTop: 6 }}>
                  Safe to cancel — no transaction submitted yet
                </p>
              </div>
            )}
          </div>
        </div>
        );
      })()}

      {/* ── Done ── */}
      {step === "done" && transfer && (
        <div className={`card ${transfer.state === "completed" ? "success" : "error"}`}>
          <div style={{ textAlign: "center", marginBottom: "1.25rem" }}>
            <div style={{ fontSize: "2.5rem", marginBottom: "0.25rem" }}>
              {transfer.state === "completed" ? "🎉" : "❌"}
            </div>
            <div style={{ fontWeight: 800, fontSize: "1.3rem", color: transfer.state === "completed" ? "var(--primary)" : "var(--red)" }}>
              {transfer.state === "completed" ? "Transfer Complete!" : "Transfer Failed"}
            </div>
            {transfer.state === "completed" && (
              <p className="text-sm" style={{ color: "var(--muted)", marginTop: "0.4rem" }}>
                {completionMsg(transfer)}
              </p>
            )}
            {transfer.state === "failed" && transfer.failure_reason && (
              <p className="text-sm" style={{ color: "var(--red)", marginTop: "0.4rem", wordBreak: "break-word" }}>
                {transfer.failure_reason}
              </p>
            )}
          </div>

          {/* Proof panel */}
          <div style={{
            background: "var(--surface2)", border: "1px solid var(--border)",
            borderRadius: 10, padding: "0.85rem 1rem", marginBottom: "1rem",
          }}>
            <div style={{ fontSize: "0.68rem", fontWeight: 700, color: "var(--muted)", textTransform: "uppercase", letterSpacing: "0.06em", marginBottom: "0.6rem" }}>
              On-chain Proof
            </div>
            <div className="contract-row">
              <span className="contract-label">Transfer ID</span>
              <span
                className="contract-addr"
                style={{ cursor: "pointer", fontSize: "0.72rem" }}
                title="Click to copy"
                onClick={() => { navigator.clipboard.writeText(transfer.id); setCopied(true); setTimeout(() => setCopied(false), 2000); }}
              >
                {transfer.id.slice(0, 16)}… {copied ? <span style={{ color: "var(--primary)", fontSize: "0.65rem" }}>Copied!</span> : <span style={{ color: "var(--muted)", fontSize: "0.65rem" }}>⧉</span>}
              </span>
            </div>
            {transfer.lock_tx_hash && (
              <div className="contract-row">
                <span className="contract-label">{lockTxLabel(transfer.direction as Direction)}</span>
                <a className="contract-addr" style={{ color: "var(--blue)", fontSize: "0.78rem" }}
                  href={explorerUrl(transfer.direction as Direction, "lock", transfer.lock_tx_hash!)}
                  target="_blank" rel="noreferrer">
                  {truncate(transfer.lock_tx_hash!)} ↗
                </a>
              </div>
            )}
            {transfer.mint_tx_hash && (
              <div className="contract-row">
                <span className="contract-label">{mintTxLabel(transfer.direction as Direction)}</span>
                <a className="contract-addr" style={{ color: "var(--blue)", fontSize: "0.78rem" }}
                  href={explorerUrl(transfer.direction as Direction, "mint", transfer.mint_tx_hash!)}
                  target="_blank" rel="noreferrer">
                  {truncate(transfer.mint_tx_hash!)} ↗
                </a>
              </div>
            )}
          </div>

          {/* Solana wallet instructions for eth_to_sol */}
          {transfer.state === "completed" && transfer.direction === "eth_to_sol" && (
            <div style={{
              background: "rgba(150,80,255,0.08)", border: "1px solid rgba(150,80,255,0.25)",
              borderRadius: 10, padding: "0.85rem 1rem", marginBottom: "1rem",
            }}>
              <div style={{ fontSize: "0.68rem", fontWeight: 700, color: "rgba(180,100,255,0.9)", textTransform: "uppercase", letterSpacing: "0.06em", marginBottom: "0.6rem" }}>
                View Tokens in Phantom / Solflare
              </div>
              <p style={{ fontSize: "0.75rem", color: "var(--muted)", marginBottom: "0.5rem", lineHeight: 1.5 }}>
                Add this SPL token mint to your Solana devnet wallet:
              </p>
              <div style={{
                display: "flex", alignItems: "center", justifyContent: "space-between",
                background: "var(--surface)", borderRadius: 6, padding: "0.4rem 0.6rem",
                border: "1px solid var(--border)",
              }}>
                <span style={{ fontFamily: "monospace", fontSize: "0.72rem", color: "rgba(180,100,255,0.9)" }}>
                  FtwLcjsYvAJcLjwDxgXoCdnNFFXSMJj3iMuMW3oyKKzx
                </span>
                <button
                  style={{ background: "none", border: "none", cursor: "pointer", color: "var(--primary)", fontSize: "0.7rem", padding: "0 4px" }}
                  onClick={() => { navigator.clipboard.writeText("FtwLcjsYvAJcLjwDxgXoCdnNFFXSMJj3iMuMW3oyKKzx"); setCopied(true); setTimeout(() => setCopied(false), 2000); }}
                >
                  {copied ? "✓" : "⧉"}
                </button>
              </div>
              <p style={{ fontSize: "0.68rem", color: "var(--muted)", marginTop: "0.5rem" }}>
                Switch Phantom to <strong>Devnet</strong> → Settings → Developer Settings → Change Network
              </p>
            </div>
          )}

          <div style={{ display: "flex", gap: "0.75rem" }}>
            {transfer.state === "failed" && transfer.failure_reason?.includes("relay") && (
              <button className="btn-primary" style={{ flex: 1 }} onClick={handleRetry}>
                Retry Relay
              </button>
            )}
            <button className="btn-secondary" style={{ flex: 1 }} onClick={reset}>New Transfer</button>
            {transfer.state === "completed" && (
              <a href="/history" style={{
                flex: 1, display: "flex", alignItems: "center", justifyContent: "center",
                background: "var(--surface2)", border: "1px solid var(--border)",
                borderRadius: 8, color: "var(--text)", textDecoration: "none",
                fontSize: "0.875rem", fontWeight: 500,
              }}>
                View History
              </a>
            )}
          </div>
        </div>
      )}

      {/* ── Error ── */}
      {step === "error" && (
        <div className="card error">
          <div className="card-title">
            {errorContext === "login" ? "Sign-In Failed" : "Transaction Failed"}
          </div>
          <p className="text-sm mono" style={{ color: "var(--red)", marginBottom: "0.5rem", wordBreak: "break-word" }}>
            {error}
          </p>
          {errorContext === "login" && (
            <p style={{ fontSize: "0.78rem", color: "var(--muted)", marginBottom: "1.25rem" }}>
              Make sure the BharatSetu backend is running (<code>./dev.sh</code>), then try again.
            </p>
          )}
          {errorContext === "tx" && <div style={{ marginBottom: "1.25rem" }} />}
          <button className="btn-secondary" onClick={() => { localStorage.removeItem("activeTransferId"); setTransfer(null); setTransferId(null); setStep(isLoggedIn() ? "form" : "login"); }}>
            Try Again
          </button>
        </div>
      )}
    </div>
  );
}

// Direction-aware progress: percentage through the step list based on current state
function stateProgressPct(state: string, stepList: StepDef[]): number {
  const idx = stepList.findIndex(s => s.key === state);
  if (idx === -1) {
    // terminal states
    if (state === "completed" || state === "failed") return 100;
    return 5;
  }
  return Math.round(((idx + 0.5) / stepList.length) * 100);
}

async function executeSolanaBurn(connection: Connection, wallet: any, amount: number, destination: string) {
    if (!wallet.publicKey) {
        throw new Error("Wallet not connected");
    }

    const transaction = new Transaction().add(
        SystemProgram.transfer({
            fromPubkey: wallet.publicKey,
            toPubkey: new PublicKey(destination),
            lamports: amount, // Convert amount to lamports (1 SOL = 10^9 lamports)
        })
    );

    transaction.feePayer = wallet.publicKey;
    const { blockhash } = await connection.getRecentBlockhash();
    transaction.recentBlockhash = blockhash;

    const signedTransaction = await wallet.signTransaction(transaction);
    const txid = await connection.sendRawTransaction(signedTransaction.serialize());

    await connection.confirmTransaction(txid);
    return txid;
}
