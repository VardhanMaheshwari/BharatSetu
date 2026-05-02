defmodule BharatCore.Indexer.EventParser do
  @moduledoc """
  Decodes raw Ethereum log entries into domain events.

  Topic hashes (keccak256 of event signature):
    TokensLocked(address,address,uint256,bytes32,bytes32)
    = 0xa4da05d95d26d78a21cff87ae79a365e9e40f1b813298b6553033965693e1090

    TokensBurned(address,uint256,bytes32,bytes32) — MintBridge (POC v1)
    = 0x76802cff36c98e0fd357b353b62bdf235862d5c71277fcc4827fce74d4d0a487

    CBDCLocked(address,uint256,bytes32,bytes32,uint8,bytes) — CBDCVault (POC v2)
    = 0x106e28fff448c4af52727f4a2a877a388930773c9c799031b52f7be42d5dbfe8

    TokensBurned(address,uint256,bytes32) — StablecoinBridge (POC v2)
    = 0x52916471973ae53f679d702015168c0a34628d9d95a48de6bd2093661e39a7c3

    AssetLocked(address,address,uint256,bytes32,bytes32,bytes) — AssetVault (POC v2)
    = 0xfebbc5c036aa2aa6ef382b492327c08033496d19d1286f732900cb5d618a70d4

    TokenLocked(address,address,uint256,bytes32,bytes32,bytes,uint256) — EthVault (ETH→SOL)
    = 0x91ddb2b87ff5745539ec0f248ea8515ca55212d12df38a53ef45ccf671c25ba6
  """

  # keccak256("TokensLocked(address,address,uint256,bytes32,bytes32)")
  @tokens_locked_topic "0xa4da05d95d26d78a21cff87ae79a365e9e40f1b813298b6553033965693e1090"

  # keccak256("TokensBurned(address,uint256,bytes32,bytes32)") — MintBridge
  @tokens_burned_topic "0x76802cff36c98e0fd357b353b62bdf235862d5c71277fcc4827fce74d4d0a487"

  # keccak256("CBDCLocked(address,uint256,bytes32,bytes32,uint8,bytes)") — CBDCVault
  @cbdc_locked_topic "0x106e28fff448c4af52727f4a2a877a388930773c9c799031b52f7be42d5dbfe8"

  # keccak256("TokensBurned(address,uint256,bytes32)") — StablecoinBridge
  @stablecoin_burned_topic "0x52916471973ae53f679d702015168c0a34628d9d95a48de6bd2093661e39a7c3"

  # keccak256("AssetLocked(address,address,uint256,bytes32,bytes32,bytes)") — AssetVault
  @asset_locked_topic "0xfebbc5c036aa2aa6ef382b492327c08033496d19d1286f732900cb5d618a70d4"

  # keccak256("TokenLocked(address,address,uint256,bytes32,bytes32,bytes,uint256)") — EthVault
  @eth_vault_locked_topic "0x91ddb2b87ff5745539ec0f248ea8515ca55212d12df38a53ef45ccf671c25ba6"

  def tokens_locked_topic, do: @tokens_locked_topic
  def tokens_burned_topic, do: @tokens_burned_topic
  def cbdc_locked_topic, do: @cbdc_locked_topic
  def stablecoin_burned_topic, do: @stablecoin_burned_topic
  def asset_locked_topic, do: @asset_locked_topic
  def eth_vault_locked_topic, do: @eth_vault_locked_topic

  # ETH→SOL: TokenLocked from EthVault (Sepolia)
  # event TokenLocked(address indexed sender, address indexed token, uint256 amount,
  #                   bytes32 crossChainId, bytes32 nonceHash, bytes destWallet, uint256 timeoutAt)
  # data layout: amount(32) + crossChainId(32) + nonceHash(32) + destWallet_offset(32) + timeoutAt(32)
  #              + destWallet_len(32) + destWallet_data(padded)
  def parse(%{"topics" => [@eth_vault_locked_topic | _rest]} = log) do
    data = log["data"] || "0x"
    # crossChainId — bytes 32..63 of data
    cross_chain_id_hex = "0x" <> decode_bytes32_hex(data, 32)
    transfer_id = cross_chain_id_hex

    # destWallet: dynamic bytes at word offset 96 (word 3 = offset pointer)
    # actual data starts at the offset encoded at word 3
    dest_wallet = decode_dest_wallet(data)

    event = %{
      sender:        decode_address(Enum.at(log["topics"], 1)),
      token_address: decode_address(Enum.at(log["topics"], 2)),
      amount:        decode_uint256(data, 0),
      cross_chain_id: cross_chain_id_hex,
      transfer_id:   transfer_id,
      dest_wallet:   dest_wallet,
      tx_hash:       log["transactionHash"],
      block_number:  decode_block_number(log["blockNumber"])
    }

    require Logger
    Logger.info("[EventParser] eth_vault_locked transfer_id=#{transfer_id} amount=#{event.amount} dest=#{dest_wallet} tx=#{event.tx_hash}")
    {:eth_vault_locked, event}
  end

  # Amoy→Sepolia: TokensLocked from LockBridge
  def parse(%{"topics" => [@tokens_locked_topic | _rest]} = log) do
    topics = log["topics"]
    data   = log["data"] || "0x"

    event = %{
      wallet:          decode_address(Enum.at(topics, 1)),
      token_address:   decode_address(Enum.at(topics, 2)),
      amount:          decode_uint256(data, 0),
      nonce_hash:      "0x" <> decode_bytes32_hex(data, 32),
      transfer_id:     bytes32_to_uuid(decode_bytes32_hex(data, 64)),
      tx_hash:         log["transactionHash"],
      block_number:    decode_block_number(log["blockNumber"])
    }

    {:tokens_locked, event}
  end

  # Sepolia→Amoy: TokensBurned from MintBridge
  def parse(%{"topics" => [@tokens_burned_topic | _rest]} = log) do
    topics = log["topics"]
    data   = log["data"] || "0x"

    event = %{
      wallet:       decode_address(Enum.at(topics, 1)),
      amount:       decode_uint256(data, 0),
      nonce_hash:   "0x" <> decode_bytes32_hex(data, 32),
      transfer_id:  bytes32_to_uuid(decode_bytes32_hex(data, 64)),
      tx_hash:      log["transactionHash"],
      block_number: decode_block_number(log["blockNumber"])
    }

    {:tokens_burned, event}
  end

  # POC v2: CBDCLocked from CBDCVault
  # Event: CBDCLocked(address indexed wallet, uint256 amount, bytes32 nonceHash,
  #                   bytes32 transferId, uint8 transferType, bytes instructionPayload)
  # topics[1] = wallet (indexed)
  # data: amount(32) + nonceHash(32) + transferId(32) + transferType(32) +
  #       payloadOffset(32) + payloadLength(32) + payloadData(padded)
  def parse(%{"topics" => [@cbdc_locked_topic | _rest]} = log) do
    topics = log["topics"]
    data   = log["data"] || "0x"

    {transfer_type, instruction_payload} = decode_cbdc_locked_extra(data)

    event = %{
      wallet:               decode_address(Enum.at(topics, 1)),
      amount:               decode_uint256(data, 0),
      nonce_hash:           "0x" <> decode_bytes32_hex(data, 32),
      transfer_id:          bytes32_to_uuid(decode_bytes32_hex(data, 64)),
      transfer_type:        transfer_type,
      instruction_payload:  instruction_payload,
      tx_hash:              log["transactionHash"],
      block_number:         decode_block_number(log["blockNumber"])
    }

    {:cbdc_locked, event}
  end

  # POC v2: TokensBurned from StablecoinBridge (reverse flow)
  def parse(%{"topics" => [@stablecoin_burned_topic | _rest]} = log) do
    topics = log["topics"]
    data   = log["data"] || "0x"

    event = %{
      wallet:       decode_address(Enum.at(topics, 1)),
      amount:       decode_uint256(data, 0),
      transfer_id:  bytes32_to_uuid(decode_bytes32_hex(data, 32)),
      tx_hash:      log["transactionHash"],
      block_number: decode_block_number(log["blockNumber"])
    }

    {:stablecoin_burned, event}
  end

  # POC v2: AssetLocked from AssetVault
  # Event: AssetLocked(address indexed wallet, address indexed tokenContract,
  #                    uint256 tokenId, bytes32 nonceHash, bytes32 transferId, bytes instructionPayload)
  # topics[1] = wallet (indexed), topics[2] = tokenContract (indexed)
  # data: tokenId(32) + nonceHash(32) + transferId(32) + payloadOffset(32) +
  #       payloadLength(32) + payloadData(padded)
  def parse(%{"topics" => [@asset_locked_topic | _rest]} = log) do
    topics = log["topics"]
    data   = log["data"] || "0x"

    instruction_payload = decode_dynamic_bytes(data, 96)

    event = %{
      wallet:               decode_address(Enum.at(topics, 1)),
      token_contract:       decode_address(Enum.at(topics, 2)),
      token_id:             decode_uint256(data, 0),
      nonce_hash:           "0x" <> decode_bytes32_hex(data, 32),
      transfer_id:          bytes32_to_uuid(decode_bytes32_hex(data, 64)),
      instruction_payload:  instruction_payload,
      tx_hash:              log["transactionHash"],
      block_number:         decode_block_number(log["blockNumber"])
    }

    {:asset_locked, event}
  end

  def parse(log), do: {:unknown, log}

  # ── Decoders ──────────────────────────────────────────────────────────────

  defp decode_address("0x" <> hex) do
    "0x" <> String.slice(hex, -40, 40)
  end

  defp decode_uint256("0x" <> hex, byte_offset) do
    hex
    |> String.slice(byte_offset * 2, 64)
    |> String.to_integer(16)
  end

  defp decode_bytes32_hex("0x" <> hex, byte_offset) do
    String.slice(hex, byte_offset * 2, 64)
  end

  # CBDCLocked: decode transferType (word 3) + instructionPayload (dynamic, word 4 is offset)
  defp decode_cbdc_locked_extra("0x" <> hex) do
    transfer_type = String.slice(hex, 192, 64) |> String.to_integer(16)
    payload = decode_dynamic_bytes_hex(hex, 128)
    {transfer_type, payload}
  end

  # Decode ABI-encoded dynamic bytes[] at static word position `word_byte_offset`.
  # That word contains the absolute byte offset to the length+data section.
  defp decode_dynamic_bytes("0x" <> hex, word_byte_offset) do
    decode_dynamic_bytes_hex(hex, word_byte_offset)
  end

  defp decode_dynamic_bytes_hex(hex, word_byte_offset) do
    # Read the offset pointer (absolute byte offset from start of data)
    data_offset = String.slice(hex, word_byte_offset * 2, 64) |> String.to_integer(16)
    # Length of bytes at data_offset
    len = String.slice(hex, data_offset * 2, 64) |> String.to_integer(16)
    if len == 0 do
      ""
    else
      "0x" <> String.slice(hex, (data_offset + 32) * 2, len * 2)
    end
  end

  # Decode destWallet from EthVault TokenLocked event data.
  # destWallet is `bytes` at ABI word 3 (byte offset 96).
  # The frontend encodes Solana pubkey as 32-byte left-padded hex, so we return base58.
  defp decode_dest_wallet("0x" <> hex) do
    # Word 3 (bytes 96..127) = offset pointer to length+data section
    offset = String.slice(hex, 192, 64) |> String.to_integer(16)
    # Length at that offset (bytes)
    len = String.slice(hex, offset * 2, 64) |> String.to_integer(16)

    if len == 0 do
      nil
    else
      raw = String.slice(hex, (offset + 32) * 2, len * 2)
      # Solana pubkey is 32 bytes, possibly left-padded to 32/64 bytes
      pubkey_hex =
        cond do
          len == 32 -> raw
          len == 64 -> String.slice(raw, 64, 64)  # right 32 bytes if 64-byte padded
          len > 32  -> String.slice(raw, (len - 32) * 2, 64)
          true      -> String.pad_leading(raw, 64, "0")
        end

      bytes58_encode(pubkey_hex)
    end
  end

  @b58_alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  defp bytes58_encode(hex) do
    bytes = Base.decode16!(hex, case: :lower)
    n = :binary.decode_unsigned(bytes)
    leading_zeros = count_leading_zero_bytes(bytes)
    encoded = do_encode58(n, [])
    String.duplicate("1", leading_zeros) <> :erlang.list_to_binary(encoded)
  end

  defp do_encode58(0, acc), do: acc
  defp do_encode58(n, acc), do: do_encode58(div(n, 58), [Enum.at(@b58_alphabet, rem(n, 58)) | acc])

  defp count_leading_zero_bytes(<<0, rest::binary>>), do: 1 + count_leading_zero_bytes(rest)
  defp count_leading_zero_bytes(_), do: 0

  defp decode_block_number("0x" <> hex), do: String.to_integer(hex, 16)
  defp decode_block_number(n) when is_integer(n), do: n

  defp bytes32_to_uuid(hex) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12, _::binary>> = hex
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
