defmodule BharatData.Repo.Migrations.CreateIndexerCheckpoints do
  use Ecto.Migration

  def change do
    create table(:indexer_checkpoints, primary_key: false) do
      add :id,                   :integer, primary_key: true
      add :last_processed_block, :integer, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end

    # Seed row — always id=1
    execute(
      "INSERT INTO indexer_checkpoints (id, last_processed_block, updated_at) VALUES (1, 0, NOW())",
      "DELETE FROM indexer_checkpoints WHERE id = 1"
    )
  end
end
