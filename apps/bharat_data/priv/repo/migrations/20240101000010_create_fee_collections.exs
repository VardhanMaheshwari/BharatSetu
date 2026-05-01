defmodule BharatData.Repo.Migrations.CreateFeeCollections do
  use Ecto.Migration

  def change do
    create table(:fee_collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :transfer_id,
          references(:transfers, type: :binary_id, on_delete: :delete_all),
          null: false
      add :amount_wei, :string, null: false
      add :chain_id, :string, null: false
      add :collected_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:fee_collections, [:transfer_id])
    create index(:fee_collections, [:chain_id])
  end
end