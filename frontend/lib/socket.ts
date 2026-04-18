// Phoenix WebSocket channel client for real-time transfer updates

const WS_URL = process.env.NEXT_PUBLIC_WS_URL ?? "ws://localhost:4000/socket";

type TransferUpdateHandler = (event: Record<string, unknown>) => void;

export function subscribeToTransfer(
  transferId: string,
  token: string,
  onUpdate: TransferUpdateHandler
): () => void {
  // Dynamic import to avoid SSR issues
  let cleanup = () => {};

  import("phoenix").then(({ Socket }) => {
    const socket = new Socket(WS_URL, { params: { token } });
    socket.connect();

    const channel = socket.channel(`transfer:${transferId}`, {});

    channel.on("state_update", (payload) => onUpdate(payload));

    channel.join()
      .receive("ok", () => console.log(`Joined transfer:${transferId}`))
      .receive("error", (err) => console.error("Channel join error:", err));

    cleanup = () => {
      channel.leave();
      socket.disconnect();
    };
  });

  return () => cleanup();
}
