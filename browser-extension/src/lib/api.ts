import type { CollectionInfo, PageCapture, PDFSavePayload, TagNodeInfo } from "./types";

const SERVER_BASE = "http://127.0.0.1:23119";
const SNAPSHOT_URL = `${SERVER_BASE}/snapshot`;
const COLLECTIONS_URL = `${SERVER_BASE}/collections`;
const TAGS_URL = `${SERVER_BASE}/tags`;
const SELECTED_COLLECTION_URL = `${SERVER_BASE}/selected-collection`;

export async function fetchCollections(signal?: AbortSignal): Promise<CollectionInfo[]> {
  const response = await fetch(COLLECTIONS_URL, { signal });
  return response.json();
}

export async function fetchTags(signal?: AbortSignal): Promise<TagNodeInfo[]> {
  const response = await fetch(TAGS_URL, { signal });
  return response.json();
}

export async function fetchSelectedCollection(signal?: AbortSignal): Promise<string | null> {
  const response = await fetch(SELECTED_COLLECTION_URL, { signal });
  const data: { id: string | null } = await response.json();
  return data.id;
}

export async function postSnapshot(
  payload: PageCapture | PDFSavePayload,
  collectionId: string | undefined,
  tagOptionIds: string[],
  newTags: string[] = []
): Promise<{ status: string; message?: string }> {
  const body: Record<string, unknown> = {
    ...payload,
    collectionId,
  };

  if (tagOptionIds.length > 0) {
    body.tagOptionIds = tagOptionIds;
  }

  if (newTags.length > 0) {
    body.newTags = newTags;
  }

  const response = await fetch(SNAPSHOT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  return response.json();
}
