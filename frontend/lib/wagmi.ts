import { createConfig, http } from "wagmi";
import { polygonAmoy, sepolia } from "wagmi/chains";
import { injected, walletConnect } from "wagmi/connectors";

export const config = createConfig({
  chains: [polygonAmoy, sepolia],
  connectors: [
    injected(),
    walletConnect({
      projectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "",
    }),
  ],
  transports: {
    [polygonAmoy.id]: http(
      process.env.NEXT_PUBLIC_POLYGON_RPC_URL ?? "https://rpc-amoy.polygon.technology",
      { retryCount: 5, retryDelay: 2_000 }
    ),
    [sepolia.id]: http(
      process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ??
      process.env.NEXT_PUBLIC_ALCHEMY_SEPOLIA_URL ??
      "https://ethereum-sepolia-rpc.publicnode.com",
      { retryCount: 2, retryDelay: 4_000 }
    ),
  },
  pollingInterval: 12_000,
});
