defmodule BharatWeb.HealthController do
  use BharatWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok", version: "0.1.0"})
  end
end
