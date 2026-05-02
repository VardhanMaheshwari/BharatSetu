defmodule BharatCore.Channel.RollbackCoordinator do
  @moduledoc """
  Handles rollback for timed-out or failed cross-chain transfers.

  Strategy per state:
    init / locked_a / hub_recorded / validating →
      call EthVault.claimTimeout or SolanaLockVault.claim_timeout on source chain
    consensus_b / minting_b →
      source chain refund (destination mint not yet committed)
    committed_b →
      complex: need to burn on destination, then refund source — POC simplifies to
      manual intervention flag + alert
  """

  require Logger

  alias BharatData.Transfers
  alias BharatAdapters.Blockchain.Contract, as: EvmContract
  alias BharatAdapters.Solana.Client, as: SolanaClient

  @evm_source_directions   ~w(eth_to_sol eth_nft_to_sol)
  @solana_source_directions ~w(sol_to_eth sol_nft_to_eth)

  def rollback(transfer) do
    case do_rollback(transfer) do
      {:ok, tx} ->
        Transfers.mark_rolled_back(transfer.id, rollback_tx_for(transfer.direction, tx))
        Logger.info("RollbackCoordinator: rolled back #{transfer.id} tx=#{tx}")

      {:error, :committed_b} ->
        Transfers.update_state(transfer.id, "failed", %{
          rollback_reason: "committed_b: manual intervention required — destination already minted"
        })
        Logger.error("RollbackCoordinator: #{transfer.id} committed_b — manual rollback needed")

      {:error, reason} ->
        Logger.error("RollbackCoordinator: rollback failed #{transfer.id}: #{inspect(reason)}")
    end
  end

  defp do_rollback(%{state: "committed_b"}), do: {:error, :committed_b}

  defp do_rollback(%{direction: dir, cross_chain_id: ccid} = transfer)
       when dir in @evm_source_directions do
    EvmContract.claim_timeout_eth_vault(ccid, transfer.lock_tx_hash)
  end

  defp do_rollback(%{direction: dir, cross_chain_id: ccid} = transfer)
       when dir in @solana_source_directions do
    SolanaClient.claim_timeout(ccid, transfer.solana_signature)
  end

  defp do_rollback(transfer) do
    Logger.warning("RollbackCoordinator: unknown direction #{transfer.direction}, skipping")
    {:error, :unknown_direction}
  end

  defp rollback_tx_for(dir, tx) when dir in @evm_source_directions, do: tx
  defp rollback_tx_for(_, tx), do: tx
end
