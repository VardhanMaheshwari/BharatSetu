defmodule BharatData.Repo.Migrations.CreateValidators do
  use Ecto.Migration

  def change do
    create table(:validators, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :eth_address, :string, null: false
      add :bls_public_key, :string, null: false
      add :active, :boolean, null: false, default: true
      add :chains, {:array, :string}, null: false, default: []
      add :registered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
    create unique_index(:validators, [:eth_address])
  end
end