# BharatSetu — Build Progress Tracker

**Project:** Cross-Chain Carbon Credit ↔ e-Rupee CBDC Bridge  
**Stack:** Elixir/Phoenix · Polygon PoS · Next.js 14  
**POC Target:** Bharat_Setu_Architecture.docx v3.0  
**Vision Target:** BharatSetu IBC Protocol v2.0 (Cosmos)

---

## Overall Status: 🔴 Not Started

---

## Phase 0 — Project Scaffold

- [ ] Create Elixir umbrella project (`mix new bharat_setu --umbrella`)
- [ ] Add sub-app `bharat_web` (Phoenix endpoint, router, channels)
- [ ] Add sub-app `bharat_core` (domain logic, OTP supervision tree)
- [ ] Add sub-app `bharat_adapters` (KYC, registry, CBDC, blockchain clients)
- [ ] Add sub-app `bharat_data` (Ecto schemas, migrations, Repo)
- [ ] Configure `mix.exs` with all dependencies
- [ ] Set up `config/` files (dev, prod, runtime)
- [ ] Set up PostgreSQL database and run initial migration
- [ ] Set up Foundry project for Solidity contracts

---

## Phase 1 — Smart Contracts (Polygon Amoy Testnet)

- [ ] Write `EscrowBridge.sol` — lock and release carbon credit tokens
- [ ] Write `CarbonCertNFT.sol` — mint retirement certificate NFTs
- [ ] Write `RetirementLog.sol` — on-chain audit trail
- [ ] Write Foundry unit tests for all contracts
- [ ] Deploy contracts to Polygon Amoy testnet
- [ ] Verify contracts on Polygonscan
- [ ] Save deployed contract addresses to config

---

## Phase 2 — Core Backend (Elixir/OTP)

### 2a — Data Layer
- [ ] Define Ecto schema: `User`
- [ ] Define Ecto schema: `Retirement`
- [ ] Define Ecto schema: `Lock`
- [ ] Define Ecto schema: `VotingRound`
- [ ] Write and run all migrations

### 2b — Auth (SIWE + Guardian)
- [ ] Implement `SiweVerifier` (EIP-4361 message + signature verification)
- [ ] Set up Redis for nonce TTL storage
- [ ] Implement `AuthController` — `/api/v1/auth/challenge` and `/api/v1/auth/verify`
- [ ] Configure Guardian JWT RS256
- [ ] Write `VerifyJWT` and `LoadWallet` plugs
- [ ] Write `RequireKYC` plug

### 2c — Blockchain Indexer
- [ ] Implement `BlockchainIndexer` GenServer (WebSocket to Polygon RPC)
- [ ] Implement `EventParser` for `RetirementComplete` and `TokensLocked` events
- [ ] Add reorg-aware confirmation depth (12 blocks)
- [ ] Publish parsed events to Phoenix.PubSub

### 2d — PoRC Consensus
- [ ] Implement `ValidatorNode` GenServer (x3 nodes)
- [ ] Implement `LeaderElector` with VRF leader election
- [ ] Implement `VoteAggregator` (>2/3 PreCommit threshold)
- [ ] Wire PoRC supervisor

### 2e — Bridge Orchestrator (RetirementServer FSM)
- [ ] Implement `RetirementServer` GenServer with all FSM states:
  - `pending_kyc` → `kyc_approved`
  - `tokens_locking` → `tokens_locked`
  - `registry_verifying` → `porc_in_progress` → `porc_finalized`
  - `cbdc_settling` → `nft_minting` → `completed` / `failed`
- [ ] Checkpoint FSM state to PostgreSQL on every transition
- [ ] Implement crash recovery (`restore_checkpoint/1`)
- [ ] Implement retry logic (`retry_or_fail/2`)
- [ ] Wire `DynamicSupervisor` for per-retirement process spawning

