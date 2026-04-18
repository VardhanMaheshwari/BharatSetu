defmodule BharatData.Schemas.IndexerCheckpoint do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "indexer_checkpoints" do
    field :chain,                :string
    field :last_processed_block, :integer

    timestamps(inserted_at: false)
  end

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:id, :chain, :last_processed_block])
    |> validate_required([:id, :last_processed_block])
  end
end
