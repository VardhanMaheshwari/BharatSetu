defmodule BharatCore.Auth.SiweVerifier do
  @moduledoc """
  Minimal SIWE (EIP-4361) signature verifier.
  Recovers Ethereum address from personal_sign signature and checks
  it matches the address in the message body.
  """

  @doc """
  Returns {:ok, wallet_address} or {:error, reason}.
  """
  def verify(message, signature) do
    with {:ok, sig_bytes}     <- decode_hex(signature),
         {:ok, wallet_in_msg} <- extract_address(message),
         {:ok, recovered}     <- recover_address(message, sig_bytes) do
      if String.downcase(recovered) == String.downcase(wallet_in_msg) do
        {:ok, String.downcase(recovered)}
      else
        {:error, :address_mismatch}
      end
    end
  end

  defp decode_hex("0x" <> hex), do: Base.decode16(hex, case: :mixed)
  defp decode_hex(hex),         do: Base.decode16(hex, case: :mixed)

  # Extract the 0x address line from a SIWE message
  defp extract_address(message) do
    case Regex.run(~r/(0x[0-9a-fA-F]{40})/, message) do
      [_, addr] -> {:ok, addr}
      nil       -> {:error, :no_address_in_message}
    end
  end

  defp recover_address(message, sig_bytes) when byte_size(sig_bytes) == 65 do
    # EIP-191: "\x19Ethereum Signed Message:\n" + length + message
    prefix   = "\x19Ethereum Signed Message:\n#{byte_size(message)}"
    prefixed = prefix <> message
    hash     = ExKeccak.hash_256(prefixed)

    # Signature: r(32) + s(32) + v(1); normalise v to recovery_id 0 or 1
    <<r::binary-32, s::binary-32, v>> = sig_bytes
    recovery_id = rem(if(v >= 27, do: v - 27, else: v), 4)

    case ExSecp256k1.recover_compact(hash, <<r::binary, s::binary>>, recovery_id) do
      {:ok, pub_key} ->
        # Uncompressed pub key is 65 bytes (04 + x + y) — drop the 04 prefix
        key_without_prefix = binary_part(pub_key, 1, 64)
        addr_hash = ExKeccak.hash_256(key_without_prefix)
        # Last 20 bytes = Ethereum address
        <<_::binary-12, addr::binary-20>> = addr_hash
        {:ok, "0x" <> Base.encode16(addr, case: :lower)}

      {:error, reason} ->
        {:error, {:recovery_failed, reason}}
    end
  end

  defp recover_address(_message, _sig), do: {:error, :invalid_signature_length}
end
