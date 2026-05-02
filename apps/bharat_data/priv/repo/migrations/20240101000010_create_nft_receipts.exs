defmodule BharatData.Repo.Migrations.CreateNftReceipts do
  use Ecto.Migration

  def change do
    create table(:nft_receipts, primary_key: false) do
      add :id,               :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :transfer_id,      references(:transfers, type: :binary_id), null: false
      add :cross_chain_id,   :string, null: false
      add :original_chain,   :string, null: false
      add :original_contract,:string, null: false
      add :original_token_id,:bigint, null: false
      add :metadata_uri,     :string
      add :metadata_hash,    :string           # keccak256 of metadata JSON
      add :metadata_json,    :map, default: %{}

      # Wrapped side
      add :wrapped_chain,    :string
      add :wrapped_mint,     :string           # Solana: Metaplex mint pubkey
      add :wrapped_token_id, :bigint           # EVM: if wrapping to ERC721

      timestamps()
    end

    create unique_index(:nft_receipts, [:transfer_id])
    create unique_index(:nft_receipts, [:cross_chain_id])
  end
end
