defmodule BharatWeb.Plugs.VerifyJWT do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- BharatWeb.Auth.Guardian.decode_and_verify(token) do
      assign(conn, :jwt_claims, claims)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid or missing token"})
        |> halt()
    end
  end
end
