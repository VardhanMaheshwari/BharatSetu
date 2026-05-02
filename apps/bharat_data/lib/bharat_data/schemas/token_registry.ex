defmodule BharatData.Schemas.TokenRegistry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @valid_standards ~w(ERC20 ERC721 SPL SPL_NFT)

  schema "token_registry" do
    field :channel_id,        :string
    field :original_chain,    :string
    field :original_address,  :string
    field :original_standard, :string
    field :original_decimals, :integer, default: 18
    field :wrapped_chain,     :string
    field :wrapped_address,   :string
    field :wrapped_standard,  :string
    field :symbol,            :string
    field :name,              :string

    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:channel_id, :original_chain, :original_address, :original_standard,
                    :original_decimals, :wrapped_chain, :wrapped_address,
                    :wrapped_standard, :symbol, :name])
    |> validate_required([:channel_id, :original_chain, :original_address,
                          :original_standard, :wrapped_chain, :wrapped_address, :wrapped_standard])
    |> validate_inclusion(:original_standard, @valid_standards)
    |> validate_inclusion(:wrapped_standard, @valid_standards)
    |> unique_constraint([:channel_id, :original_chain, :original_address])
  end
end
