# ETH → SOL Bridge: Complete Request Flow

Deep dive into how a single ETH→SOL transfer works — every entity, every step, every message.

---

## Entities Involved

| Entity | What it is | Where it runs |
|---|---|---|
| **MetaMask** | User's EVM wallet | Browser |
| **Phantom** | User's Solana wallet | Browser extension |
| **Frontend** (Next.js) | Bridge UI | Browser |
| **Phoenix Backend** | Elixir umbrella app — orchestrates everything | Local server |
| **TransferServer** | GenServer FSM — one per active transfer | Inside Phoenix |
| **SepoliaIndexer** | GenServer — polls Sepolia for on-chain events | Inside Phoenix |
| **Relayer Worker** | GenServer — polls DB, triggers mints | Inside Phoenix |
| **SolanaClient** | Elixir module — calls `mint_wrapped.js` | Inside Phoenix |
| **EthVault** | Solidity contract — locks ERC20 tokens | Ethereum Sepolia |
| **MintBridge program** | Anchor/Rust program — mints wrapped SPL tokens | Solana Devnet |
| **PostgreSQL** | Stores transfer state, tx hashes, checkpoints | Local DB |

---

## High-Level Flow

```
User (Browser)
  │  1. fill form, click "Lock & Bridge"
  ▼
Frontend
  │  2. POST /api/v1/transfers  →  creates DB record + starts FSM
  │  3. MetaMask: approve wCCC spend
  │  4. MetaMask: lock() tx on EthVault
  │  5. POST /api/v1/transfers/:id/confirm_lock
  ▼
Phoenix Backend
  │  6. SepoliaIndexer polls blocks → detects TokenLocked event
  │  7. FSM transitions: init → locked → confirmed
  │  8. Relayer Worker polls DB → picks up confirmed transfer
  │  9. SolanaClient runs mint_wrapped.js → Solana tx
  │  10. FSM transitions: minted → completed → broadcasts WS event
  ▼
Frontend
  │  11. WebSocket receives "completed" → fetches full transfer → shows done screen
  ▼
Solana Devnet
     10 wrapped SPL tokens in user's ATA
```

---

## Step-by-Step Detail

### Step 1 — User fills form and clicks "Lock & Bridge"

Frontend state at this point:
- `fromChain = sepolia`, `toChain = solana`
- `direction = "eth_to_sol"`
- `amount = "10"`
- `solanaAddress = "2dM7…LYxm"` (masked in UI, stored in state)

---

### Step 2 — Create transfer record

**Frontend → Phoenix**

```
POST /api/v1/transfers
{
  direction: "eth_to_sol",
  token_address: "<wCCC ERC20 address on Sepolia>",
  amount: "10"
}
```

**Phoenix (TransferController):**
- Validates amount > 0
- Checks compliance (skipped for eth_to_sol — not a CBDC direction)
- Inserts row in `transfers` table: `state = "init"`
- Calls `TransferSupervisor.start_transfer/1` → spawns a `TransferServer` GenServer for this transfer ID
- Returns `{ id: "87011d7a-...", state: "init" }`

**TransferServer init (direction = eth_to_sol):**
- Sets `state = :init`
- Broadcasts WS event `await_eth_lock` to frontend with unsigned tx params (contract addresses, chain ID)
- Waits for user to submit the lock tx

**Frontend:**
- Stores `transferId` in `localStorage`
- Sets step to `"pending"` — starts polling + subscribes to WebSocket channel

---

### Step 3 — MetaMask: Approve wCCC spend

Frontend builds and sends:
```
ERC20.approve(spender=EthVault, amount=10e18)
  to: <wCCC token address on Sepolia>
```

MetaMask prompts user → user signs → tx submitted to Sepolia.

Frontend waits for 2 confirmations before proceeding.

**Why approve?** ERC20 tokens require the owner to grant explicit permission to a contract before it can pull tokens. EthVault cannot take your wCCC without this step.

---

### Step 4 — MetaMask: Lock tokens in EthVault

Frontend builds:
```
EthVault.lock(
  token:        <wCCC address>,
  amount:       10_000_000_000_000_000_000,  // 10 × 10^18 wei
  crossChainId: keccak256(transferId + timestamp),  // unique per attempt
  destWallet:   <32 bytes — Solana pubkey decoded from base58>,
  timeoutSec:   3600
)
  to: <EthVault contract address on Sepolia>
```

