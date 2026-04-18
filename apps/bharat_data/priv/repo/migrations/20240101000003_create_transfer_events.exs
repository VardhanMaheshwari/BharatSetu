defmodule BharatData.Repo.Migrations.CreateTransferEvents do
  use Ecto.Migration

  def change do
    create table(:transfer_events, primary_key: false) do
      add :id,          :binary_id, primary_key: true
      add :transfer_id, references(:transfers, type: :binary_id, on_delete: :delete_all), null: false
      add :state,       :string, null: false
      add :metadata,    :map, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:transfer_events, [:transfer_id])
  end
end
