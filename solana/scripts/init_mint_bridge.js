#!/usr/bin/env node
/**
 * Initialize MintBridge program on Solana devnet.
 * Run once after deploying the program.
 *
 * Uses raw @solana/web3.js only, polling for confirmation (no WebSocket).
 *
 * Anchor discriminators (sha256("global:<name>")[0..8]):
 *   initialize   = afaf6d1f0d989bed
 *   mint_wrapped = 825a1274bc40ccc7
 *
 * Usage: SOLANA_RPC_URL=... node solana/scripts/init_mint_bridge.js
 * Output: SOLANA_WRAPPED_MINT=<base58>  — add to .env
 */

const {
  Connection, Keypair, PublicKey, SystemProgram, Transaction,
  TransactionInstruction, LAMPORTS_PER_SOL,
} = require("@solana/web3.js");
const {
  createMint, TOKEN_PROGRAM_ID,
  createSetAuthorityInstruction, AuthorityType,
} = require("@solana/spl-token");
const fs     = require("fs");
const path   = require("path");
const crypto = require("crypto");

const MINT_BRIDGE_PROGRAM_ID = new PublicKey("Hs7LHuXuAGcXaGtpsuUtHQjxAnZwRGdcqh937xFSPGNv");
const RPC_URL      = process.env.SOLANA_RPC_URL || "https://solana-devnet.g.alchemy.com/v2/Bzb9gqOW7RkhvMCvlmmMs";
const KEYPAIR_PATH = process.env.SOLANA_RELAYER_KEYPAIR || path.join(process.env.HOME, ".config/solana/id.json");

// Anchor discriminator = first 8 bytes of sha256("global:<name>")
function discriminator(name) {
  return crypto.createHash("sha256").update(`global:${name}`).digest().slice(0, 8);
}

// initialize(relayers: Vec<Pubkey>, threshold: u8)
// Borsh: vec_len(u32-LE) + pubkeys(32 each) + threshold(u8)
function encodeInitialize(relayerPubkeys, threshold) {
  const disc    = discriminator("initialize");
  const vecLen  = Buffer.alloc(4);
  vecLen.writeUInt32LE(relayerPubkeys.length, 0);
  const keys    = Buffer.concat(relayerPubkeys.map(pk => pk.toBuffer()));
  const thresh  = Buffer.from([threshold]);
  return Buffer.concat([disc, vecLen, keys, thresh]);
}

// Poll until tx confirmed (no WebSocket needed)
async function confirmTx(connection, sig, maxRetries = 60) {
  console.log("  Waiting for confirmation:", sig.slice(0, 20) + "...");
  for (let i = 0; i < maxRetries; i++) {
    await new Promise(r => setTimeout(r, 2000));
    const status = await connection.getSignatureStatus(sig, { searchTransactionHistory: true });
    const val = status?.value;
    if (!val) continue;
    if (val.err) throw new Error(`Transaction failed: ${JSON.stringify(val.err)}`);
    if (val.confirmationStatus === "confirmed" || val.confirmationStatus === "finalized") {
      console.log("  Confirmed:", val.confirmationStatus);
      return;
    }
  }
  throw new Error(`Timeout waiting for tx ${sig}`);
}

// Send transaction and poll for confirmation
async function sendAndWait(connection, tx, signers) {
  const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash("confirmed");
  tx.recentBlockhash  = blockhash;
  tx.feePayer         = signers[0].publicKey;
  tx.lastValidBlockHeight = lastValidBlockHeight;
  tx.sign(...signers);
  const sig = await connection.sendRawTransaction(tx.serialize(), { skipPreflight: false });
  await confirmTx(connection, sig);
  return sig;
}

