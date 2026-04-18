"use client";

import { useEffect, useState } from "react";
import { getPrices, listTransfers, Transfer } from "../../lib/api";

const STATE_LABELS: Record<string, string> = {
  init:      "⏳ Awaiting Lock",
  locked:    "🔒 Lock Submitted",
  confirmed: "✅ Confirmed on Chain",
  minted:    "🪙 Tokens Minted",
  completed: "🎉 Completed",
  failed:    "❌ Failed",
};

export default function DashboardPage() {
  const [prices, setPrices] = useState<Record<string, number>>({});
  const [transfers, setTransfers] = useState<Transfer[]>([]);

  useEffect(() => {
    getPrices().then((r) => setPrices(r.data as Record<string, number>));

    const jwt = localStorage.getItem("jwt");
    if (jwt) listTransfers().then((r) => setTransfers(r.data));
  }, []);

  return (
    <div className="page">
      <h1>Dashboard</h1>

      <section className="card">
        <h2>Carbon Credit Prices</h2>
        <table>
          <thead><tr><th>Token</th><th>Price (USD)</th></tr></thead>
          <tbody>
            {Object.entries(prices).map(([k, v]) => (
              <tr key={k}><td>{k}</td><td>${typeof v === "number" ? v.toFixed(4) : "—"}</td></tr>
            ))}
          </tbody>
        </table>
      </section>

      {transfers.length > 0 && (
        <section className="card">
          <h2>Your Transfers</h2>
          <table>
            <thead>
              <tr><th>ID</th><th>Token</th><th>Amount</th><th>Status</th></tr>
            </thead>
            <tbody>
              {transfers.map((t) => (
                <tr key={t.id}>
                  <td><a href={`/bridge?id=${t.id}`}>{t.id.slice(0, 8)}…</a></td>
                  <td>{t.token_address.slice(0, 10)}…</td>
                  <td>{t.amount}</td>
                  <td>{STATE_LABELS[t.state] ?? t.state}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </div>
  );
}
