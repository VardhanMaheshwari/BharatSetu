defmodule BharatAdapters.Blockchain.ABI do
  @moduledoc "ABI encoding helpers using ex_abi."

  def encode(abi, function_name, args) do
    selector =
      abi
      |> ABI.parse_specification()
      |> Enum.find(fn f -> f.function == function_name end)

    ABI.encode(selector, args)
  end

  def decode(abi, function_name, data) do
    selector =
      abi
      |> ABI.parse_specification()
      |> Enum.find(fn f -> f.function == function_name end)

    ABI.decode(selector, data)
  end

  # keccak256 of a function/event signature string
  def topic_hash(signature) do
    :crypto.hash(:keccak_256, signature) |> Base.encode16(case: :lower)
  end
end
