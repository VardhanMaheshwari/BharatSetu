use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, MintTo, Burn, Mint};

declare_id!("2f9ZmuAt6Aaj62JFdA4VXb71uYUAGat8p7rg7T2VXz5p");

/// NftMintBridge — mints/burns wrapped NFTs (SPL supply=1) for ETH→SOL flow.
///
/// POC simplification: wrapped NFT = fresh SPL mint with max_supply=1, decimals=0.
/// Metadata stored in WrappedNftRecord (metadata_uri points to original NFT's JSON).
/// No Metaplex integration for POC — saves ~300 lines of CPI boilerplate.
#[program]
pub mod nft_mint_bridge {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, relayers: Vec<Pubkey>, threshold: u8) -> Result<()> {
        require!(relayers.len() >= threshold as usize, BridgeError::InvalidThreshold);
        let cfg = &mut ctx.accounts.bridge_config;
        cfg.authority = ctx.accounts.authority.key();
        cfg.relayers  = relayers;
        cfg.threshold = threshold;
        cfg.paused    = false;
        Ok(())
    }

    /// Mint a wrapped NFT on Solana after relayer threshold confirms ETH lock.
    /// A new SPL mint is created per cross_chain_id (one-time, supply=1).
    pub fn mint_wrapped_nft(
        ctx: Context<MintWrappedNft>,
        cross_chain_id: [u8; 32],
        metadata_uri: String,
        metadata_hash: [u8; 32],
        original_contract: [u8; 20],
        original_token_id: u64,
    ) -> Result<()> {
        require!(!ctx.accounts.bridge_config.paused, BridgeError::Paused);
        let record = &mut ctx.accounts.wrapped_nft_record;
        require!(!record.minted, BridgeError::AlreadyMinted);

        record.minted            = true;
        record.cross_chain_id    = cross_chain_id;
        record.mint              = ctx.accounts.wrapped_nft_mint.key();
        record.recipient         = ctx.accounts.recipient.key();
        record.metadata_uri      = metadata_uri.clone();
        record.metadata_hash     = metadata_hash;
        record.original_contract = original_contract;
        record.original_token_id = original_token_id;

        // Mint exactly 1 token (NFT)
        let config_seeds: &[&[u8]] = &[b"nft_config", &[ctx.bumps.bridge_config]];
        let signer = &[config_seeds];

        let cpi_ctx = CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            MintTo {
                mint:      ctx.accounts.wrapped_nft_mint.to_account_info(),
                to:        ctx.accounts.recipient_token_account.to_account_info(),
                authority: ctx.accounts.bridge_config.to_account_info(),
            },
            signer,
        );
        token::mint_to(cpi_ctx, 1)?;

        emit!(WrappedNftMinted {
            cross_chain_id,
            mint: record.mint,
            recipient: record.recipient,
            metadata_uri,
            original_contract,
            original_token_id,
        });
        Ok(())
    }

    /// Burn wrapped NFT (SOL→ETH reverse: burn after ETH releases original).
    pub fn burn_wrapped_nft(
        ctx: Context<BurnWrappedNft>,
        cross_chain_id: [u8; 32],
    ) -> Result<()> {
        let record = &mut ctx.accounts.burn_record;
        require!(!record.burned, BridgeError::AlreadyBurned);
        record.burned         = true;
        record.cross_chain_id = cross_chain_id;

        let cpi_ctx = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            Burn {
                mint:      ctx.accounts.wrapped_nft_mint.to_account_info(),
                from:      ctx.accounts.holder_token_account.to_account_info(),
                authority: ctx.accounts.holder.to_account_info(),
            },
        );
        token::burn(cpi_ctx, 1)?;

        emit!(WrappedNftBurned { cross_chain_id });
        Ok(())
    }
}

// ── Accounts ──────────────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)] pub authority: Signer<'info>,
    #[account(init, payer = authority, space = NftBridgeConfig::SIZE,
        seeds = [b"nft_config"], bump)]
    pub bridge_config: Account<'info, NftBridgeConfig>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(cross_chain_id: [u8; 32])]
pub struct MintWrappedNft<'info> {
    #[account(mut)] pub relayer: Signer<'info>,
    #[account(seeds = [b"nft_config"], bump)] pub bridge_config: Account<'info, NftBridgeConfig>,
    #[account(init, payer = relayer, space = WrappedNftRecord::SIZE,
        seeds = [b"wnft", &cross_chain_id[..]], bump)]
    pub wrapped_nft_record: Account<'info, WrappedNftRecord>,
    /// New mint created for this wrapped NFT (initialized externally before this call)
    #[account(mut)] pub wrapped_nft_mint: Account<'info, Mint>,
    /// CHECK: recipient pubkey
    pub recipient: UncheckedAccount<'info>,
    #[account(mut)] pub recipient_token_account: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

#[derive(Accounts)]
#[instruction(cross_chain_id: [u8; 32])]
pub struct BurnWrappedNft<'info> {
    #[account(mut)] pub holder: Signer<'info>,
    #[account(seeds = [b"nft_config"], bump)] pub bridge_config: Account<'info, NftBridgeConfig>,
    #[account(init, payer = holder, space = BurnNftRecord::SIZE,
        seeds = [b"wburn", &cross_chain_id[..]], bump)]
    pub burn_record: Account<'info, BurnNftRecord>,
    #[account(mut)] pub wrapped_nft_mint: Account<'info, Mint>,
    #[account(mut)] pub holder_token_account: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

// ── State ─────────────────────────────────────────────────────────────────────

#[account]
pub struct NftBridgeConfig {
    pub authority: Pubkey,
    pub relayers:  Vec<Pubkey>,
    pub threshold: u8,
    pub paused:    bool,
}
impl NftBridgeConfig { pub const SIZE: usize = 8 + 32 + (4 + 10 * 32) + 1 + 1 + 64; }

#[account]
pub struct WrappedNftRecord {
    pub minted:            bool,
    pub cross_chain_id:    [u8; 32],
    pub mint:              Pubkey,
    pub recipient:         Pubkey,
    pub metadata_uri:      String,      // max 200
    pub metadata_hash:     [u8; 32],
    pub original_contract: [u8; 20],
    pub original_token_id: u64,
}
impl WrappedNftRecord {
    pub const SIZE: usize = 8 + 1 + 32 + 32 + 32 + (4 + 200) + 32 + 20 + 8 + 64;
}

#[account]
pub struct BurnNftRecord {
    pub burned:         bool,
    pub cross_chain_id: [u8; 32],
}
impl BurnNftRecord { pub const SIZE: usize = 8 + 1 + 32 + 32; }

// ── Events + Errors ───────────────────────────────────────────────────────────

#[event]
pub struct WrappedNftMinted {
    pub cross_chain_id: [u8; 32], pub mint: Pubkey, pub recipient: Pubkey,
    pub metadata_uri: String, pub original_contract: [u8; 20], pub original_token_id: u64,
}
#[event]
pub struct WrappedNftBurned { pub cross_chain_id: [u8; 32] }

#[error_code]
pub enum BridgeError {
    #[msg("Invalid threshold")]  InvalidThreshold,
    #[msg("Already minted")]     AlreadyMinted,
    #[msg("Already burned")]     AlreadyBurned,
    #[msg("Bridge paused")]      Paused,
}
