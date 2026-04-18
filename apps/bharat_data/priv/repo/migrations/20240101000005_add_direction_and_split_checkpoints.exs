defmodule BharatData.Repo.Migrations.AddDirectionAndSplitCheckpoints do
  use Ecto.Migration

  def change do
    alter table(:transfers) do
      add :direction, :string, null: false, default: "amoy_to_sepolia"
    end

    # Add chain column to indexer_checkpoints and insert Sepolia row
    alter table(:indexer_checkpoints) do
      add :chain, :string, null: false, default: "amoy"
    end

    # Existing row (id=1) gets chain='amoy' from default
    # Insert Sepolia checkpoint
    execute(
      "INSERT INTO indexer_checkpoints (id, chain, last_processed_block, updated_at) VALUES (2, 'sepolia', 0, NOW())",
      "DELETE FROM indexer_checkpoints WHERE id = 2"
    )
  end
end
