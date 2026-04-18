defmodule BharatData.Repo.Migrations.CreateTransfers do
  use Ecto.Migration

  def change do
    create table(:transfers, primary_key: false) do
      add :id,             :binary_id, primary_key: true
      add :wallet,         :string, null: false
      add :token_address,  :string, null: false
      add :amount,         :decimal, null: false
      add :nonce_hash,     :string, null: false
      add :state,          :string, null: false, default: "init"
      add :lock_tx_hash,   :string
      add :lock_block,     :integer
      add :mint_tx_hash,   :string
      add :failure_reason, :string
      add :relay_attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:transfers, [:nonce_hash])
    create index(:transfers, [:wallet])
    create index(:transfers, [:state])
  end
end
