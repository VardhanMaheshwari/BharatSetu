defmodule BharatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :bharat_web

  @session_options [
    store: :cookie,
    key: "_bharat_setu_key",
    signing_salt: "bharat_setu",
    same_site: "Lax"
  ]

  socket "/socket", BharatWeb.UserSocket,
    websocket: true,
    longpoll: false

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug CORSPlug,
    origin: ["http://localhost:3000", "http://localhost:3001"],
    methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug BharatWeb.Router
end
