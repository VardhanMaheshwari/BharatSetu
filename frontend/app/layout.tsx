import dynamic from "next/dynamic";
import "./globals.css";

const Providers = dynamic(
  () => import("./providers").then((m) => m.Providers),
  { ssr: false }
);

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <nav className="navbar">
            <span className="brand">🌿 BharatSetu</span>
            <a href="/dashboard">Dashboard</a>
            <a href="/bridge">Bridge</a>
          </nav>
          <main>{children}</main>
        </Providers>
      </body>
    </html>
  );
}
