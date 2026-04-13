# BharatSetu — Cross-Chain Carbon Credit ↔ e-Rupee CBDC Bridge

> **Status:** 🔴 POC in active development  
> **Architecture:** v3.0 (Production-Grade POC) | Vision: IBC Protocol v2.0 (Cosmos)

BharatSetu enables verifiable on-chain retirement of tokenized voluntary carbon credits (VCCs) on Polygon PoS and atomic settlement of their fiat equivalent as **e-Rupee CBDC** — India's central bank digital currency. Every retirement flows through a fault-tolerant OTP process tree, a multi-validator consensus layer, and a two-phase CBDC commit — with a cryptographically auditable trail at every step.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Core Components](#core-components)
  - [Bridge Orchestrator (FSM)](#bridge-orchestrator-fsm)
  - [PoRC Consensus](#porc-consensus)
  - [Blockchain Indexer](#blockchain-indexer)
  - [CBDC Adapter](#cbdc-adapter)
  - [Smart Contracts](#smart-contracts)
- [Request Flows](#request-flows)
- [Database Schema](#database-schema)
- [Security Model](#security-model)
- [Getting Started](#getting-started)
- [Roadmap](#roadmap)
- [Vision: Cosmos IBC](#vision-cosmos-ibc)

---

## Overview

### The Problem

Voluntary carbon markets lack a credible, atomic settlement mechanism. Today, retiring a tokenized carbon credit and receiving its fiat equivalent requires multiple off-chain handshakes, manual reconciliation, and no trustless finality guarantee.

### The Solution

BharatSetu bridges the gap with three guarantees:

1. **Atomicity** — CBDC is never issued unless the on-chain `RetirementComplete` event is confirmed at ≥12 block depth.
2. **Auditability** — Every FSM state transition is persisted as an immutable event record in PostgreSQL before the in-process state advances, enabling full replay on restart.
3. **Nonce Isolation** — Every cross-chain event carries a `keccak256(user || counter || chainId)` nonce — replay attacks are structurally impossible.

### Why Elixir?

| Requirement | Elixir / OTP Advantage | Node.js Limitation |
|---|---|---|
| Long-running retirement FSM | GenServer owns FSM state; supervised; restarts from last checkpoint | Requires external Redis FSM; process death = lost state |
| Validator coordination | GenServer cluster via `pg`; built-in distributed messaging | Requires Kafka or Redis pub/sub |
| WebSocket at scale | Phoenix Channels: 2M+ concurrent connections on one node | Event loop bottlenecks under sustained WebSocket load |
| Blockchain event listener | Long-lived supervised GenServer; auto-restart on RPC disconnect | Requires pm2 wrapper; crash loses queue state |
| Fault isolation | `let it crash` + supervisor restarts individual processes | Uncaught promise rejection brings down entire worker |

---

## Architecture

### Five-Tier System

```
┌─────────────────────────────────────────────────────────┐
│  TIER 1 — PRESENTATION                                   │
│  Next.js 14 (App Router)  ·  wagmi v2  ·  MetaMask      │
│  Dashboard | Convert Wizard | Portfolio | Settings       │
└────────────────────────┬────────────────────────────────┘
                         │  HTTPS / WSS / SSE
┌────────────────────────┴────────────────────────────────┐
│  TIER 2 — PHOENIX WEB LAYER  (bharat_web)               │
│  REST /api/v1/*  ·  Phoenix Channels  ·  LiveView        │
│  Auth Plug · KYC Plug · Rate Limit · CorrelationId      │
└────────────────────────┬────────────────────────────────┘
                         │  GenServer calls + Phoenix.PubSub
┌────────────────────────┴────────────────────────────────┐
│  TIER 3 — OTP ORCHESTRATION  (bharat_core)              │
│  RetirementServer FSM (DynamicSupervisor)               │
│  PoRC Cluster  ·  BlockchainIndexer  ·  PriceAggregator │
│  Phoenix.PubSub  ·  Cachex (ETS)  ·  Broadway           │
└────────────────────────┬────────────────────────────────┘
                         │  JSON-RPC / eth_subscribe (WebSocket)
┌────────────────────────┴────────────────────────────────┐
│  TIER 4 — BLOCKCHAIN  (Polygon PoS)                     │
│  EscrowBridge.sol  ·  CarbonCertNFT.sol                 │
│  RetirementLog.sol                                      │
└────────────────────────┬────────────────────────────────┘
                         │  HTTP / Req
┌────────────────────────┴────────────────────────────────┐
│  TIER 5 — EXTERNAL ADAPTERS  (bharat_adapters)          │
│  KYC (Jumio)  ·  Verra Registry  ·  RBI e-Rupee         │
│  CoinGecko  ·  Chainlink VRF                            │
└─────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Backend Framework | Elixir 1.16 + Phoenix 1.7 + Phoenix Channels |
| Concurrency Model | OTP GenServers, Supervisors, Task.Supervisor |
| Message Bus | Phoenix.PubSub (POC) → Broadway/Kafka (production) |
| Database | PostgreSQL 16 via Ecto 3 + Cachex (ETS-backed cache) |
| Blockchain Interface | Ethereumex + ABI decoding (ex_abi) |
| Smart Contracts | Solidity 0.8 / Foundry — Polygon PoS (Amoy testnet) |
| Consensus Layer | Elixir PoRC GenServer cluster + libsecp256k1 |
| Auth | SIWE (EIP-4361) + Guardian JWT RS256 + Redis nonce TTL |
| Frontend | Next.js 14 (App Router) + wagmi v2 + viem |

---

## Project Structure

```
bharat_setu/                          # Elixir umbrella root
├── apps/
│   ├── bharat_web/                   # Phoenix endpoint, router, controllers, channels
│   │   └── lib/bharat_web/
│   │       ├── endpoint.ex           # Phoenix.Endpoint (HTTP + WebSocket)
│   │       ├── router.ex             # Routes + pipeline plugs
│   │       ├── controllers/          # REST JSON API controllers
│   │       ├── channels/             # RetirementChannel, DashboardChannel
│   │       ├── live/                 # Phoenix LiveView (dashboard)
│   │       └── plugs/                # Auth, KYC gate, rate limit, correlation ID
│   │
│   ├── bharat_core/                  # Domain logic — no web dependency
│   │   └── lib/bharat_core/
│   │       ├── bridge/               # RetirementServer FSM, DynamicSupervisor
│   │       ├── porc/                 # ValidatorNode, LeaderElector, VoteAggregator
│   │       ├── indexer/              # BlockchainIndexer, EventParser
│   │       ├── pricing/              # PriceAggregator, ETS cache
│   │       ├── portfolio/            # Portfolio queries, balance calculators
│   │       └── application.ex        # OTP Application + supervision tree
│   │
│   ├── bharat_adapters/              # External system integrations
│   │   └── lib/bharat_adapters/
│   │       ├── kyc/                  # KYC.Client + KYC.MockClient (Jumio shape)
│   │       ├── registry/             # Verra, GoldStd, Mock strategies
│   │       ├── cbdc/                 # CBDC.Client (reserve/commit/rollback)
│   │       └── blockchain/           # Ethereumex wrapper, ABI decoder, contract calls
│   │
│   └── bharat_data/                  # Ecto schemas, migrations, repo
│       └── lib/bharat_data/
│           ├── repo.ex
│           ├── schemas/              # User, Retirement, Lock, VotingRound, ...
│           └── migrations/
│
├── contracts/                        # Foundry project
│   ├── src/
│   │   ├── EscrowBridge.sol          # Lock and release carbon credit tokens
│   │   ├── CarbonCertNFT.sol         # Mint retirement certificate NFTs
│   │   └── RetirementLog.sol         # On-chain audit trail
│   └── test/
│
├── frontend/                         # Next.js 14 App Router
│   ├── app/
│   │   ├── dashboard/
│   │   ├── convert/                  # Bridge wizard
│   │   └── portfolio/
│   └── lib/
│       └── wagmi.ts                  # wagmi v2 + viem config
│
└── config/                           # config.exs, dev.exs, prod.exs, runtime.exs
```

---

## Core Components

### Bridge Orchestrator (FSM)

Each retirement request spawns a dedicated `RetirementServer` GenServer under a `DynamicSupervisor`. The FSM is checkpointed to PostgreSQL on every transition.

**FSM States:**

```
pending_kyc → kyc_approved → tokens_locking → tokens_locked
    → registry_verifying → porc_in_progress → porc_finalized
    → cbdc_settling → nft_minting → completed
                                  ↘ failed
```

Key properties:
- **Process isolation** — one crash = one retirement affected, never others
- **Crash recovery** — `init/1` restores last checkpoint from PostgreSQL
- **Event sourcing** — every transition written to `retirement_events` before FSM advances
- **Real-time** — every state change broadcast via Phoenix.PubSub → WebSocket to frontend

### PoRC Consensus

Proof-of-Relay Consensus (PoRC) is a 3-node validator cluster implemented as OTP GenServers:

- `ValidatorNode` — independent event verification (N=3 in POC)
- `LeaderElector` — VRF-based leader selection (Chainlink VRF in production)
- `VoteAggregator` — collects votes; triggers finality at >2/3 quorum (2-of-3 in POC)

In the POC all three nodes run on the same host. In production, Erlang distribution (`:net_kernel`) spreads them across nodes **without code changes**.

### Blockchain Indexer

`BlockchainIndexer` is a supervised GenServer that maintains a persistent WebSocket to the Polygon RPC. It is reorg-aware:

- Tentative events wait in a `pending` map
- On every `new_block`, events with `current_block - event_block >= 12` are promoted to confirmed
- WebSocket drop raises intentionally — supervisor restarts and reconnects automatically

### CBDC Adapter

Two-phase commit against the RBI e-Rupee sandbox:

| Phase | Action | When |
|---|---|---|
| `RESERVE` | Freeze CBDC for beneficiary | After `tokens_locked`, before chain finality |
| `COMMIT` | Release reserved CBDC | After `RetirementComplete` confirmed at ≥12 blocks |
| `ROLLBACK` | Cancel reservation | On any failure or timeout |

Idempotency key = `nonce_hash` — safe to retry on network failures.

### Smart Contracts

| Contract | Purpose |
|---|---|
| `EscrowBridge.sol` | Accepts `lockTokens()` call; emits `TokensLocked` event; releases on `finalizeRetirement()` |
| `CarbonCertNFT.sol` | ERC-721 retirement certificate; minted by relayer after CBDC settlement |
| `RetirementLog.sol` | Immutable on-chain audit trail; one entry per finalized retirement |

All contracts deployed to **Polygon Amoy testnet** and verified on Polygonscan.

---

## Request Flows

### Full Retirement Bridge Flow

```
User (MetaMask)
    │
    ├─ POST /api/v1/auth/challenge   ← get SIWE nonce
    ├─ personal_sign (MetaMask)
    ├─ POST /api/v1/auth/verify      ← Guardian JWT issued
    │
    ├─ POST /api/v1/retirements      ← spawn RetirementServer FSM
    │       │
    │       ├─ KYC check (Jumio)
    │       ├─ Build unsigned lockTokens() tx → push to frontend via WebSocket
    │       ├─ User signs & submits tx in MetaMask
    │       ├─ POST /api/v1/retirements/:id/lock  ← tx hash confirmed
    │       │
    │       ├─ BlockchainIndexer confirms TokensLocked (12 blocks)
    │       ├─ [parallel] Registry verification (Verra/GoldStd)
    │       ├─ [parallel] PoRC 3-validator consensus
    │       │       └─ VoteAggregator reaches 2/3 quorum
    │       │
    │       ├─ CBDC.reserve()  → CBDC.commit() after finality
    │       ├─ finalizeRetirement() on-chain (relayer key)
    │       └─ CarbonCertNFT.mintCertificate() → NFT to user wallet
    │
    └─ WebSocket push: status_update events at each FSM transition
```

---

## Database Schema

| Table | Key Fields | Purpose |
|---|---|---|
| `users` | `wallet_address`, `kyc_tier`, `kyc_provider_ref` | Identity + compliance |
| `retirements` | `id(UUID)`, `wallet`, `token`, `amount`, `state`, `nonce_hash` | Master FSM record |
| `retirement_events` | `retirement_id`, `state`, `metadata(JSONB)` | Immutable event log + crash recovery |
| `locks` | `retirement_id`, `tx_hash`, `block_number` | On-chain lock details |
| `registry_receipts` | `retirement_id`, `registry`, `registry_id`, `serial_range` | Registry retirement proof |
| `porc_rounds` | `retirement_id`, `leader_node`, `votes(JSONB)`, `quorum_met_at` | PoRC voting history |
| `cbdc_settlements` | `retirement_id`, `reserve_id`, `amount_paise`, `cbdc_tx_ref` | CBDC settlement record |
| `nft_certificates` | `retirement_id`, `token_id`, `ipfs_uri`, `wallet`, `minted_at` | NFT certificate issuance |
| `price_snapshots` | `token`, `price_usd`, `source`, `recorded_at` | Time-series price history |

---

## Security Model

| Threat | Mitigation |
|---|---|
| Replay attack | Per-user `keccak256(user \|\| counter \|\| chainId)` nonce; consumed on use; stored in Redis with TTL |
| Double-spend | CBDC `reserve` is idempotent (idempotency key = nonce_hash); 12-block confirmation before commit |
| Chain reorg | Indexer tracks confirmation depth; events re-queued if block depth drops below threshold |
| CBDC partial failure | Two-phase commit with explicit `rollback`; state machine never advances without DB checkpoint |
| Price manipulation | VWAP aggregation across CoinGecko + Toucan; >5% divergence halts CBDC minting |
| Stale retirement | Timeout + refund flow for retirements stuck in any state > configurable TTL |
| Unauthorized access | Guardian JWT RS256; SIWE wallet ownership proof; KYC tier gate on bridge endpoints |

---

## Getting Started

### Prerequisites

- Elixir 1.16 + Erlang/OTP 26
- Node.js 20+
- PostgreSQL 16
- Redis 7
- Foundry (`foundryup`)
- Polygon Amoy testnet ETH ([faucet](https://faucet.polygon.technology/))

### Setup

```bash
# Clone
git clone https://github.com/<your-org>/BharatSetu.git
cd BharatSetu

# Backend
mix deps.get
mix ecto.setup
iex -S mix phx.server

# Contracts
cd contracts
forge install
forge test
forge script script/Deploy.s.sol --rpc-url $AMOY_RPC_URL --broadcast

# Frontend
cd frontend
npm install
npm run dev
```

### Environment Variables

```bash
# config/runtime.exs inputs
DATABASE_URL=postgresql://user:pass@localhost/bharat_setu
REDIS_URL=redis://localhost:6379
AMOY_RPC_URL=https://rpc-amoy.polygon.technology
ESCROW_CONTRACT=0x...
NFT_CONTRACT=0x...
RELAYER_PRIVATE_KEY=0x...
RBI_CBDC_BASE_URL=https://sandbox.rbi.org.in/cbdc
KYC_API_KEY=...
GUARDIAN_SECRET_KEY_BASE=...
```

---

## Roadmap

### POC (Current)

- [ ] Phase 0 — Elixir umbrella scaffold + Foundry setup
- [ ] Phase 1 — Smart contracts on Polygon Amoy
- [ ] Phase 2 — Core backend (FSM, PoRC, Indexer, Adapters)
- [ ] Phase 3 — Phoenix web layer (REST + Channels + LiveView)
- [ ] Phase 4 — Next.js 14 frontend
- [ ] Phase 5 — Security hardening
- [ ] Phase 6 — Testing (unit + integration + load)

See [PROGRESS.md](PROGRESS.md) for granular task tracking.

---

## Vision: Cosmos IBC

Post-POC, BharatSetu evolves into a full IBC-native protocol:

| Component | POC | IBC Vision |
|---|---|---|
| Consensus | Elixir PoRC GenServers | Cosmos SDK + Tendermint BFT |
| Cross-chain relay | Ethereum event listener | Hermes IBC relayer (ICS-04) |
| Token transfer | Custom escrow contract | ICS-20 fungible token transfer |
| Chain topology | Polygon + Elixir bridge | Hub-and-spoke IBC zone architecture |
| Governance | None | ATOM staking, proposals, voting |
| Scale | Single host | 100 validators, mainnet |

This architecture is **designed for the upgrade** — Erlang distribution means the PoRC GenServer cluster can be distributed across nodes without code changes, laying the mental model for IBC validator sets.

---

## License

MIT

---

*Built for India's green finance future — bridging voluntary carbon markets with sovereign digital currency.*
