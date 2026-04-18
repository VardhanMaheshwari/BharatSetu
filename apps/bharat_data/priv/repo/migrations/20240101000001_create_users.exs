defmodule BharatData.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :wallet_address, :string, primary_key: true
      add :kyc_tier, :integer, default: 0, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
