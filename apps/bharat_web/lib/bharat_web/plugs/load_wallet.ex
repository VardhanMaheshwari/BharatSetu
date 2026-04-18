defmodule BharatWeb.Plugs.LoadWallet do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    wallet = conn.assigns.jwt_claims["sub"]
    assign(conn, :wallet, wallet)
  end
end
