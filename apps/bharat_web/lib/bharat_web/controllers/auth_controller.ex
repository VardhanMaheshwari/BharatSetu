defmodule BharatWeb.AuthController do
  use BharatWeb, :controller

  alias BharatCore.Auth.SiweVerifier
  alias BharatWeb.Auth.Guardian

  @nonce_ttl_seconds 300

  def challenge(conn, %{"wallet" => wallet}) do
    nonce = generate_nonce()
    :ok = store_nonce(nonce, wallet)

    json(conn, %{
      nonce: nonce,
      domain: "bharatsetu.in",
      expiry: DateTime.add(DateTime.utc_now(), @nonce_ttl_seconds, :second) |> DateTime.to_iso8601()
    })
  end

  def verify(conn, %{"message" => message, "signature" => signature}) do
    with {:ok, wallet} <- SiweVerifier.verify(message, signature),
         {:ok, token, _claims} <- Guardian.encode_and_sign(wallet, %{}, token_type: :access) do
      json(conn, %{token: token, wallet: wallet})
    else
      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: inspect(reason)})
    end
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp store_nonce(nonce, wallet) do
    {:ok, _} = Redix.command(:redix, ["SETEX", "nonce:#{nonce}", @nonce_ttl_seconds, wallet])
    :ok
  end
end
