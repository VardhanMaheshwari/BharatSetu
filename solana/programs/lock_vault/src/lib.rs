use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer as SplTransfer, Mint};

declare_id!("FEb6GdiTHqUvpxui8SZnNLW6NeDNbs3Xhb7vg24UbPtT");

/// LockVault — escrow for SPL tokens on Solana side of cross-chain channel.
///
/// Forward flow  (SOL→ETH): user locks SPL tokens here, hub relayer observes
///   the LockRecord and triggers EthVault.unlock on Ethereum.
///
/// Reverse flow (ETH→SOL): MintBridge mints wrapped SPL on this side;
///   for the burn path this program is not involved.
///
/// Timeout: if hub doesn't commit within timeout_at, sender calls claim_timeout
///   to recover their tokens.
#[program]
pub mod lock_vault {
    use super::*;

    /// Lock SPL tokens for SOL→ETH transfer.
    pub fn lock_tokens(
        ctx: Context<LockTokens>,
        cross_chain_id: [u8; 32],
        amount: u64,
        dest_eth_wallet: [u8; 20],  // Ethereum address (20 bytes)
        timeout_sec: i64,
    ) -> Result<()> {
        require!(amount > 0, VaultError::ZeroAmount);

        let record = &mut ctx.accounts.lock_record;
        require!(!record.initialized, VaultError::AlreadyLocked);

        let clock = Clock::get()?;
        record.initialized   = true;
        record.sender        = ctx.accounts.sender.key();
        record.mint          = ctx.accounts.sender_token_account.mint;
        record.amount        = amount;
        record.cross_chain_id = cross_chain_id;
        record.dest_eth_wallet = dest_eth_wallet;
        record.timeout_at    = clock.unix_timestamp + timeout_sec;
        record.committed     = false;
        record.refunded      = false;

        // Transfer SPL tokens from sender to vault ATA
        let cpi_ctx = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            SplTransfer {
                from:      ctx.accounts.sender_token_account.to_account_info(),
                to:        ctx.accounts.vault_token_account.to_account_info(),
                authority: ctx.accounts.sender.to_account_info(),
            },
        );
        token::transfer(cpi_ctx, amount)?;

        // Nonce hash matches hub expectation:
        // keccak256(chain="solana" ++ sender_pubkey ++ cross_chain_id)
        let nonce_input = [
            b"solana".as_ref(),
            ctx.accounts.sender.key().as_ref(),
            &cross_chain_id,
        ].concat();
        let nonce_hash = anchor_lang::solana_program::keccak::hashv(&[&nonce_input]).0;

        emit!(TokenLocked {
            sender:         ctx.accounts.sender.key(),
            mint:           record.mint,
            amount,
            cross_chain_id,
            nonce_hash,
            dest_eth_wallet,
            timeout_at:     record.timeout_at,
        });

        Ok(())
    }

    /// Relayer commits transfer after ETH side confirmed.
    pub fn commit_transfer(
        ctx: Context<RelayerAction>,
        _cross_chain_id: [u8; 32],
    ) -> Result<()> {
        let record = &mut ctx.accounts.lock_record;
        require!(record.initialized, VaultError::NotLocked);
        require!(!record.committed && !record.refunded, VaultError::AlreadyFinalized);

        record.committed = true;
        emit!(TransferCommitted { cross_chain_id: record.cross_chain_id });
        Ok(())
    }

    /// Sender reclaims tokens after timeout (hub failed to commit).
    pub fn claim_timeout(ctx: Context<ClaimTimeout>, _cross_chain_id: [u8; 32]) -> Result<()> {
        let record = &mut ctx.accounts.lock_record;
        require!(record.initialized, VaultError::NotLocked);
        require!(!record.committed && !record.refunded, VaultError::AlreadyFinalized);

        let clock = Clock::get()?;
        require!(clock.unix_timestamp >= record.timeout_at, VaultError::NotTimedOut);
        require!(ctx.accounts.sender.key() == record.sender, VaultError::NotOwner);

        record.refunded = true;

        // Return tokens to sender
        let vault_seeds: &[&[u8]] = &[
            b"vault",
            &record.cross_chain_id[..],
            &[ctx.bumps.vault_authority],
        ];
        let signer = &[vault_seeds];

        let cpi_ctx = CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            SplTransfer {
                from:      ctx.accounts.vault_token_account.to_account_info(),
                to:        ctx.accounts.sender_token_account.to_account_info(),
                authority: ctx.accounts.vault_authority.to_account_info(),
            },
            signer,
        );
        token::transfer(cpi_ctx, record.amount)?;

        emit!(TransferRefunded {
            cross_chain_id: record.cross_chain_id,
            sender:         record.sender,
            amount:         record.amount,
        });
        Ok(())
    }
}

