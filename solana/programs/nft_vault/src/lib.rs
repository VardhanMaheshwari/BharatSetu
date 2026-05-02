use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer as SplTransfer, Mint};

declare_id!("FKAZg2HtpsBbT2gvZcBN36bMo3XVnLLUBRncfDRsD26w");

/// NftVault — escrow for NFTs (SPL tokens with supply=1) on the Solana side.
///
/// POC simplification: "NFT" = SPL token with max_supply=1 and decimals=0.
/// No full Metaplex metadata program integration (would require mpl-token-metadata
/// CPI which adds significant complexity). Metadata stored in the LockRecord
/// as a URI string pointing to IPFS/arweave JSON.
///
/// Forward (SOL→ETH): lock NFT here, hub mints wrapped ERC721 on ETH.
/// Reverse (ETH→SOL): unlock NFT here after ETH side burns wrapped ERC721.
#[program]
pub mod nft_vault {
    use super::*;

    pub fn lock_nft(
        ctx: Context<LockNft>,
        cross_chain_id: [u8; 32],
        dest_eth_wallet: [u8; 20],
        metadata_uri: String,
        metadata_hash: [u8; 32],
        timeout_sec: i64,
    ) -> Result<()> {
        require!(metadata_uri.len() <= 200, NftVaultError::MetadataTooLong);
        require!(ctx.accounts.sender_token_account.amount == 1, NftVaultError::NotNFT);

        let record = &mut ctx.accounts.lock_record;
        require!(!record.initialized, NftVaultError::AlreadyLocked);

        let clock = Clock::get()?;
        record.initialized    = true;
        record.sender         = ctx.accounts.sender.key();
        record.mint           = ctx.accounts.nft_mint.key();
        record.cross_chain_id = cross_chain_id;
        record.dest_eth_wallet = dest_eth_wallet;
        record.metadata_uri   = metadata_uri.clone();
        record.metadata_hash  = metadata_hash;
        record.timeout_at     = clock.unix_timestamp + timeout_sec;
        record.committed      = false;
        record.refunded       = false;

        // Transfer NFT (amount=1) to vault
        let cpi_ctx = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            SplTransfer {
                from:      ctx.accounts.sender_token_account.to_account_info(),
                to:        ctx.accounts.vault_token_account.to_account_info(),
                authority: ctx.accounts.sender.to_account_info(),
            },
        );
        token::transfer(cpi_ctx, 1)?;

        let nonce_hash = anchor_lang::solana_program::keccak::hashv(&[
            b"nft", ctx.accounts.sender.key().as_ref(), &cross_chain_id
        ]).0;

        emit!(NftLocked {
            sender: ctx.accounts.sender.key(),
            mint:   record.mint,
            cross_chain_id,
            nonce_hash,
            dest_eth_wallet,
            metadata_uri,
            metadata_hash,
            timeout_at: record.timeout_at,
        });
        Ok(())
    }

    /// Relayer unlocks NFT back to dest after ETH wrapped NFT burned.
    pub fn unlock_nft(
        ctx: Context<UnlockNft>,
        _cross_chain_id: [u8; 32],
    ) -> Result<()> {
        let record = &mut ctx.accounts.lock_record;
        require!(record.initialized, NftVaultError::NotLocked);
        require!(!record.committed && !record.refunded, NftVaultError::AlreadyFinalized);

        record.committed = true;

        let vault_seeds: &[&[u8]] = &[
            b"nft_vault", &record.cross_chain_id[..], &[ctx.bumps.vault_authority]
        ];
        let signer = &[vault_seeds];

        let cpi_ctx = CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            SplTransfer {
                from:      ctx.accounts.vault_token_account.to_account_info(),
                to:        ctx.accounts.recipient_token_account.to_account_info(),
                authority: ctx.accounts.vault_authority.to_account_info(),
            },
            signer,
        );
        token::transfer(cpi_ctx, 1)?;

        emit!(NftUnlocked {
            cross_chain_id: record.cross_chain_id,
            recipient: ctx.accounts.recipient_token_account.owner,
        });
        Ok(())
    }

    pub fn claim_timeout(ctx: Context<NftClaimTimeout>, _cross_chain_id: [u8; 32]) -> Result<()> {
        let record = &mut ctx.accounts.lock_record;
        require!(record.initialized, NftVaultError::NotLocked);
        require!(!record.committed && !record.refunded, NftVaultError::AlreadyFinalized);
        let clock = Clock::get()?;
        require!(clock.unix_timestamp >= record.timeout_at, NftVaultError::NotTimedOut);
        require!(ctx.accounts.sender.key() == record.sender, NftVaultError::NotOwner);

        record.refunded = true;

        let vault_seeds: &[&[u8]] = &[
            b"nft_vault", &record.cross_chain_id[..], &[ctx.bumps.vault_authority]
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
        token::transfer(cpi_ctx, 1)?;
        emit!(NftRefunded { cross_chain_id: record.cross_chain_id, sender: record.sender });
        Ok(())
    }
}

