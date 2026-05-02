defmodule BharatData.Repo.Migrations.ExtendTransfersChannel do
  use Ecto.Migration

  def change do
    alter table(:transfers) do
      # Channel linkage
      add :channel_id,        :string                 # "eth-sol-v1"
      add :cross_chain_id,    :string                 # deterministic unique id (hex bytes32)

      # Token version for reverse flows
      add :token_version,     :string, default: "original"  # "original" | "wrapped"
      add :wrapped_token_ref, :string                 # token_registry id

      # Solana-side tx tracking
      add :solana_signature,  :string                 # base58 lock tx on Solana
      add :solana_mint_sig,   :string                 # base58 mint tx on Solana

      # NFT fields
      add :nft_metadata_uri,  :string
      add :nft_metadata_hash, :string                 # keccak256 of metadata JSON

      # Commit tracking
      add :commit_tx_a,       :string
      add :commit_tx_b,       :string
      add :hub_state_hash,    :string                 # keccak256(lock+mint+cross_chain_id)

      # Timeout / rollback
      add :timeout_at,        :utc_datetime
      add :rollback_reason,   :string
      add :rollback_tx_a,     :string
      add :rollback_tx_b,     :string
    end

    # Extend state enum — Postgres uses string column so just index it
    create index(:transfers, [:channel_id])
    create index(:transfers, [:cross_chain_id])
    create index(:transfers, [:timeout_at])
  end
end
