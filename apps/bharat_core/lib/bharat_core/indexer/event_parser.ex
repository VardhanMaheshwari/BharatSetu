defmodule BharatCore.Indexer.EventParser do
  @moduledoc """
  Decodes raw Ethereum log entries into domain events.

  Topic hashes (keccak256 of event signature):
    TokensLocked(address,address,uint256,bytes32,bytes32)
    = 0xa4da05d95d26d78a21cff87ae79a365e9e40f1b813298b6553033965693e1090

    TokensBurned(address,uint256,bytes32,bytes32)
    = 0x76802cff36c98e0fd357b353b62bdf235862d5c71277fcc4827fce74d4d0a487
  """

  # keccak256("TokensLocked(address,address,uint256,bytes32,bytes32)")
  @tokens_locked_topic "0xa4da05d95d26d78a21cff87ae79a365e9e40f1b813298b6553033965693e1090"

  # keccak256("TokensBurned(address,uint256,bytes32,bytes32)")
  @tokens_burned_topic "0x76802cff36c98e0fd357b353b62bdf235862d5c71277fcc4827fce74d4d0a487"

  def tokens_locked_topic, do: @tokens_locked_topic
  def tokens_burned_topic, do: @tokens_burned_topic

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
  # Event: TokensBurned(address indexed wallet, uint256 amount, bytes32 nonceHash, bytes32 transferId)
  # topics[1] = wallet (indexed), data = amount(32) + nonceHash(32) + transferId(32)
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

  defp decode_block_number("0x" <> hex), do: String.to_integer(hex, 16)
  defp decode_block_number(n) when is_integer(n), do: n

  defp bytes32_to_uuid(hex) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12, _::binary>> = hex
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