async function main() {
  const connection   = new Connection(RPC_URL, {
    commitment: "confirmed",
    wsEndpoint: undefined,   // disable WebSocket
    disableRetryOnRateLimit: false,
  });
  const keypairData  = JSON.parse(fs.readFileSync(KEYPAIR_PATH, "utf8"));
  const relayer      = Keypair.fromSecretKey(Uint8Array.from(keypairData));

  console.log("Relayer pubkey:", relayer.publicKey.toBase58());
  console.log("RPC:", RPC_URL);

  const bal = await connection.getBalance(relayer.publicKey);
  console.log("Balance:", bal / LAMPORTS_PER_SOL, "SOL");
  if (bal < 0.1 * LAMPORTS_PER_SOL) {
    console.error("Need at least 0.1 SOL. Fund: solana airdrop 2 --url devnet");
    process.exit(1);
  }

  // Derive bridge_config PDA
  const [configPda, configBump] = PublicKey.findProgramAddressSync(
    [Buffer.from("config")],
    MINT_BRIDGE_PROGRAM_ID
  );
  console.log("bridge_config PDA:", configPda.toBase58(), "bump:", configBump);

  const configAcct = await connection.getAccountInfo(configPda);
  let wrappedMint;

  let needsMint = true;
  if (configAcct) {
    console.log("bridge_config already exists — skipping initialize instruction");
    const envMint = process.env.SOLANA_WRAPPED_MINT;
    if (envMint) {
      wrappedMint = new PublicKey(envMint);
      console.log("Wrapped mint from env:", wrappedMint.toBase58());
      needsMint = false;
    } else {
      console.log("Creating new wrapped mint and transferring authority to existing bridge_config...");
    }
  }
  
  if (needsMint) {
    // Step 1: Create wrapped SPL mint (9 decimals)
    console.log("\nCreating wrapped SPL mint (9 decimals)...");

    const mintKp = Keypair.generate();
    const mintRent = await connection.getMinimumBalanceForRentExemption(82);

    const createMintTx = new Transaction().add(
      SystemProgram.createAccount({
        fromPubkey:  relayer.publicKey,
        newAccountPubkey: mintKp.publicKey,
        space:       82,
        lamports:    mintRent,
        programId:   TOKEN_PROGRAM_ID,
      }),
      new TransactionInstruction({
        programId: TOKEN_PROGRAM_ID,
        keys: [
          { pubkey: mintKp.publicKey,  isSigner: false, isWritable: true },
          { pubkey: new PublicKey("SysvarRent111111111111111111111111111111111"), isSigner: false, isWritable: false },
        ],
        data: (() => {
          const buf = Buffer.alloc(67);
          buf.writeUInt8(0, 0);           // InitializeMint opcode
          buf.writeUInt8(9, 1);           // decimals
          relayer.publicKey.toBuffer().copy(buf, 2); // mintAuthority
          buf.writeUInt8(0, 34);          // coption = 0 (no freeze authority)
          return buf;
        })(),
      })
    );

    const mintSig = await sendAndWait(connection, createMintTx, [relayer, mintKp]);
    wrappedMint = mintKp.publicKey;
    console.log("Wrapped SPL mint:", wrappedMint.toBase58());
    console.log("createMint tx:", mintSig);

    if (!configAcct) {
      // Step 2: Call initialize([relayer], threshold=1)
      console.log("\nCalling initialize([relayer], threshold=1)...");
      const initData = encodeInitialize([relayer.publicKey], 1);
      const initIx   = new TransactionInstruction({
        programId: MINT_BRIDGE_PROGRAM_ID,
        keys: [
          { pubkey: relayer.publicKey,          isSigner: true,  isWritable: true  },
          { pubkey: configPda,                  isSigner: false, isWritable: true  },
          { pubkey: SystemProgram.programId,    isSigner: false, isWritable: false },
        ],
        data: initData,
      });
      const initSig = await sendAndWait(connection, new Transaction().add(initIx), [relayer]);
      console.log("initialize tx:", initSig);
    }

    // Step 3: Transfer mint authority to bridge_config PDA
    console.log("\nTransferring mint authority to PDA...");
    const setAuthIx = createSetAuthorityInstruction(
      wrappedMint,
      relayer.publicKey,
      AuthorityType.MintTokens,
      configPda,
    );
    const setAuthSig = await sendAndWait(connection, new Transaction().add(setAuthIx), [relayer]);
    console.log("mint authority transferred, tx:", setAuthSig);
  }

  console.log("\n=== Add to .env ===");
  if (wrappedMint) {
    console.log(`SOLANA_WRAPPED_MINT=${wrappedMint.toBase58()}`);
  }
  console.log("===================\n");

  const finalAcct = await connection.getAccountInfo(configPda);
  if (finalAcct) {
    console.log("bridge_config size:", finalAcct.data.length, "bytes");
    console.log("bridge_config owner:", finalAcct.owner.toBase58());
  }
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
