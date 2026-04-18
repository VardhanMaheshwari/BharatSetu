defmodule BharatData.Schemas.TransferEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "transfer_events" do
    field :transfer_id, :binary_id
    field :state,       :string
    field :metadata,    :map, default: %{}

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:transfer_id, :state, :metadata])
    |> validate_required([:transfer_id, :state])
  end
end
