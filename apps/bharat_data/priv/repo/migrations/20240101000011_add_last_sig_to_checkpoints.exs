defmodule BharatData.Repo.Migrations.AddLastSigToCheckpoints do
  use Ecto.Migration

  def change do
    alter table(:indexer_checkpoints) do
      add :last_sig, :string, null: true
    end

    # Insert rows for Solana lock_vault (id=4) and nft_vault (id=5) if missing.
    execute(
      "INSERT INTO indexer_checkpoints (id, chain, last_processed_block, updated_at) VALUES (4, 'solana_lock', 0, NOW()) ON CONFLICT (id) DO NOTHING",
      "DELETE FROM indexer_checkpoints WHERE id IN (4, 5)"
    )
    execute(
      "INSERT INTO indexer_checkpoints (id, chain, last_processed_block, updated_at) VALUES (5, 'solana_nft', 0, NOW()) ON CONFLICT (id) DO NOTHING",
      ""
    )
  end
end
