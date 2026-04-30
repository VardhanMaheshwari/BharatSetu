defmodule BharatData.Schemas.Transfer do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_states ~w(
    init
    submitted
    source_confirmed
    attested
    relay_submitted
    destination_confirmed
    completed
    expired
    blocked
    relay_failed
  )

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "transfers" do
    field :wallet, :string
    field :token_address, :string
    field :amount, :decimal
    field :nonce_hash, :string

    field :state, :string, default: "init"
    field :direction, :string, default: "amoy_to_sepolia"

    field :lock_tx_hash, :string
    field :lock_block, :integer
    field :mint_tx_hash, :string
    field :failure_reason, :string
    field :relay_attempts, :integer, default: 0

    # --- NEW FIELDS (from migration) ---
    field :source_chain, :string, default: "polygon"
    field :destination_chain, :string, default: "ethereum"
    field :token_standard, :string, default: "ERC20"
    field :token_id, :string
    field :data, :binary
    field :destination_wallet, :string
    field :blocked_reason, :string

    timestamps()
  end

  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :wallet,
      :token_address,
      :amount,
      :nonce_hash,
      :state,
      :direction,
      :lock_tx_hash,
      :lock_block,
      :mint_tx_hash,
      :failure_reason,
      :relay_attempts,
      :source_chain,
      :destination_chain,
      :token_standard,
      :token_id,
      :data,
      :destination_wallet,
      :blocked_reason
    ])
    |> validate_required([:wallet, :token_address, :amount, :nonce_hash])
    |> validate_inclusion(:state, @valid_states)
    |> unique_constraint(:nonce_hash)
  end

  def valid_states, do: @valid_states
end