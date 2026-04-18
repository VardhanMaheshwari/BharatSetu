defmodule BharatData.Schemas.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:wallet_address, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "users" do
    field :kyc_tier, :integer, default: 0

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:wallet_address, :kyc_tier])
    |> validate_required([:wallet_address])
    |> validate_number(:kyc_tier, greater_than_or_equal_to: 0)
  end
end
