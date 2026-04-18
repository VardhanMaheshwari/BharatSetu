import { getChallenge, verifySignature } from "./api";

const DOMAIN = process.env.NEXT_PUBLIC_DOMAIN ?? "bharatsetu.in";

export async function siweLogin(
  wallet: string,
  signMessage: (msg: string) => Promise<string>
): Promise<string> {
  const { nonce, expiry } = await getChallenge(wallet);

  const message = buildSiweMessage({ wallet, nonce, expiry });
  const signature = await signMessage(message);
  const { token } = await verifySignature(message, signature);

  localStorage.setItem("jwt", token);
  localStorage.setItem("wallet", wallet);
  return token;
}

export function buildSiweMessage({
  wallet,
  nonce,
  expiry,
}: {
  wallet: string;
  nonce: string;
  expiry: string;
}): string {
  return [
    `${DOMAIN} wants you to sign in with your Ethereum account:`,
    wallet,
    "",
    "Sign in to BharatSetu — Cross-Chain Carbon Credit Bridge",
    "",
    `URI: https://${DOMAIN}`,
    "Version: 1",
    "Chain ID: 80002",
    `Nonce: ${nonce}`,
    `Issued At: ${new Date().toISOString()}`,
    `Expiration Time: ${expiry}`,
  ].join("\n");
}

export function isLoggedIn(): boolean {
  return typeof window !== "undefined" && !!localStorage.getItem("jwt");
}

export function logout(): void {
  localStorage.removeItem("jwt");
  localStorage.removeItem("wallet");
}
