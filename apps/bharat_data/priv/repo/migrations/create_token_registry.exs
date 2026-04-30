defmodule BharatData.Repo.Migrations.CreateTokenRegistry do
  use Ecto.Migration

  def change do
    create table(:token_registry, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_address, :string, null: false
      add :token_standard, :string, null: false
      add :name, :string, null: false
      add :symbol, :string, null: false
      add :decimals, :integer, null: false
      add :max_transfer_bytes, :integer, null: false, default: 262144
      add :supported_chains, {:array, :string}, null: false, default: [
      add :active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:token_registry, [:token_address])
  end
end