defmodule BharatWeb.ConfigController do
  use BharatWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      data: %{
        # POC v1 — Amoy ↔ Sepolia
        lock_bridge:      Application.get_env(:bharat_core, :lock_contract),
        mint_bridge:      Application.get_env(:bharat_core, :mint_contract),
        # tCCS = Amoy-side token (locked in LockBridge); wCCC = Sepolia-side token (MintBridge IS the ERC20)
        tccs_token:       Application.get_env(:bharat_core, :tccs_token, Application.get_env(:bharat_core, :lock_contract)),
        wccc_token:       Application.get_env(:bharat_core, :mint_contract),
        amoy_chain_id:    80_002,
        sepolia_chain_id: 11_155_111,
        # POC v2 — Anvil ↔ Amoy (CBDC ↔ Stablecoin)
        cbdc_vault:            Application.get_env(:bharat_core, :cbdc_vault_contract),
        asset_vault:           Application.get_env(:bharat_core, :asset_vault_contract),
        stablecoin_bridge:     Application.get_env(:bharat_core, :stablecoin_bridge_contract),
        mock_cbdc_token:       Application.get_env(:bharat_core, :mock_cbdc_token),
        mock_asset_contract:   Application.get_env(:bharat_core, :mock_asset_contract),
        block_hash_oracle:     Application.get_env(:bharat_core, :block_hash_oracle_contract),
        anvil_chain_id:        31_337,
        # Channel/Zone — ETH ↔ SOL
        eth_vault:             Application.get_env(:bharat_core, :eth_vault_contract),
        nft_vault:             Application.get_env(:bharat_core, :nft_vault_contract)
      }
    })
  end
end
