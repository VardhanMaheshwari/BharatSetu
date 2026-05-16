defmodule BharatWeb.Plugs.RateLimit do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @max_requests 500
  @window_seconds 60

  def init(opts), do: opts

  def call(conn, _opts) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    key = "rate_limit:#{ip}"

    case check_rate(key) do
      {:ok, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(@max_requests))
        |> put_resp_header("x-ratelimit-remaining", to_string(@max_requests - count))

      {:error, :exceeded} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate limit exceeded"})
        |> halt()
    end
  end

  defp check_rate(key) do
    case Redix.command(:redix, ["INCR", key]) do
      {:ok, 1} ->
        Redix.command(:redix, ["EXPIRE", key, @window_seconds])
        {:ok, 1}

      {:ok, count} when count <= @max_requests ->
        {:ok, count}

      {:ok, count} ->
        {:error, :exceeded}

      _ ->
        {:ok, 0}
    end
  end
end
