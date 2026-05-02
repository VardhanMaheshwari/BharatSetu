#!/usr/bin/env node
/**
 * Mint wrapped SPL tokens for an ETH→SOL bridge transfer.
 *
 * Called by BharatRelayer.Worker via System.cmd for each confirmed transfer.
 *
 * Usage:
 *   node solana/scripts/mint_wrapped.js \
 *     <cross_chain_id_hex> <amount_spl_lamports> <eth_lock_nonce_hex> <dest_solana_wallet>
 *
 * Prints: MINT_SIG=<base58_signature>  on success
 * Exits 1 on failure.
 *
 * Environment:
 *   SOLANA_RPC_URL        — Alchemy devnet URL
 *   SOLANA_RELAYER_KEYPAIR — path to keypair JSON
 *   SOLANA_WRAPPED_MINT   — base58 address of wrapped SPL mint
 */

const {
  Connection, Keypair, PublicKey, SystemProgram, Transaction,
  TransactionInstruction, SYSVAR_RENT_PUBKEY,
} = require("@solana/web3.js");
const {
  getAssociatedTokenAddress,
  createAssociatedTokenAccountInstruction,
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
} = require("@solana/spl-token");
const fs     = require("fs");
const path   = require("path");
const crypto = require("crypto");

const MINT_BRIDGE_PROGRAM_ID = new PublicKey("Hs7LHuXuAGcXaGtpsuUtHQjxAnZwRGdcqh937xFSPGNv");
const RPC_URL      = process.env.SOLANA_RPC_URL || "https://api.devnet.solana.com";
const KEYPAIR_PATH = (process.env.SOLANA_RELAYER_KEYPAIR || "~/.config/solana/id.json")
                       .replace(/^~/, process.env.HOME || "");
const WRAPPED_MINT = process.env.SOLANA_WRAPPED_MINT;

// Anchor discriminator = sha256("global:<name>")[0..8]
function discriminator(name) {
  return crypto.createHash("sha256").update(`global:${name}`).digest().slice(0, 8);
}
const MINT_WRAPPED_DISC = discriminator("mint_wrapped");

// Poll for tx confirmation (no WebSocket)
async function waitConfirmed(connection, sig, retries = 60) {
  for (let i = 0; i < retries; i++) {
    await new Promise(r => setTimeout(r, 2000));
    const status = await connection.getSignatureStatus(sig, { searchTransactionHistory: true });
    const val = status?.value;
    if (!val) continue;
    if (val.err) throw new Error(`Tx failed: ${JSON.stringify(val.err)}`);
    if (val.confirmationStatus === "confirmed" || val.confirmationStatus === "finalized") return;
  }
  throw new Error(`Timeout waiting for ${sig}`);
}

async function sendAndWait(connection, tx, signers) {
  const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash("confirmed");
  tx.recentBlockhash = blockhash;
  tx.feePayer        = signers[0].publicKey;
  tx.sign(...signers);
  const sig = await connection.sendRawTransaction(tx.serialize(), { skipPreflight: false });
  await waitConfirmed(connection, sig);
  return sig;
}

async function main() {
  const [crossChainIdHex, amountStr, ethLockNonceHex, destWallet] = process.argv.slice(2);

  if (!crossChainIdHex || !amountStr || !ethLockNonceHex || !destWallet) {
    console.error("Usage: mint_wrapped.js <cross_chain_id_hex> <amount_spl> <eth_lock_nonce_hex> <dest_wallet>");
    process.exit(1);
  }
  if (!WRAPPED_MINT) {
    console.error("SOLANA_WRAPPED_MINT not set");
    process.exit(1);
  }

  const connection = new Connection(RPC_URL, { commitment: "confirmed", wsEndpoint: undefined });
  const relayer    = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(fs.readFileSync(KEYPAIR_PATH))));
  const wrappedMint = new PublicKey(WRAPPED_MINT);
  const destPk      = new PublicKey(destWallet);

  // Parse args
  const hexToBytes32 = (hex) => {
    const h = hex.startsWith("0x") ? hex.slice(2) : hex;
    return Buffer.from(h.padStart(64, "0"), "hex");
  };
  const ccidBytes   = hexToBytes32(crossChainIdHex);
  const nonceBytes  = hexToBytes32(ethLockNonceHex);
  const amount      = BigInt(amountStr);

  // Derive PDAs
  const [configPda]     = PublicKey.findProgramAddressSync([Buffer.from("config")], MINT_BRIDGE_PROGRAM_ID);
  const [mintRecordPda] = PublicKey.findProgramAddressSync([Buffer.from("mint"), ccidBytes], MINT_BRIDGE_PROGRAM_ID);

  console.error("bridge_config PDA:", configPda.toBase58());
  console.error("mint_record PDA:", mintRecordPda.toBase58());

  // Ensure recipient ATA exists
  const recipientAta = await getAssociatedTokenAddress(wrappedMint, destPk, false);
  console.error("recipient ATA:", recipientAta.toBase58());

  const ataInfo = await connection.getAccountInfo(recipientAta);
  if (!ataInfo) {
    console.error("Creating ATA for recipient...");
    const createAtaTx = new Transaction().add(
      createAssociatedTokenAccountInstruction(
        relayer.publicKey,  // payer
        recipientAta,       // ata
        destPk,             // owner
        wrappedMint,        // mint
      )
    );
    const ataSig = await sendAndWait(connection, createAtaTx, [relayer]);
    console.error("ATA created, tx:", ataSig);
  }

  // Build mint_wrapped instruction data
  // Borsh: discriminator(8) + cross_chain_id([u8;32]) + amount(u64-LE) + eth_lock_nonce([u8;32])
  const amountLE = Buffer.alloc(8);
  amountLE.writeBigUInt64LE(amount, 0);
  const ixData = Buffer.concat([MINT_WRAPPED_DISC, ccidBytes, amountLE, nonceBytes]);

  const mintIx = new TransactionInstruction({
    programId: MINT_BRIDGE_PROGRAM_ID,
    keys: [
      { pubkey: relayer.publicKey, isSigner: true,  isWritable: true  },
      { pubkey: configPda,         isSigner: false, isWritable: false },
      { pubkey: mintRecordPda,     isSigner: false, isWritable: true  },
      { pubkey: wrappedMint,       isSigner: false, isWritable: true  },
      { pubkey: recipientAta,      isSigner: false, isWritable: true  },
      { pubkey: TOKEN_PROGRAM_ID,  isSigner: false, isWritable: false },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
      { pubkey: SYSVAR_RENT_PUBKEY, isSigner: false, isWritable: false },
    ],
    data: ixData,
  });

  console.error(`Minting ${amount} SPL lamports to ${recipientAta.toBase58()}...`);
  const tx  = new Transaction().add(mintIx);
  const sig = await sendAndWait(connection, tx, [relayer]);

  // Success — print sig for Elixir to capture
  console.log(`MINT_SIG=${sig}`);
  console.error("mint_wrapped success:", sig);
}

main().catch((e) => {
  console.error("mint_wrapped FAILED:", e.message || e);
  process.exit(1);
});
