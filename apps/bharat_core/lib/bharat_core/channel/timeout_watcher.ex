defmodule BharatCore.Channel.TimeoutWatcher do
  @moduledoc """
  Polls for transfers that have exceeded their timeout_at deadline and
  initiates rollback: marks state = rolling_back, then triggers on-chain
  claimTimeout on the source chain vault to refund the sender.

  POC simplification: calls relayer to submit claimTimeout tx.
  Full production would use a more robust retry + on-chain coordination.
  """

  use GenServer
  require Logger

  alias BharatData.Transfers
  alias BharatCore.Channel.RollbackCoordinator

  @poll_interval_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    check_timeouts()
    schedule_poll()
    {:noreply, state}
  end

  defp check_timeouts do
    timed_out = Transfers.get_timed_out()
    if length(timed_out) > 0 do
      Logger.info("TimeoutWatcher: #{length(timed_out)} transfers timed out, initiating rollback")
    end
    Enum.each(timed_out, &initiate_rollback/1)
  end

  defp initiate_rollback(transfer) do
    Logger.warning("TimeoutWatcher: rolling back transfer=#{transfer.id} state=#{transfer.state}")
    Transfers.mark_rolling_back(transfer.id, "timeout exceeded")
    RollbackCoordinator.rollback(transfer)
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
