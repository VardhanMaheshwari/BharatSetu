defmodule BharatCore.Bridge.TransferServer do
  @moduledoc """
  FSM for a single cross-chain transfer.

  States (Channel/Zone architecture):
    init           — unsigned tx built; waiting for user to submit
    locked         — lock tx_hash received; indexer takes over
    hub_recorded   — hub received lock event, compliance + routing initiated
    validating     — compliance check in-flight
    consensus_b    — waiting for zone_b relayer threshold
    minting_b      — mint/unlock in-flight on zone_b
    committed_b    — zone_b action confirmed
    committed_a    — zone_a finalized (commit or refund ack)
    completed      — all done
    rolling_back   — timeout or failure; refund initiated
    rolled_back    — refund confirmed
    failed         — terminal (unrecoverable)

  Directions:
    amoy_to_sepolia      — legacy POC v1 EVM→EVM
    sepolia_to_amoy      — legacy reverse
    cbdc_to_stablecoin   — POC v2 Anvil→Amoy
    eth_to_sol           — Channel: ETH EthVault → Solana MintBridge
    sol_to_eth           — Channel: Solana LockVault → ETH EthVault unlock
    eth_nft_to_sol       — Channel: ETH NFTVault → Solana NftMintBridge
    sol_nft_to_eth       — Channel: Solana NftVault → ETH NFTVault unlock
  """

  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.Contract
  alias BharatCore.Channel.RollbackCoordinator
  alias BharatData.Transfers

  defstruct [
    :id, :wallet, :token_address, :amount,
    :nonce_hash, :cross_chain_id, :channel_id,
    :lock_tx_hash, :mint_tx_hash, :solana_signature,
    :state, :direction, :started_at,
    :nft_metadata_uri, :nft_metadata_hash
  ]

  # ── Public API ────────────────────────────────────────────────────────────

  def child_spec(opts) do
    %{
      id:      {__MODULE__, opts[:id]},
      start:   {__MODULE__, :start_link, [opts]},
      restart: :temporary,   # don't restart on :normal exit (transfer completed)
      type:    :worker
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))
  end

  def get_state(id) do
    case lookup(id) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :get_state)}
      {:error, _} = err -> err
    end
  end

  def lock_submitted(id, tx_hash) do
    case lookup(id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:lock_submitted, tx_hash})
        :ok
      {:error, _} ->
        Transfers.update_state(id, "locked", %{lock_tx_hash: tx_hash})
        :ok
    end
  end

  # Legacy: BlockchainIndexer confirmed TokensLocked (amoy_to_sepolia)
  def on_confirmed(id, block_number) do
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:confirmed, block_number})
      {:error, _} -> Transfers.update_state(id, "confirmed", %{lock_block: block_number})
    end
    :ok
  end

  # Called by BharatRelayer after successful mint (legacy + sol→eth path)
  def on_minted(id, mint_tx_hash) do
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:minted, mint_tx_hash})
      {:error, _} ->
        Transfers.update_state(id, "minted", %{mint_tx_hash: mint_tx_hash})
        Transfers.update_state(id, "completed", %{})
        broadcast(id, %{event: "completed", state: "completed", transfer_id: id})
    end
    :ok
  end

  # Called by SolanaIndexer: TokenLocked on Solana lock_vault (sol_to_eth direction)
  def on_solana_locked(event) do
    id = event.cross_chain_id
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:solana_locked, event})
      {:error, _} ->
        Transfers.update_state(id, "hub_recorded", %{
          solana_signature: event.solana_signature,
          cross_chain_id:   id
        })
    end
    :ok
  end

  # Called by SolanaIndexer: NftLocked on Solana nft_vault (sol_nft_to_eth direction)
  def on_solana_nft_locked(event) do
    id = event.cross_chain_id
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:solana_nft_locked, event})
      {:error, _} ->
        Transfers.update_state(id, "hub_recorded", %{
          solana_signature: event.solana_signature,
          nft_metadata_uri:  event.metadata_uri,
          nft_metadata_hash: event.metadata_hash,
          cross_chain_id:    id
        })
    end
    :ok
  end

  # Called by HubRouter when consensus_b threshold reached → trigger zone_b mint
  def on_consensus_reached(id, approvals) do
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:consensus_reached, approvals})
      {:error, _} -> Transfers.update_state(id, "consensus_b", %{})
    end
    :ok
  end

  # Called by relayer when starting zone_b mint/unlock
  def execute_zone_b(id) do
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, :execute_zone_b)
      {:error, _} -> :ok
    end
  end

  # Called by relayer after zone_b mint/unlock confirmed
  def on_committed_b(id, commit_tx) do
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:committed_b, commit_tx})
      {:error, _} ->
        Transfers.commit_b(id, commit_tx)
        Transfers.commit_a(id, nil)
        Transfers.finalize(id, nil)
    end
    :ok
  end

  # Called by RollbackCoordinator when claimTimeout confirmed
  def on_rolled_back(id, rollback_tx) do
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:rolled_back, rollback_tx})
      {:error, _} ->
        Transfers.mark_rolled_back(id, rollback_tx, "timeout")
    end
    :ok
  end

  # ── Init ──────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    s = struct(__MODULE__,
      id:               opts[:id],
      wallet:           opts[:wallet],
      token_address:    opts[:token_address],
      amount:           opts[:amount],
      channel_id:       opts[:channel_id],
      cross_chain_id:   opts[:cross_chain_id] || opts[:id],
      nonce_hash:       compute_nonce(opts[:wallet] || "", opts[:id]),
      state:            :init,
      direction:        opts[:direction] || "amoy_to_sepolia",
      started_at:       DateTime.utc_now(),
      nft_metadata_uri:  opts[:nft_metadata_uri],
      nft_metadata_hash: opts[:nft_metadata_hash]
    )

    {:ok, s, {:continue, :init_transfer}}
  end

  # ── handle_continue ───────────────────────────────────────────────────────

  @impl true
  def handle_continue(:init_transfer, s) do
    Logger.info("[FSM] #{s.id} INIT direction=#{s.direction} amount=#{s.amount} wallet=#{s.wallet} cross_chain_id=#{s.cross_chain_id}")

    payload =
      try do
        case s.direction do
          "amoy_to_sepolia" ->
            unsigned_tx = Contract.build_lock_tx(s.token_address, s.amount, s.id)
            %{event: "await_lock", transfer_id: s.id, unsigned_tx: unsigned_tx, nonce_hash: s.nonce_hash}

          "cbdc_to_stablecoin" ->
            unsigned_tx = Contract.build_lock_cbdc_tx(s.amount, s.id)
            %{event: "await_cbdc_lock", transfer_id: s.id, unsigned_tx: unsigned_tx, nonce_hash: s.nonce_hash}

          dir when dir in ["eth_to_sol", "eth_nft_to_sol"] ->
            unsigned_tx = build_eth_lock_tx(s)
            Logger.info("[FSM] #{s.id} built eth_lock_tx to=#{unsigned_tx[:to]} data_len=#{String.length(unsigned_tx[:data] || "")}")
            %{event: "await_eth_lock", transfer_id: s.id, unsigned_tx: unsigned_tx,
              cross_chain_id: s.cross_chain_id, channel_id: s.channel_id}

          dir when dir in ["sol_to_eth", "sol_nft_to_eth"] ->
            %{event: "await_sol_lock", transfer_id: s.id,
              cross_chain_id: s.cross_chain_id, channel_id: s.channel_id}

          _ ->
            %{event: "await_burn", transfer_id: s.id, nonce_hash: s.nonce_hash}
        end
      rescue
        e ->
          Logger.error("[FSM] #{s.id} INIT CRASH direction=#{s.direction} error=#{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
          Transfers.update_state(s.id, "failed", %{failure_reason: "init_crash: #{inspect(e)}"})
          %{event: "error", transfer_id: s.id, reason: inspect(e)}
      end

    broadcast(s.id, payload)
    {:noreply, s}
  end

  @impl true
  def handle_continue(:complete, s) do
    s = %{s | state: :completed}
    Transfers.update_state(s.id, "completed", %{})
    broadcast(s.id, %{event: "completed", state: "completed", transfer_id: s.id})
    Logger.info("Transfer #{s.id} COMPLETED")
    {:stop, :normal, s}
  end

  @impl true
  def handle_continue(:initiate_rollback, s) do
    s = %{s | state: :rolling_back}
    Transfers.mark_rolling_back(s.id, "timeout")
    broadcast(s.id, %{event: "state_change", state: "rolling_back", transfer_id: s.id})
    Logger.warning("Transfer #{s.id} ROLLING_BACK")
    RollbackCoordinator.rollback(%{id: s.id, direction: to_string(s.direction), lock_tx_hash: s.lock_tx_hash})
    {:noreply, s}
  end

  def handle_continue(:trigger_consensus, s) do
    s = %{s | state: :validating}
    Transfers.update_state(s.id, "validating", %{})
    broadcast(s.id, %{event: "state_change", state: "validating"})
    # V2Workers observe the lock event and call BharatRelayer.HubRouter.submit_approval/3.
    # HubRouter calls on_consensus_reached/2 when threshold (2-of-3) is reached.
    Logger.info("Transfer #{s.id} VALIDATING — awaiting relayer approvals")
    {:noreply, s}
  end

  def handle_continue(:execute_zone_b, s) do
    s = %{s | state: :minting_b}
    Transfers.update_state(s.id, "minting_b", %{})
    broadcast(s.id, %{event: "state_change", state: "minting_b"})
    Logger.info("Transfer #{s.id} MINTING_B — dispatching zone_b action")
    {:noreply, s}
  end

  def handle_continue(:commit_zone_a, s) do
    s = %{s | state: :committed_a}
    Transfers.commit_a(s.id, nil)
    broadcast(s.id, %{event: "state_change", state: "committed_a"})
    Logger.info("Transfer #{s.id} COMMITTED_A")
    {:noreply, s, {:continue, :complete}}
  end

  # ── Casts: legacy path ────────────────────────────────────────────────────

  @impl true
  def handle_cast({:lock_submitted, tx_hash}, %{state: :init} = s) do
    Logger.info("[FSM] #{s.id} LOCKED tx=#{tx_hash} direction=#{s.direction}")
    s = %{s | state: :locked, lock_tx_hash: tx_hash}
    Transfers.update_state(s.id, "locked", %{lock_tx_hash: tx_hash})
    broadcast(s.id, %{event: "state_change", state: "locked", tx_hash: tx_hash})
    {:noreply, s}
  end

  def handle_cast({:confirmed, block_number}, %{state: state} = s)
      when state in [:init, :locked] do
    Logger.info("[FSM] #{s.id} CONFIRMED block=#{block_number} direction=#{s.direction} prev_state=#{s.state}")
    s = %{s | state: :confirmed}
    Transfers.update_state(s.id, "confirmed", %{lock_block: block_number})
    broadcast(s.id, %{event: "state_change", state: "confirmed", block: block_number})
    {:noreply, s}
  end

  def handle_cast({:minted, mint_tx_hash}, %{state: state} = s)
      when state in [:confirmed, :committed_b] do
    Logger.info("[FSM] #{s.id} MINTED tx=#{mint_tx_hash} direction=#{s.direction}")
    s = %{s | state: :minted, mint_tx_hash: mint_tx_hash}
    Transfers.update_state(s.id, "minted", %{mint_tx_hash: mint_tx_hash})
    broadcast(s.id, %{event: "state_change", state: "minted", mint_tx_hash: mint_tx_hash})
    {:noreply, s, {:continue, :complete}}
  end

  def handle_cast({:minted, _}, %{state: :minted} = s), do: {:noreply, s}

  # ── Casts: Channel/Zone path ──────────────────────────────────────────────

  # ETH lock confirmed by EthVault indexer
  def handle_cast({:lock_submitted, tx_hash}, %{state: :init, direction: dir} = s)
      when dir in ["eth_to_sol", "eth_nft_to_sol"] do
    s = %{s | state: :locked, lock_tx_hash: tx_hash}
    Transfers.update_state(s.id, "locked", %{lock_tx_hash: tx_hash})
    broadcast(s.id, %{event: "state_change", state: "locked", tx_hash: tx_hash})
    {:noreply, s}
  end

  # Hub records ETH lock (confirmed by EVM indexer depth)
  def handle_cast({:confirmed, block_number}, %{state: state, direction: dir} = s)
      when state in [:locked] and dir in ["eth_to_sol", "eth_nft_to_sol"] do
    s = %{s | state: :hub_recorded}
    Transfers.update_state(s.id, "hub_recorded", %{lock_block: block_number})
    broadcast(s.id, %{event: "state_change", state: "hub_recorded"})
    Logger.info("Transfer #{s.id} HUB_RECORDED (ETH lock confirmed block=#{block_number})")
    {:noreply, s, {:continue, :trigger_consensus}}
  end

  # Solana lock confirmed — hub records (sol_to_eth path)
  def handle_cast({:solana_locked, event}, %{state: :init} = s) do
    s = %{s | state: :hub_recorded, solana_signature: event.solana_signature}
    Transfers.update_state(s.id, "hub_recorded", %{solana_signature: event.solana_signature})
    broadcast(s.id, %{event: "state_change", state: "hub_recorded"})
    Logger.info("Transfer #{s.id} HUB_RECORDED (SOL lock sig=#{event.solana_signature})")
    {:noreply, s, {:continue, :trigger_consensus}}
  end

  def handle_cast({:solana_nft_locked, event}, %{state: :init} = s) do
    s = %{s | state: :hub_recorded, solana_signature: event.solana_signature,
              nft_metadata_uri: event.metadata_uri, nft_metadata_hash: event.metadata_hash}
    Transfers.update_state(s.id, "hub_recorded", %{
      solana_signature: event.solana_signature,
      nft_metadata_uri:  event.metadata_uri,
      nft_metadata_hash: event.metadata_hash
    })
    broadcast(s.id, %{event: "state_change", state: "hub_recorded"})
    Logger.info("Transfer #{s.id} HUB_RECORDED (SOL NFT lock)")
    {:noreply, s, {:continue, :trigger_consensus}}
  end

  # Consensus threshold reached → trigger zone_b mint/unlock
  def handle_cast({:consensus_reached, _approvals}, %{state: :validating} = s) do
    s = %{s | state: :consensus_b}
    Transfers.update_state(s.id, "consensus_b", %{})
    broadcast(s.id, %{event: "state_change", state: "consensus_b"})
    Logger.info("Transfer #{s.id} CONSENSUS_B reached")
    {:noreply, s, {:continue, :execute_zone_b}}
  end

  # Explicit trigger from relayer to enter minting_b state
  def handle_cast(:execute_zone_b, s) do
    {:noreply, s, {:continue, :execute_zone_b}}
  end

  # Zone_b action confirmed
  def handle_cast({:committed_b, commit_tx}, s) do
    # Allow committed_b from minting_b (normal) or hub_recorded/validating (relayer skip)
    s = %{s | state: :committed_b}
    Transfers.commit_b(s.id, commit_tx)
    broadcast(s.id, %{event: "state_change", state: "committed_b", tx: commit_tx})
    Logger.info("Transfer #{s.id} COMMITTED_B tx=#{commit_tx}")
    {:noreply, s, {:continue, :commit_zone_a}}
  end

  # Rollback confirmed
  def handle_cast({:rolled_back, rollback_tx}, %{state: :rolling_back} = s) do
    s = %{s | state: :rolled_back}
    Transfers.mark_rolled_back(s.id, rollback_tx, "timeout")
    broadcast(s.id, %{event: "state_change", state: "rolled_back", tx: rollback_tx})
    Logger.info("Transfer #{s.id} ROLLED_BACK tx=#{rollback_tx}")
    {:stop, :normal, s}
  end

  def handle_cast(msg, s) do
    Logger.warning("Transfer #{s.id}: unexpected cast #{inspect(msg)} in state #{s.state}")
    {:noreply, s}
  end

  # ── Calls ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:get_state, _from, s) do
    {:reply, Map.from_struct(s), s}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp build_eth_lock_tx(%{direction: "eth_to_sol"} = s) do
    # EthVault.lock(token, amount, crossChainId, destWallet, timeoutSec)
    # POC: build basic lock calldata; real impl will call EthVault-specific encoder
    Contract.build_lock_tx(s.token_address, s.amount, s.cross_chain_id)
  end

  defp build_eth_lock_tx(%{direction: "eth_nft_to_sol"} = s) do
    # NFTVault.lockNFT — token_address = ERC721 contract, amount = tokenId
    Contract.build_lock_tx(s.token_address, s.amount, s.cross_chain_id)
  end

  defp compute_nonce(wallet, id) do
    :crypto.hash(:sha256, wallet <> id)
    |> Base.encode16(case: :lower)
    |> then(&"0x#{&1}")
  end

  defp broadcast(id, payload) do
    Phoenix.PubSub.broadcast(BharatSetu.PubSub, "transfer:#{id}", {:transfer_update, payload})
  end

  defp via(id), do: {:via, Registry, {BharatCore.Bridge.Registry, id}}

  defp lookup(id) do
    case Registry.lookup(BharatCore.Bridge.Registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
