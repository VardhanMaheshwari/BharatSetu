defmodule BharatCore.Indexer.SolanaBlockHashReporter do
  @moduledoc """
  Watches Anvil for finalized block hashes and submits them to the
  BlockHashOracle contract on Amoy via Contract.submit_block_hash/2.

  Used in the MPT-proof bridge path so Amoy can verify Anvil receipts
  without a light client. Polls every 15s — only submits new blocks.
  """

  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.Contract

  @poll_interval_ms 15_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :poll)
    {:ok, %{last_reported_block: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = report_new_blocks(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Block submission ───────────────────────────────────────────────────────

  defp report_new_blocks(state) do
    case Contract.anvil_block_number() do
      {:ok, latest} when latest > state.last_reported_block ->
        next = state.last_reported_block + 1

        case fetch_block_hash(next) do
          {:ok, block_hash} ->
            case Contract.submit_block_hash(next, block_hash) do
              {:ok, tx_hash} ->
                Logger.info("[BlockHashReporter] submitted block=#{next} tx=#{tx_hash}")
                %{state | last_reported_block: next}

              {:error, reason} ->
                Logger.warning("[BlockHashReporter] submit failed block=#{next}: #{inspect(reason)}")
                state
            end

          {:error, reason} ->
            Logger.warning("[BlockHashReporter] getBlockByNumber #{next} failed: #{inspect(reason)}")
            state
        end

      {:ok, _same} ->
        state

      {:error, reason} ->
        Logger.warning("[BlockHashReporter] anvil_block_number failed: #{inspect(reason)}")
        state
    end
  end

  defp fetch_block_hash(block_number) do
    hex_block = "0x" <> Integer.to_string(block_number, 16)
    anvil_url = Application.get_env(:bharat_core, :anvil_http_url) ||
                raise "anvil_http_url not configured"

    body = Jason.encode!(%{
      jsonrpc: "2.0", id: 1,
      method: "eth_getBlockByNumber",
      params: [hex_block, false]
    })

    case Req.post(anvil_url, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %{body: %{"result" => %{"hash" => hash}}}} ->
        {:ok, hash}

      {:ok, %{body: %{"result" => nil}}} ->
        {:error, :block_not_found}

      {:ok, %{body: %{"error" => err}}} ->
        {:error, {:rpc_error, err}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