### 2f — External Adapters
- [ ] Implement `KYC.MockClient` (Jumio interface shape)
- [ ] Implement `Registry.MockClient` (Verra / Gold Standard interface)
- [ ] Implement `CBDC.Client` — two-phase: reserve → commit → rollback (RBI sandbox)
- [ ] Implement `Blockchain` adapter — Ethereumex wrapper + ABI decoder + contract calls

### 2g — Pricing Service
- [ ] Implement `PriceAggregator` GenServer (CoinGecko + RBI rate feed)
- [ ] Implement VWAP aggregation and manipulation guard
- [ ] Back with ETS cache (`Cachex`)

---

## Phase 3 — Phoenix Web Layer

- [ ] Set up `router.ex` with `:api`, `:authenticated`, `:kyc_verified` pipelines
- [ ] Implement `RetirementController` (create, show, index, confirm_lock)
- [ ] Implement `PortfolioController`
- [ ] Implement `PriceController`
- [ ] Implement `CertController`
- [ ] Implement `RetirementChannel` (Phoenix Channel — real-time FSM updates)
- [ ] Implement `DashboardChannel`
- [ ] Implement `DashboardLive` (Phoenix LiveView)
- [ ] Add rate limiting plug (100 req/min per IP)
- [ ] Add `CorrelationId` plug

---

## Phase 4 — Frontend (Next.js 14)

- [ ] Bootstrap Next.js 14 App Router project
- [ ] Set up `wagmi v2` + `viem` + MetaMask / WalletConnect
- [ ] Implement wallet sign-in flow (SIWE challenge → verify → JWT)
- [ ] Build Dashboard page (prices, global stats, settlement feed)
- [ ] Build Convert Wizard (bridge flow: select token → lock → track FSM)
- [ ] Build Portfolio page (carbon held/retired, CBDC balance, NFT certs)
- [ ] Wire Phoenix WebSocket channel for real-time retirement status updates

---

## Phase 5 — Security & Hardening

- [ ] Nonce replay protection: `keccak256(user || counter || chainId)`
- [ ] CBDC two-phase commit: reserve → confirm → rollback on failure
- [ ] Validate 12-block confirmation depth before state advancement
- [ ] Timeout and refund flow for stalled retirements
- [ ] Input validation at all API boundaries
- [ ] Rate limiting + DDoS protection review

---

## Phase 6 — Testing

- [ ] Unit tests for `SiweVerifier`
- [ ] Unit tests for `RetirementServer` FSM transitions
- [ ] Unit tests for `VoteAggregator`
- [ ] Integration tests for full retirement flow (mock adapters)
- [ ] Foundry tests coverage for all smart contracts
- [ ] Load test Phoenix Channels (target: 1000 concurrent)

---

## Future — Cosmos IBC Vision (Post-POC)

- [ ] Set up Cosmos SDK chain (replace Polygon)
- [ ] Deploy IBC core modules (ICS-02, ICS-03, ICS-04, ICS-20)
- [ ] Configure Hermes relayer (replace Elixir indexer)
- [ ] Build hub-and-spoke zone architecture
- [ ] Ethereum bridge-zone (Tendermint + Ethereum full node)
- [ ] Governance module (ATOM staking, proposals, voting)
- [ ] Mainnet launch (100 validators)

---

## Notes & Decisions

| Date | Decision | Rationale |
|------|----------|-----------|
| | Using Phoenix.PubSub over Kafka | Simpler for POC; Broadway-ready for production |
| | Polygon Amoy testnet | Free testnet ETH/MATIC; production-equivalent EVM |
| | Mock clients for all external APIs | Ship faster; real API shape preserved via behaviours |
| | Single-host PoRC cluster | POC simplicity; `:net_kernel` distributable without code changes |

---

## Resources

- Architecture Doc: `Bharat_Setu_Architecture.docx` (v3.0 — POC)
- Vision Doc: `summary.docx` (v2.0 — Cosmos IBC)
- Polygon Amoy Faucet: https://faucet.polygon.technology/
- Hermes Relayer Docs: https://hermes.informal.systems/
