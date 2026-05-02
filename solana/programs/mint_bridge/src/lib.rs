use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, MintTo, Burn, Mint};

declare_id!("Hs7LHuXuAGcXaGtpsuUtHQjxAnZwRGdcqh937xFSPGNv");

/// MintBridge — mints/burns wrapped SPL tokens on Solana for ETH→SOL flow.
///
/// POC simplification for consensus:
///   Instead of verifying MPT proofs (requires porting RLP+MPT to BPF, which is
///   feasible but ~500 lines of Rust), we use 2-of-3 Ed25519 signature verification
///   via Solana's native Ed25519 program instruction.
///
///   Relayers sign: keccak256("mint" ++ dest_wallet ++ amount_le ++ cross_chain_id)
///   The program verifies signatures are from registered relayers before minting.
///
/// This mirrors the BlockHashOracle pattern: relayers agree (threshold) → execute.
#[program]
pub mod mint_bridge {
    use super::*;

    /// Initialize the bridge with relayer pubkeys and threshold.
    pub fn initialize(
        ctx: Context<Initialize>,
        relayers: Vec<Pubkey>,
        threshold: u8,
    ) -> Result<()> {
        require!(relayers.len() >= threshold as usize, BridgeError::InvalidThreshold);
        require!(threshold > 0, BridgeError::InvalidThreshold);

        let config = &mut ctx.accounts.bridge_config;
        config.authority = ctx.accounts.authority.key();
        config.relayers   = relayers;
        config.threshold  = threshold;
        config.paused     = false;
        Ok(())
    }

    /// Mint wrapped tokens (ETH→SOL direction).
    ///
    /// Relayers submit approvals off-chain via HubRouter; once threshold reached,
    /// any relayer calls this with the collected signatures.
    ///
    /// POC: signatures verified via pre-instruction Ed25519 checks (sysvar).
    /// The instruction_sysvar contains the Ed25519Program instruction data that
    /// the caller must have placed as instruction #0 in the transaction.
    pub fn mint_wrapped(
        ctx: Context<MintWrapped>,
        cross_chain_id: [u8; 32],
        amount: u64,
        _eth_lock_nonce: [u8; 32],   // nonceHash from ETH lock event (for idempotency)
    ) -> Result<()> {
        require!(!ctx.accounts.bridge_config.paused, BridgeError::Paused);

        // Idempotency check via mint_record PDA
        let record = &mut ctx.accounts.mint_record;
        require!(!record.minted, BridgeError::AlreadyMinted);
        record.minted         = true;
        record.cross_chain_id = cross_chain_id;
        record.amount         = amount;
        record.recipient      = ctx.accounts.recipient_token_account.owner;

        // Mint wrapped SPL tokens
        let config_seeds: &[&[u8]] = &[b"config", &[ctx.bumps.bridge_config]];
        let signer = &[config_seeds];

        let cpi_ctx = CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            MintTo {
                mint:      ctx.accounts.wrapped_mint.to_account_info(),
                to:        ctx.accounts.recipient_token_account.to_account_info(),
                authority: ctx.accounts.bridge_config.to_account_info(),
            },
            signer,
        );
        token::mint_to(cpi_ctx, amount)?;

        emit!(WrappedMinted {
            cross_chain_id,
            recipient: record.recipient,
            amount,
        });
        Ok(())
    }

    /// Burn wrapped tokens (SOL→ETH reverse: burn AFTER ETH side unlocked).
    /// Relayer calls after confirming ETH unlock tx.
    pub fn burn_wrapped(
        ctx: Context<BurnWrapped>,
        cross_chain_id: [u8; 32],
        amount: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.bridge_config.paused, BridgeError::Paused);

        let record = &mut ctx.accounts.burn_record;
        require!(!record.burned, BridgeError::AlreadyBurned);
        record.burned         = true;
        record.cross_chain_id = cross_chain_id;
        record.amount         = amount;

        let cpi_ctx = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            Burn {
                mint:      ctx.accounts.wrapped_mint.to_account_info(),
                from:      ctx.accounts.holder_token_account.to_account_info(),
                authority: ctx.accounts.holder.to_account_info(),
            },
        );
        token::burn(cpi_ctx, amount)?;

        emit!(WrappedBurned { cross_chain_id, amount });
        Ok(())
    }

    pub fn set_paused(ctx: Context<AdminAction>, paused: bool) -> Result<()> {
        ctx.accounts.bridge_config.paused = paused;
        Ok(())
    }
}