// ── Accounts ──────────────────────────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(cross_chain_id: [u8; 32])]
pub struct LockTokens<'info> {
    #[account(mut)]
    pub sender: Signer<'info>,

    #[account(
        init,
        payer = sender,
        space = LockRecord::SIZE,
        seeds = [b"lock", &cross_chain_id[..]],
        bump
    )]
    pub lock_record: Account<'info, LockRecord>,

    /// CHECK: PDA authority over vault token account
    #[account(seeds = [b"vault", &cross_chain_id[..]], bump)]
    pub vault_authority: UncheckedAccount<'info>,

    #[account(
        init_if_needed,
        payer = sender,
        associated_token::mint = mint,
        associated_token::authority = vault_authority,
    )]
    pub vault_token_account: Account<'info, TokenAccount>,

    #[account(mut, associated_token::mint = mint, associated_token::authority = sender)]
    pub sender_token_account: Account<'info, TokenAccount>,

    pub mint: Account<'info, Mint>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub associated_token_program: Program<'info, anchor_spl::associated_token::AssociatedToken>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
#[instruction(_cross_chain_id: [u8; 32])]
pub struct RelayerAction<'info> {
    pub relayer: Signer<'info>,

    #[account(
        mut,
        seeds = [b"lock", &lock_record.cross_chain_id[..]],
        bump
    )]
    pub lock_record: Account<'info, LockRecord>,
}

#[derive(Accounts)]
#[instruction(_cross_chain_id: [u8; 32])]
pub struct ClaimTimeout<'info> {
    #[account(mut)]
    pub sender: Signer<'info>,

    #[account(
        mut,
        seeds = [b"lock", &lock_record.cross_chain_id[..]],
        bump
    )]
    pub lock_record: Account<'info, LockRecord>,

    /// CHECK: PDA authority
    #[account(seeds = [b"vault", &lock_record.cross_chain_id[..]], bump)]
    pub vault_authority: UncheckedAccount<'info>,

    #[account(mut)]
    pub vault_token_account: Account<'info, TokenAccount>,

    #[account(mut)]
    pub sender_token_account: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
}

// ── State ─────────────────────────────────────────────────────────────────────

#[account]
pub struct LockRecord {
    pub initialized:    bool,
    pub sender:         Pubkey,
    pub mint:           Pubkey,
    pub amount:         u64,
    pub cross_chain_id: [u8; 32],
    pub dest_eth_wallet: [u8; 20],
    pub timeout_at:     i64,
    pub committed:      bool,
    pub refunded:       bool,
}

impl LockRecord {
    pub const SIZE: usize = 8   // discriminator
        + 1   // initialized
        + 32  // sender
        + 32  // mint
        + 8   // amount
        + 32  // cross_chain_id
        + 20  // dest_eth_wallet
        + 8   // timeout_at
        + 1   // committed
        + 1   // refunded
        + 64; // padding
}

// ── Events ────────────────────────────────────────────────────────────────────

#[event]
pub struct TokenLocked {
    pub sender:          Pubkey,
    pub mint:            Pubkey,
    pub amount:          u64,
    pub cross_chain_id:  [u8; 32],
    pub nonce_hash:      [u8; 32],
    pub dest_eth_wallet: [u8; 20],
    pub timeout_at:      i64,
}

#[event]
pub struct TransferCommitted { pub cross_chain_id: [u8; 32] }

#[event]
pub struct TransferRefunded {
    pub cross_chain_id: [u8; 32],
    pub sender:         Pubkey,
    pub amount:         u64,
}

// ── Errors ────────────────────────────────────────────────────────────────────

#[error_code]
pub enum VaultError {
    #[msg("Amount must be > 0")]           ZeroAmount,
    #[msg("Already locked")]               AlreadyLocked,
    #[msg("Lock not found")]               NotLocked,
    #[msg("Transfer already finalized")]   AlreadyFinalized,
    #[msg("Timeout not reached yet")]      NotTimedOut,
    #[msg("Not the original sender")]      NotOwner,
}
