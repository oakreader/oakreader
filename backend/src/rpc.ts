/**
 * JSON-RPC 2.0 over newline-delimited stdio.
 *
 * Symmetric by construction: this module does not distinguish "our" requests
 * from "theirs". A reverse call (tool/execute, oauth/prompt) is an ordinary
 * request that happens to depart rather than arrive, so it reuses the same
 * `pending` map and the same correlation. The previous protocol needed a
 * separate waiter table per reverse call, each keyed by a string-concatenated
 * parent id, and each cleaned up by scanning for that prefix.
 */
import { RpcError } from "./protocol.generated.js";

export interface RpcErrorObject {
  code: number;
  message: string;
  data?: unknown;
}

export interface Envelope {
  jsonrpc: "2.0";
  id?: string;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: RpcErrorObject;
}

/** Thrown by handlers to answer with a specific code rather than a generic failure. */
export class RpcFailure extends Error {
  constructor(readonly code: number, message: string, readonly data?: unknown) {
    super(message);
  }
}

/** Anything that validates and narrows incoming params — a zod schema. */
interface ParamSchema<T> {
  parse(value: unknown): T;
}

type RequestHandler<T> = (params: T, id: string) => Promise<unknown> | unknown;
type NotificationHandler<T> = (params: T) => void;

export class RpcPeer {
  private readonly requests = new Map<string, {
    schema: ParamSchema<unknown>;
    handler: RequestHandler<any>;
  }>();
  private readonly notifications = new Map<string, {
    schema: ParamSchema<unknown>;
    handler: NotificationHandler<any>;
  }>();
  /** Reverse calls we have sent, awaiting the shell's answer. */
  private readonly pending = new Map<string, {
    resolve(value: unknown): void;
    reject(error: Error): void;
  }>();
  private nextId = 0;

  constructor(
    private readonly write: (line: string) => void,
    private readonly log: (message: string) => void,
  ) {}

  /**
   * Validation belongs to the peer, not to each handler: it is the only place
   * that knows a params failure must answer -32602 rather than a generic
   * internal error, and doing it here means no handler can forget.
   */
  onRequest<T>(method: string, schema: ParamSchema<T>, handler: RequestHandler<T>): void {
    this.requests.set(method, { schema, handler });
  }

  onNotification<T>(method: string, schema: ParamSchema<T>, handler: NotificationHandler<T>): void {
    this.notifications.set(method, { schema, handler });
  }

  notify(method: string, params: unknown): void {
    this.send({ jsonrpc: "2.0", method, params });
  }

  /** Ask the shell to do something and wait for its answer. */
  callClient<R>(method: string, params: unknown): Promise<R> {
    const id = `s${++this.nextId}`;
    return new Promise<R>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.send({ jsonrpc: "2.0", id, method, params });
    });
  }

  /** Fail every outstanding reverse call — the peer is gone or the parent died. */
  failPending(predicate: (id: string) => boolean, error: Error): void {
    for (const [id, waiter] of [...this.pending]) {
      if (!predicate(id)) continue;
      this.pending.delete(id);
      waiter.reject(error);
    }
  }

  /** Feed one received line. Never throws: a bad line is answered or logged. */
  async handleLine(line: string): Promise<void> {
    let envelope: Envelope;
    try {
      envelope = JSON.parse(line);
    } catch {
      this.send({ jsonrpc: "2.0", id: undefined, error: { code: RpcError.parseError, message: "invalid JSON" } });
      return;
    }
    if (envelope.method !== undefined) {
      if (envelope.id !== undefined) await this.serveRequest(envelope.id, envelope.method, envelope.params);
      else this.serveNotification(envelope.method, envelope.params);
      return;
    }
    // A response to something we sent.
    const id = envelope.id;
    if (id === undefined) {
      this.log("envelope with neither method nor id");
      return;
    }
    const waiter = this.pending.get(id);
    if (!waiter) return;            // late answer to a cancelled call
    this.pending.delete(id);
    if (envelope.error) waiter.reject(new RpcFailure(envelope.error.code, envelope.error.message, envelope.error.data));
    else waiter.resolve(envelope.result);
  }

  private async serveRequest(id: string, method: string, params: unknown): Promise<void> {
    const entry = this.requests.get(method);
    if (!entry) {
      this.send({ jsonrpc: "2.0", id, error: { code: RpcError.methodNotFound, message: `unknown method ${method}` } });
      return;
    }
    let parsed: unknown;
    try {
      parsed = entry.schema.parse(params ?? {});
    } catch (error) {
      this.send({ jsonrpc: "2.0", id, error: {
        code: RpcError.invalidParams,
        message: error instanceof Error ? error.message : "invalid params",
      } });
      return;
    }
    try {
      const result = await entry.handler(parsed, id);
      this.send({ jsonrpc: "2.0", id, result: result ?? {} });
    } catch (error) {
      if (error instanceof RpcFailure) {
        this.send({ jsonrpc: "2.0", id, error: { code: error.code, message: error.message, data: error.data } });
      } else {
        this.send({ jsonrpc: "2.0", id, error: {
          code: RpcError.internalError,
          message: error instanceof Error ? error.message : String(error),
        } });
      }
    }
  }

  private serveNotification(method: string, params: unknown): void {
    const entry = this.notifications.get(method);
    if (!entry) return;          // notifications are fire-and-forget by definition
    try {
      entry.handler(entry.schema.parse(params ?? {}));
    } catch (error) {
      this.log(`notification ${method} failed: ${error instanceof Error ? error.message : error}`);
    }
  }

  private send(envelope: Envelope): void {
    this.write(JSON.stringify(envelope) + "\n");
  }
}
