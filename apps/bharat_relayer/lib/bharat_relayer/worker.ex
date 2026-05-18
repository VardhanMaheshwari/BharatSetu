defmodule BharatRelayer.Worker do
  @moduledoc """
  Queue-based mint worker. Single responsibility:

    1. Poll DB every 5s for transfers in state 'confirmed'
    2. For each confirmed transfer:
       a. Idempotency check — skip if nonce already minted
       b. Call Contract.mint_on_proof(wallet, nonce_hash, amount)
       c. On success: update transfer state to 'minted', store mint_tx_hash,
                      notify TransferServer via PubSub
       d. On failure: increment relay_attempts; mark 'failed' after 3 attempts

  This process is fully independent of TransferServer.
  Crash here does not affect the bridge FSM.
  Restart here re-reads DB state — no in-memory state lost.
  """

  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.Contract
  alias BharatAdapters.Solana.Client, as: SolanaClient
  alias BharatData.Transfers
  alias BharatCore.Bridge.TransferServer

  @poll_interval_ms 5_000
  @max_relay_attempts 3
  @wei_per_token Decimal.new("1000000000000000000")

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    process_confirmed_transfers()
    schedule_poll()
    {:noreply, state}
  end

  defp process_confirmed_transfers do
    confirmed = Transfers.get_confirmed_pending_relay()
    eth_to_sol = Transfers.get_eth_to_sol_pending_mint()

    all = Enum.uniq_by(confirmed ++ eth_to_sol, & &1.id)
    if all != [] do
      Logger.info("Relayer: found #{length(confirmed)} confirmed + #{length(eth_to_sol)} eth_to_sol transfer(s) to mint")
    end

    Enum.each(all, &relay_transfer/1)
  end

  defp relay_transfer(transfer) do
    # Idempotency: don't re-mint if already done
    if Transfers.already_minted?(transfer.nonce_hash) do
      Logger.info("Relayer: transfer #{transfer.id} already minted — skipping")
      Transfers.update_state(transfer.id, "minted", %{})
      return_ok()
    else
      attempt_mint(transfer)
    end
  end

  defp attempt_mint(transfer) do
    Logger.info("Relayer: processing transfer #{transfer.id} direction=#{transfer.direction} (attempt #{transfer.relay_attempts + 1})")

    amount_wei = Decimal.mult(transfer.amount, @wei_per_token)

    result =
      case transfer.direction do
        "sepolia_to_amoy" ->
          Contract.unlock_on_amoy(transfer.wallet, transfer.token_address,
                                  transfer.nonce_hash, amount_wei)

        "eth_to_sol" ->
          # Convert 18-decimal EVM amount to 9-decimal SPL lamports
          amount_spl = Decimal.to_integer(Decimal.div(amount_wei, Decimal.new("1000000000")))
          cross_chain_id = transfer.cross_chain_id || transfer.nonce_hash
          nonce_hash     = transfer.nonce_hash || cross_chain_id
          # instruction_payload stores the Solana destination wallet (base58)
          # set by SepoliaIndexer when it sees the EthVault TokenLocked event
          dest_wallet = transfer.instruction_payload || transfer.wallet
          
          # Transition state to minting_b so TransferServer is ready for on_committed_b
          Transfers.update_state(transfer.id, "minting_b", %{})
          BharatCore.Bridge.TransferServer.execute_zone_b(transfer.id)
          
          Logger.info("Relayer: eth_to_sol mint amount_spl=#{amount_spl} dest=#{dest_wallet} ccid=#{cross_chain_id}")
          SolanaClient.mint_wrapped(cross_chain_id, amount_spl, nonce_hash, dest_wallet)

        _ ->
          Contract.mint_on_proof(transfer.wallet, transfer.nonce_hash, amount_wei)
      end

    case result do
      {:ok, mint_tx_hash} ->
        if transfer.direction == "eth_to_sol" do
          Transfers.update_state(transfer.id, "committed_b", %{mint_tx_hash: mint_tx_hash})
          TransferServer.on_committed_b(transfer.id, mint_tx_hash)
        else
          Transfers.update_state(transfer.id, "minted", %{mint_tx_hash: mint_tx_hash})
          TransferServer.on_minted(transfer.id, mint_tx_hash)
        end
        Logger.info("Relayer: completed transfer #{transfer.id} — tx #{mint_tx_hash}")

      {:error, reason} ->
        Transfers.increment_relay_attempts(transfer.id)
        new_attempts = transfer.relay_attempts + 1

        if new_attempts >= @max_relay_attempts do
          Transfers.update_state(transfer.id, "failed", %{
            failure_reason: "relay failed after #{new_attempts} attempts: #{inspect(reason)}"
          })
          Logger.error("Relayer: transfer #{transfer.id} FAILED after #{new_attempts} attempts: #{inspect(reason)}")
        else
          Logger.warning("Relayer: transfer #{transfer.id} mint failed (attempt #{new_attempts}): #{inspect(reason)}")
        end
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp return_ok, do: :ok
end
