import { NextRequest, NextResponse } from "next/server";
import { appendFileSync, mkdirSync } from "fs";
import { join } from "path";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const date = new Date().toISOString().slice(0, 10);
    const logDir = join(process.cwd(), "..", "_dev_logs");
    mkdirSync(logDir, { recursive: true });
    const line = JSON.stringify({ ts: new Date().toISOString(), ...body }) + "\n";
    appendFileSync(join(logDir, `bridge_${date}.jsonl`), line);
    return NextResponse.json({ ok: true });
  } catch {
    return NextResponse.json({ ok: false }, { status: 500 });
  }
}
