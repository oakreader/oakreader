import { resolveServerBase } from "./server";
import type { PageCapture, PDFSavePayload } from "./types";

export async function postClip(
  payload: PageCapture | PDFSavePayload,
  serverBase?: string | null
): Promise<{ status: string; message?: string }> {
  const base = serverBase ?? (await resolveServerBase());
  if (!base) {
    return { status: "error", message: "OakReader is not running." };
  }

  const body: Record<string, unknown> = {
    ...payload,
  };

  const response = await fetch(`${base}/clip`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  return response.json();
}