// ── Accounts ──────────────────────────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(cross_chain_id: [u8; 32])]
pub struct LockNft<'info> {
    #[account(mut)] pub sender: Signer<'info>,
    #[account(
        init, payer = sender, space = NftLockRecord::SIZE,
        seeds = [b"nft_lock", &cross_chain_id[..]], bump
    )]
    pub lock_record: Account<'info, NftLockRecord>,
    /// CHECK: PDA authority
    #[account(seeds = [b"nft_vault", &cross_chain_id[..]], bump)]
    pub vault_authority: UncheckedAccount<'info>,
    #[account(init_if_needed, payer = sender,
        associated_token::mint = nft_mint,
        associated_token::authority = vault_authority)]
    pub vault_token_account: Account<'info, TokenAccount>,
    #[account(mut, associated_token::mint = nft_mint, associated_token::authority = sender)]
    pub sender_token_account: Account<'info, TokenAccount>,
    pub nft_mint: Account<'info, Mint>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub associated_token_program: Program<'info, anchor_spl::associated_token::AssociatedToken>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
#[instruction(_cross_chain_id: [u8; 32])]
pub struct UnlockNft<'info> {
    pub relayer: Signer<'info>,
    #[account(mut, seeds = [b"nft_lock", &lock_record.cross_chain_id[..]], bump)]
    pub lock_record: Account<'info, NftLockRecord>,
    /// CHECK: PDA
    #[account(seeds = [b"nft_vault", &lock_record.cross_chain_id[..]], bump)]
    pub vault_authority: UncheckedAccount<'info>,
    #[account(mut)] pub vault_token_account: Account<'info, TokenAccount>,
    #[account(mut)] pub recipient_token_account: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
#[instruction(_cross_chain_id: [u8; 32])]
pub struct NftClaimTimeout<'info> {
    #[account(mut)] pub sender: Signer<'info>,
    #[account(mut, seeds = [b"nft_lock", &lock_record.cross_chain_id[..]], bump)]
    pub lock_record: Account<'info, NftLockRecord>,
    /// CHECK: PDA
    #[account(seeds = [b"nft_vault", &lock_record.cross_chain_id[..]], bump)]
    pub vault_authority: UncheckedAccount<'info>,
    #[account(mut)] pub vault_token_account: Account<'info, TokenAccount>,
    #[account(mut)] pub sender_token_account: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

// ── State ─────────────────────────────────────────────────────────────────────

#[account]
pub struct NftLockRecord {
    pub initialized:    bool,
    pub sender:         Pubkey,
    pub mint:           Pubkey,
    pub cross_chain_id: [u8; 32],
    pub dest_eth_wallet: [u8; 20],
    pub metadata_uri:   String,      // max 200 chars
    pub metadata_hash:  [u8; 32],
    pub timeout_at:     i64,
    pub committed:      bool,
    pub refunded:       bool,
}
impl NftLockRecord {
    pub const SIZE: usize = 8 + 1 + 32 + 32 + 32 + 20 + (4 + 200) + 32 + 8 + 1 + 1 + 64;
}

// ── Events + Errors ───────────────────────────────────────────────────────────

#[event]
pub struct NftLocked {
    pub sender: Pubkey, pub mint: Pubkey,
    pub cross_chain_id: [u8; 32], pub nonce_hash: [u8; 32],
    pub dest_eth_wallet: [u8; 20],
    pub metadata_uri: String, pub metadata_hash: [u8; 32],
    pub timeout_at: i64,
}
#[event]
pub struct NftUnlocked { pub cross_chain_id: [u8; 32], pub recipient: Pubkey }
#[event]
pub struct NftRefunded { pub cross_chain_id: [u8; 32], pub sender: Pubkey }

#[error_code]
pub enum NftVaultError {
    #[msg("Already locked")]            AlreadyLocked,
    #[msg("Not locked")]                NotLocked,
    #[msg("Already finalized")]         AlreadyFinalized,
    #[msg("Timeout not reached")]       NotTimedOut,
    #[msg("Not original sender")]       NotOwner,
    #[msg("Token supply must be 1")]    NotNFT,
    #[msg("Metadata URI too long")]     MetadataTooLong,
}
