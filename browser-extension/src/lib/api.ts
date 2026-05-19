import type { PageCapture, PDFSavePayload } from "./types";

const SERVER_BASE = "http://127.0.0.1:23119";
const SNAPSHOT_URL = `${SERVER_BASE}/snapshot`;

export async function postSnapshot(
  payload: PageCapture | PDFSavePayload
): Promise<{ status: string; message?: string }> {
  const body: Record<string, unknown> = {
    ...payload,
  };

  const response = await fetch(SNAPSHOT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  return response.json();
}
