defmodule BharatCore.Bridge.TransferSupervisor do
  @moduledoc "Starts and tracks TransferServer processes."

  alias BharatCore.Bridge.TransferServer
  alias BharatData.Transfers

  def start_transfer(attrs) do
    id = Ecto.UUID.generate()

    transfer_attrs = %{
      id:            id,
      wallet:        attrs.wallet,
      token_address: attrs.token_address,
      amount:        attrs.amount,
      nonce_hash:    compute_nonce(attrs.wallet, id),
      state:         "init",
      direction:     Map.get(attrs, :direction, "amoy_to_sepolia")
    }

    with {:ok, _record} <- Transfers.create(transfer_attrs) do
      opts = Enum.map(transfer_attrs, fn {k, v} -> {k, v} end)

      case DynamicSupervisor.start_child(
             BharatCore.Bridge.Supervisor,
             {TransferServer, opts}
           ) do
        {:ok, _pid}             -> {:ok, id}
        {:error, {:already_started, _}} -> {:ok, id}
        {:error, reason}        -> {:error, reason}
      end
    end
  end

  defp compute_nonce(wallet, id) do
    :crypto.hash(:sha256, wallet <> id)
    |> Base.encode16(case: :lower)
    |> then(&"0x#{&1}")
  end
end