MetaMask signs → tx submitted. Frontend waits for 1 confirmation.

**What EthVault does on-chain:**
- Pulls `10e18` wCCC from user wallet into the vault
- Records the lock: `(crossChainId, token, amount, destWallet, expiry)`
- Emits a `TokenLocked(crossChainId, token, amount, destWallet)` event in the tx receipt

**After lock confirmed:**

Frontend calls:
```
POST /api/v1/transfers/87011d7a-…/confirm_lock
{ tx_hash: "0xb5e6…", cross_chain_id: "0x9638…" }
```

Phoenix stores `cross_chain_id` in DB — SepoliaIndexer will need this to correlate on-chain events back to the DB transfer record.

---

### Step 5 — SepoliaIndexer detects TokenLocked event

**SepoliaIndexer** is a GenServer polling Sepolia every 3 seconds:

```
loop:
  current_block = eth_blockNumber()
  logs = eth_getLogs(from=last_block, to=current_block, address=EthVault)
  for each log:
    parse topic → if TokenLocked event:
      store in pending{} map keyed by (transfer_id, tx_hash)
  
  promote_confirmed():
    for each pending event where (current_block - event_block) >= 3:
      → confirmed — process it
```

**On confirmation (3 blocks deep):**
- Looks up DB transfer by `cross_chain_id` (the key stored in Step 4's confirm_lock)
- Stores `dest_wallet` (Solana address) in `instruction_payload` column
- Calls `TransferServer.lock_submitted(id, tx_hash)` → FSM: `init → locked`
- Calls `TransferServer.on_confirmed(id, block_number)` → FSM: `locked → confirmed`

---

### Step 6 — FSM transitions through states

**TransferServer** (GenServer, one per transfer):

```
init
  ↓ lock_submitted(tx_hash)
locked
  ↓ on_confirmed(block_number)    [eth_to_sol path skips hub/validating/consensus_b — simplified POC]
confirmed
  ↓ [Relayer picks it up from DB]
minted
  ↓ [FSM receives on_minted]
completed
```

Each state transition:
1. Updates the `state` field in PostgreSQL
2. Inserts a row in `transfer_events` (audit log)
3. Broadcasts a WebSocket event to the frontend: `{ event: "state_change", state: "confirmed" }`

---

### Step 7 — Relayer Worker picks up the transfer

**BharatRelayer.Worker** polls DB every 5 seconds:

```sql
SELECT * FROM transfers
WHERE state = 'confirmed'
  AND direction IN ('eth_to_sol', ...)
  AND relay_attempts < 3
```

Finds `87011d7a` → calls `relay_transfer/1`.

**Amount conversion (critical):**
```
DB amount: 10  (stored as decimal, no decimals)
× 10^18 = 10_000_000_000_000_000_000  (EVM wei, 18 decimals)
÷ 10^9  = 10_000_000_000              (SPL lamports, 9 decimals)
```

Solana SPL tokens use 9 decimals. EVM uses 18. The relayer bridges this by dividing by `10^9`.

**Idempotency check:**
- Checks `Transfers.already_minted?(nonce_hash)` — if another relayer instance already minted, skips.

---

### Step 8 — SolanaClient mints wrapped SPL tokens

Relayer calls:
```elixir
SolanaClient.mint_wrapped(
  cross_chain_id_hex,   # "0x9638…" — unique lock identifier
  10_000_000_000,       # SPL lamports
  nonce_hash,           # "0x…" — replay protection
  "2dM7…LYxm"          # destination Solana wallet (from instruction_payload)
)
```

**SolanaClient** shells out to Node.js:
```
node solana/scripts/mint_wrapped.js \
  "0x9638…"        \   # cross_chain_id
  "10000000000"    \   # amount in lamports
  "0x…"            \   # nonce hash
  "2dM7…LYxm"         # dest wallet
```

**mint_wrapped.js (Anchor client):**
1. Loads relayer keypair (from `SOLANA_RELAYER_KEYPAIR` env)
2. Loads mint authority (from `SOLANA_WRAPPED_MINT` env = `FtwLcj…`)
3. Derives the user's ATA: `getAssociatedTokenAddress(mint=FtwLcj…, owner=2dM7…)`
4. If ATA doesn't exist → creates it (costs ~0.00203 SOL rent — charged once)
5. Calls `mintTo(mint=FtwLcj…, destination=ATA, authority=relayer, amount=10e9)`
6. Prints `MINT_SIG=3d9nTwPf…` to stdout

SolanaClient reads stdout, extracts signature.

---

### Step 9 — DB updated, FSM completes

Relayer writes to DB:
```sql
UPDATE transfers SET state='minted', mint_tx_hash='3d9nTwPf…' WHERE id='87011d7a'
```

Calls `TransferServer.on_minted(id, sig)` → FSM:
```
minted
  ↓
completed  →  broadcast { event: "completed", state: "completed" }
              DELETE from localStorage
              stop GenServer (:normal exit — not restarted, restart: :temporary)
```

---

### Step 10 — Frontend receives WebSocket event

Frontend WS handler receives `{ state: "completed" }`:
1. Clears visual simulation timers
2. Fetches full transfer from API: `GET /api/v1/transfers/87011d7a`
3. Sets `step = "done"`, removes `activeTransferId` from localStorage
4. Renders "Transfer Complete!" screen with:
   - Lock tx link → Sepolia Etherscan
   - Mint tx link → Solana Devnet Explorer

---

## What Happened to the Tokens

```
BEFORE:
  MetaMask (Sepolia):   1000 wCCC
  Solana (2dM7…):       0 wCCC-SPL

AFTER:
  MetaMask (Sepolia):   990 wCCC    ← 10 locked in EthVault (not burned)
  Solana (2dM7…) ATA:  10 wCCC-SPL ← minted by relayer to ATA
  Solana fee:           -0.00168 SOL ← tx fee + ATA rent (one-time)
```

The EthVault holds the 10 wCCC in escrow. To get them back: do `sol_to_eth` (burn SPL on Solana → unlock EVM on Sepolia).

---

## Solana Token Account Model (Why FtwLcj… ≠ your wallet)

```
FtwLcjsYvAJcLjwDxgXoCdnNFFXSMJj3iMuMW3oyKKzx
  = Mint Account (the token TYPE — like an ERC20 contract address)
  = defines: decimals=9, total_supply, mint_authority=relayer

2dM7Stmka8ZmwgS8S8EXEZr7EkeCztMTjw2ZyykqLYxm
  = your Wallet Account (holds SOL, owns ATAs)

ATA (Associated Token Account)
  = derived address: PDA(seeds=[your_wallet, TokenProgram, mint])
  = holds: { mint: FtwLcj…, owner: 2dM7…, amount: 10_000_000_000 }
  = this is where your 10 tokens actually live
```

Phantom reads your ATA, sees `amount = 10e9`, divides by `10^9 decimals`, displays `10.0000 wCCC`.

---

## State Machine Summary

```
init          User created transfer, waiting for MetaMask tx
  ↓
locked        Lock tx submitted (confirm_lock API called by frontend)
  ↓
confirmed     SepoliaIndexer saw TokenLocked event ≥ 3 blocks deep
  ↓
minted        Relayer minted 10 SPL on Solana (mint_wrapped.js succeeded)
  ↓
completed     FSM done, WS broadcast sent, GenServer stopped
```

---

## Key Files

| File | Role |
|---|---|
| `frontend/app/bridge/page.tsx` | UI, MetaMask tx signing, WS listener |
| `bharat_web/controllers/transfer_controller.ex` | REST API — create, confirm_lock, show |
| `bharat_core/bridge/transfer_server.ex` | FSM GenServer — state machine per transfer |
| `bharat_core/bridge/transfer_supervisor.ex` | DynamicSupervisor — spawns TransferServers |
| `bharat_core/indexer/sepolia_indexer.ex` | Polls Sepolia blocks, detects TokenLocked |
| `bharat_core/indexer/event_parser.ex` | Decodes raw EVM log bytes → typed events |
| `bharat_relayer/worker.ex` | Polls DB for confirmed transfers, calls SolanaClient |
| `bharat_adapters/solana/client.ex` | Shells out to mint_wrapped.js |
| `solana/scripts/mint_wrapped.js` | Anchor client — creates ATA, calls mintTo |
| `bharat_data/transfers.ex` | DB context — all transfer queries |
| `bharat_data/schemas/transfer.ex` | Ecto schema — transfer table shape |
