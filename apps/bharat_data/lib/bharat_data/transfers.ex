defmodule BharatData.Transfers do
  import Ecto.Query
  alias BharatData.Repo
  alias BharatData.Schemas.{Transfer, TransferEvent}

  def create(attrs) do
    %Transfer{}
    |> Transfer.changeset(attrs)
    |> Repo.insert()
  end

  def get(id) do
    Repo.get(Transfer, id)
  end

  def get(id, wallet) do
    Repo.get_by(Transfer, id: id, wallet: wallet)
  end

  def list_by_wallet(wallet) do
    Transfer
    |> where([t], t.wallet == ^wallet)
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  def update_state(id, new_state, extra_attrs \\ %{}) do
    case get(id) do
      nil ->
        {:error, :not_found}

      transfer ->
        attrs = Map.merge(%{state: new_state}, extra_attrs)

        result =
          transfer
          |> Transfer.changeset(attrs)
          |> Repo.update()

        with {:ok, updated} <- result do
          append_event(id, new_state, extra_attrs)
          {:ok, updated}
        end
    end
  end

  def increment_relay_attempts(id) do
    {count, _} =
      Transfer
      |> where([t], t.id == ^id)
      |> Repo.update_all(inc: [relay_attempts: 1])

    count
  end

  # Returns confirmed transfers not yet picked up by relayer.
  # Relayer queries this to find work.
  def get_confirmed_pending_relay(limit \\ 50) do
    Transfer
    |> where([t], t.state == "confirmed" and t.relay_attempts < 3)
    |> order_by([t], asc: t.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # Idempotency check: has this nonce_hash already been minted?
  def already_minted?(nonce_hash) do
    Transfer
    |> where([t], t.nonce_hash == ^nonce_hash and t.state in ["minted", "completed"])
    |> Repo.exists?()
  end

  defp append_event(transfer_id, state, metadata) do
    %TransferEvent{}
    |> TransferEvent.changeset(%{
      transfer_id: transfer_id,
      state: state,
      metadata: metadata
    })
    |> Repo.insert!()
  end
end
