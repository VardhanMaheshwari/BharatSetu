defmodule BharatCore.Channel.IdentifierStrategy do
  @moduledoc """
  Behaviour for generating and validating cross-chain transfer identifiers.
  Each channel can override this with a custom implementation via channel config.

  Default: keccak256(channel_id ++ zone_source ++ sequence ++ sender ++ block_timestamp)
  Result is a 0x-prefixed hex bytes32 string stored as cross_chain_id.
  """

  @callback generate(channel_id :: String.t(), zone :: String.t(), sender :: String.t(), context :: map()) :: String.t()
  @callback validate(id :: String.t(), channel_id :: String.t(), zone :: String.t()) :: :ok | {:error, term()}

  defmodule Default do
    @behaviour BharatCore.Channel.IdentifierStrategy

    @impl true
    def generate(channel_id, zone, sender, context) do
      sequence  = Map.get(context, :sequence, :erlang.unique_integer([:positive, :monotonic]))
      timestamp = Map.get(context, :timestamp, System.system_time(:second))

      payload = channel_id <> zone <> Integer.to_string(sequence) <> sender <> Integer.to_string(timestamp)
      hash    = ExKeccak.hash_256(payload)
      "0x" <> Base.encode16(hash, case: :lower)
    end

    @impl true
    def validate(id, _channel_id, _zone) do
      case id do
        "0x" <> hex when byte_size(hex) == 64 -> :ok
        _ -> {:error, :invalid_format}
      end
    end
  end
end
