defmodule BharatCore.Indexer.SolanaIndexer do
  @moduledoc """
  Solana program event indexer using signature polling.

  Polls getSignaturesForAddress for lock_vault and nft_vault programs every 5s.
  Tracks last-seen signature as watermark (DB checkpoint, chain_id=4).
  On restart: backfills from last checkpoint signature.

  Dispatches:
  - TokenLocked  → TransferServer.on_solana_locked/1
  - NftLocked    → TransferServer.on_solana_nft_locked/1
  """

  use GenServer
  require Logger

  alias BharatAdapters.Solana.Client, as: SolanaClient
  alias BharatCore.Bridge.TransferServer
  alias BharatData.IndexerCheckpoints

  # Anchor event discriminators: first 8 bytes of sha256("event:<EventName>"), base64-encoded.
  # Pre-computed for lock_vault program events.
  # Real values must match the Anchor IDL — these are placeholders for POC.
  @token_locked_disc "TokenLockedDisc"   # replace with real base64 discriminator
  @nft_locked_disc   "NftLockedDisc"     # replace with real base64 discriminator

  @poll_interval_ms  5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :poll)
    {:ok, %{last_sig_lock: nil, last_sig_nft: nil, initialized: false}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_program(state, :lock_vault, lock_vault_program_id(), @token_locked_disc, :last_sig_lock)
    state = poll_program(state, :nft_vault,  nft_vault_program_id(),  @nft_locked_disc,  :last_sig_nft)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Poll one program ───────────────────────────────────────────────────────

  defp poll_program(state, program_key, program_id, disc, sig_key) do
    watermark = Map.get(state, sig_key) || load_watermark(program_key)

    opts = [limit: 50]
    opts = if watermark, do: Keyword.put(opts, :until, watermark), else: opts

    case SolanaClient.get_signatures_for_address(program_id, opts) do
      {:ok, []} ->
        state

      {:ok, sigs} ->
        # Signatures newest-first; process oldest-first for correct FSM ordering.
        sigs
        |> Enum.reverse()
        |> Enum.filter(& is_nil(&1.err))
        |> Enum.each(fn %{signature: sig} ->
          process_signature(sig, program_key, disc)
        end)

        newest_sig = hd(sigs).signature
        save_watermark(program_key, newest_sig)
        Map.put(state, sig_key, newest_sig)

      {:error, reason} ->
        Logger.warning("[SolanaIndexer] #{program_key} poll failed: #{inspect(reason)}")
        state
    end
  end

  defp process_signature(sig, program_key, disc) do
    with {:ok, tx}        <- SolanaClient.get_transaction(sig),
         logs              = SolanaClient.get_logs(tx),
         raw_data when not is_nil(raw_data) <- SolanaClient.parse_anchor_event(logs, disc) do
      decode_and_dispatch(program_key, raw_data, sig)
    else
      {:error, :not_found} ->
        Logger.debug("[SolanaIndexer] tx not found: #{sig}")

      nil ->
        Logger.debug("[SolanaIndexer] no matching event in tx: #{sig}")

      {:error, reason} ->
        Logger.warning("[SolanaIndexer] fetch #{sig} failed: #{inspect(reason)}")
    end
  end

  defp decode_and_dispatch(:lock_vault, raw, sig) do
    case SolanaClient.decode_token_locked(raw) do
      {:ok, event} ->
        Logger.info("[SolanaIndexer] TokenLocked ccid=#{event.cross_chain_id} sig=#{sig}")
        TransferServer.on_solana_locked(Map.put(event, :solana_signature, sig))

      {:error, reason} ->
        Logger.warning("[SolanaIndexer] decode_token_locked failed sig=#{sig}: #{inspect(reason)}")
    end
  end

  defp decode_and_dispatch(:nft_vault, raw, sig) do
    case SolanaClient.decode_nft_locked(raw) do
      {:ok, event} ->
        Logger.info("[SolanaIndexer] NftLocked ccid=#{event.cross_chain_id} sig=#{sig}")
        TransferServer.on_solana_nft_locked(Map.put(event, :solana_signature, sig))

      {:error, reason} ->
        Logger.warning("[SolanaIndexer] decode_nft_locked failed sig=#{sig}: #{inspect(reason)}")
    end
  end

  # ── Checkpoint persistence ─────────────────────────────────────────────────

  # Reuse IndexerCheckpoints with sub-keys encoded in the chain_id integer.
  # POC: store as string metadata in the checkpoint row via chain_id offset.
  # lock_vault = chain_id 4, nft_vault = chain_id 5.
  defp load_watermark(:lock_vault), do: IndexerCheckpoints.get_last_sig(4)
  defp load_watermark(:nft_vault),  do: IndexerCheckpoints.get_last_sig(5)

  defp save_watermark(:lock_vault, sig), do: IndexerCheckpoints.update_last_sig(4, sig)
  defp save_watermark(:nft_vault, sig),  do: IndexerCheckpoints.update_last_sig(5, sig)

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)

  defp lock_vault_program_id do
    Application.get_env(:bharat_adapters, :solana_lock_vault_program_id) ||
      raise "solana_lock_vault_program_id not configured"
  end

  defp nft_vault_program_id do
    Application.get_env(:bharat_adapters, :solana_nft_vault_program_id) ||
      raise "solana_nft_vault_program_id not configured"
  end
end
