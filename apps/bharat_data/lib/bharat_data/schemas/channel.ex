defmodule BharatData.Schemas.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "channels" do
    field :name,           :string
    field :zone_a,         :string
    field :zone_b,         :string
    field :zone_a_chain_id,:integer
    field :zone_b_cluster, :string
    field :config,         :map, default: %{}
    field :active,         :boolean, default: true

    timestamps()
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:id, :name, :zone_a, :zone_b, :zone_a_chain_id,
                    :zone_b_cluster, :config, :active])
    |> validate_required([:id, :name, :zone_a, :zone_b])
  end
end
