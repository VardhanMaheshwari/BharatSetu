defmodule BharatData.Repo.Migrations.AddProductionFieldsToTransfers do
    use Ecto.Migration

    def change do
        alter table(:transfers) do
            add :source_chain, :string, null: false, default: "polygon"
            add :destination_chain, :string, null: false, default: "ethereum"
            add :token_standard, :string, null: false, default: "ERC20"
            add :token_id, :string
            add :data, :binary
            add :destination_wallet, :string
            add :blocked_reason, :string
        end 
    end
end