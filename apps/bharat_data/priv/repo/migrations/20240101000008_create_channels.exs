defmodule BharatData.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    create table(:channels, primary_key: false) do
      add :id,          :string, primary_key: true   # e.g. "eth-sol-v1"
      add :name,        :string, null: false
      add :zone_a,      :string, null: false          # "ethereum" | "anvil"
      add :zone_b,      :string, null: false          # "solana"
      add :zone_a_chain_id,  :integer
      add :zone_b_cluster,   :string                  # "devnet" | "mainnet-beta"
      add :config,      :map, default: %{}            # confirmation depths, timeout_sec, etc.
      add :active,      :boolean, default: true

      timestamps()
    end

    create table(:token_registry, primary_key: false) do
      add :id,                  :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :channel_id,          references(:channels, type: :string), null: false
      add :original_chain,      :string, null: false   # "ethereum" | "solana"
      add :original_address,    :string, null: false   # EVM address or Solana pubkey
      add :original_standard,   :string, null: false   # "ERC20" | "ERC721" | "SPL" | "SPL_NFT"
      add :original_decimals,   :integer, default: 18
      add :wrapped_chain,       :string, null: false
      add :wrapped_address,     :string, null: false
      add :wrapped_standard,    :string, null: false
      add :symbol,              :string
      add :name,                :string

      timestamps()
    end

    create unique_index(:token_registry, [:channel_id, :original_chain, :original_address])
    create index(:token_registry, [:channel_id])
  end
end