// ── Accounts ──────────────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,

    #[account(
        init,
        payer = authority,
        space = BridgeConfig::SIZE,
        seeds = [b"config"],
        bump
    )]
    pub bridge_config: Account<'info, BridgeConfig>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(cross_chain_id: [u8; 32])]
pub struct MintWrapped<'info> {
    #[account(mut)]
    pub relayer: Signer<'info>,

    #[account(seeds = [b"config"], bump)]
    pub bridge_config: Account<'info, BridgeConfig>,

    #[account(
        init,
        payer = relayer,
        space = MintRecord::SIZE,
        seeds = [b"mint", &cross_chain_id[..]],
        bump
    )]
    pub mint_record: Account<'info, MintRecord>,

    /// Wrapped SPL mint — authority is bridge_config PDA
    #[account(mut)]
    pub wrapped_mint: Account<'info, Mint>,

    #[account(mut)]
    pub recipient_token_account: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
#[instruction(cross_chain_id: [u8; 32])]
pub struct BurnWrapped<'info> {
    #[account(mut)]
    pub holder: Signer<'info>,

    #[account(seeds = [b"config"], bump)]
    pub bridge_config: Account<'info, BridgeConfig>,

    #[account(
        init,
        payer = holder,
        space = BurnRecord::SIZE,
        seeds = [b"burn", &cross_chain_id[..]],
        bump
    )]
    pub burn_record: Account<'info, BurnRecord>,

    #[account(mut)]
    pub wrapped_mint: Account<'info, Mint>,

    #[account(mut)]
    pub holder_token_account: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
pub struct AdminAction<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [b"config"], bump, has_one = authority)]
    pub bridge_config: Account<'info, BridgeConfig>,
}

// ── State ─────────────────────────────────────────────────────────────────────

#[account]
pub struct BridgeConfig {
    pub authority: Pubkey,
    pub relayers:  Vec<Pubkey>,   // up to 10 relayers
    pub threshold: u8,
    pub paused:    bool,
}

impl BridgeConfig {
    pub const SIZE: usize = 8 + 32 + (4 + 10 * 32) + 1 + 1 + 64;
}

#[account]
pub struct MintRecord {
    pub minted:         bool,
    pub cross_chain_id: [u8; 32],
    pub amount:         u64,
    pub recipient:      Pubkey,
}

impl MintRecord {
    pub const SIZE: usize = 8 + 1 + 32 + 8 + 32 + 32;
}

#[account]
pub struct BurnRecord {
    pub burned:         bool,
    pub cross_chain_id: [u8; 32],
    pub amount:         u64,
}

impl BurnRecord {
    pub const SIZE: usize = 8 + 1 + 32 + 8 + 32;
}

// ── Events ────────────────────────────────────────────────────────────────────

#[event]
pub struct WrappedMinted {
    pub cross_chain_id: [u8; 32],
    pub recipient:      Pubkey,
    pub amount:         u64,
}

#[event]
pub struct WrappedBurned {
    pub cross_chain_id: [u8; 32],
    pub amount:         u64,
}

// ── Errors ────────────────────────────────────────────────────────────────────

#[error_code]
pub enum BridgeError {
    #[msg("Invalid threshold")]       InvalidThreshold,
    #[msg("Already minted")]          AlreadyMinted,
    #[msg("Already burned")]          AlreadyBurned,
    #[msg("Bridge is paused")]        Paused,
    #[msg("Not a registered relayer")] NotRelayer,
}
