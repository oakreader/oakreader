/**
 * The sidecar protocol — the single import site for both halves.
 *
 * `protocol.base.ts` holds the hand-written wire types; everything else is
 * generated from protocol/schema.ts. There is no longer a Swift "mirror" to
 * keep in sync by hand: app/Services/Backend/BackendProtocol.generated.swift
 * comes out of the same schema, and `pnpm protocol:check` fails CI if either
 * side is stale.
 */
export * from "./protocol.base.js";
export * from "./protocol.generated.js";
