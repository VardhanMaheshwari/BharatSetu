defmodule BharatData.Repo.Migrations.CreateChainConfigs do
  use Ecto.Migration

  def change do
    create table(:chain_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :chain_id, :string, null: false
      add :rpc_url, :string, null: false
      add :confirmation_depth, :integer, null: false
      add :chain_type, :string, null: false
      add :active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:chain_configs, [:chain_id])
  end
end