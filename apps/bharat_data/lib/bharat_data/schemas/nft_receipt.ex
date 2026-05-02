defmodule BharatData.Schemas.NftReceipt do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "nft_receipts" do
    field :transfer_id,        :binary_id
    field :cross_chain_id,     :string
    field :original_chain,     :string
    field :original_contract,  :string
    field :original_token_id,  :integer
    field :metadata_uri,       :string
    field :metadata_hash,      :string
    field :metadata_json,      :map, default: %{}
    field :wrapped_chain,      :string
    field :wrapped_mint,       :string
    field :wrapped_token_id,   :integer

    timestamps()
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:transfer_id, :cross_chain_id, :original_chain, :original_contract,
                    :original_token_id, :metadata_uri, :metadata_hash, :metadata_json,
                    :wrapped_chain, :wrapped_mint, :wrapped_token_id])
    |> validate_required([:transfer_id, :cross_chain_id, :original_chain,
                          :original_contract, :original_token_id])
    |> unique_constraint(:transfer_id)
    |> unique_constraint(:cross_chain_id)
  end
end
