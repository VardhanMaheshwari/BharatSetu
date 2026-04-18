defmodule BharatWeb.TransferChannel do
  use BharatWeb, :channel

  alias BharatData.Transfers

  @impl true
  def join("transfer:" <> transfer_id, _payload, socket) do
    wallet = socket.assigns.wallet

    case Transfers.get(transfer_id, wallet) do
      nil ->
        {:error, %{reason: "not found or unauthorized"}}

      _transfer ->
        Phoenix.PubSub.subscribe(BharatSetu.PubSub, "transfer:#{transfer_id}")
        {:ok, assign(socket, :transfer_id, transfer_id)}
    end
  end

  @impl true
  def handle_info({:transfer_update, event}, socket) do
    push(socket, "state_update", event)
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if transfer_id = socket.assigns[:transfer_id] do
      Phoenix.PubSub.unsubscribe(BharatSetu.PubSub, "transfer:#{transfer_id}")
    end
    :ok
  end
end
