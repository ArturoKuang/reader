import type {
  BooksResponse,
  ConflictsResponse,
  DevicesResponse,
  HealthResponse,
  PullResponse,
  PushRequest,
  PushResponse,
  RedeemRequest,
  RedeemResponse,
  RegisterBookRequest,
  RegisterBookResponse,
} from "./wire";

export class SyncNetworkError extends Error {
  constructor(message = "network unavailable") {
    super(message);
    this.name = "SyncNetworkError";
  }
}

export class SyncApiError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = "SyncApiError";
    this.status = status;
    this.code = code;
  }
}

export interface BlobPart {
  status: number;
  body: Uint8Array;
  etag: string | null;
  contentRange: string | null;
}

export interface SyncTransport {
  health(): Promise<HealthResponse>;
  redeem(body: RedeemRequest): Promise<RedeemResponse>;
  devices(): Promise<DevicesResponse>;
  push(body: PushRequest): Promise<PushResponse>;
  pull(since: number, limit: number): Promise<PullResponse>;
  registerBook(body: RegisterBookRequest): Promise<RegisterBookResponse>;
  books(): Promise<BooksResponse>;
  conflicts(bookId?: string): Promise<ConflictsResponse>;
  blob(sha256: string, range?: { start: number; end: number }, ifRange?: string): Promise<BlobPart>;
}

export interface HttpTransportOptions {
  /** Pairing QR origin, for example `http://100.97.87.111:8788`. Null until paired. */
  baseUrl: () => string | null;
  credential: () => string | null;
  fetchImpl?: typeof fetch;
}

/**
 * `fetch` against the origin from the pairing QR. There is no built-in host or port.
 */
export class HttpTransport implements SyncTransport {
  constructor(private readonly options: HttpTransportOptions) {}

  health(): Promise<HealthResponse> {
    return this.json("GET", "/v1/health");
  }

  redeem(body: RedeemRequest): Promise<RedeemResponse> {
    return this.json("POST", "/v1/pairing/redeem", body, false);
  }

  devices(): Promise<DevicesResponse> {
    return this.json("GET", "/v1/devices");
  }

  push(body: PushRequest): Promise<PushResponse> {
    return this.json("POST", "/v1/changes", body);
  }

  pull(since: number, limit: number): Promise<PullResponse> {
    return this.json("GET", `/v1/changes?since=${since}&limit=${limit}`);
  }

  registerBook(body: RegisterBookRequest): Promise<RegisterBookResponse> {
    return this.json("POST", "/v1/books", body);
  }

  books(): Promise<BooksResponse> {
    return this.json("GET", "/v1/books");
  }

  conflicts(bookId?: string): Promise<ConflictsResponse> {
    const query = bookId ? `?bookId=${encodeURIComponent(bookId)}` : "";
    return this.json("GET", `/v1/conflicts${query}`);
  }

  async blob(sha256: string, range?: { start: number; end: number }, ifRange?: string): Promise<BlobPart> {
    const headers = new Headers();
    if (range) headers.set("range", `bytes=${range.start}-${range.end}`);
    if (ifRange) headers.set("if-range", ifRange);
    const response = await this.send("GET", `/v1/blobs/${sha256}`, undefined, headers);
    if (!response.ok && response.status !== 206) await this.raise(response);
    const buffer = new Uint8Array(await response.arrayBuffer());
    return {
      status: response.status,
      body: buffer,
      etag: response.headers.get("etag"),
      contentRange: response.headers.get("content-range"),
    };
  }

  private async json<T>(method: string, path: string, body?: unknown, authorize = true): Promise<T> {
    const response = await this.send(method, path, body, new Headers(), authorize);
    if (!response.ok) await this.raise(response);
    return (await response.json()) as T;
  }

  private async send(method: string, path: string, body: unknown, headers: Headers, authorize = true): Promise<Response> {
    const baseUrl = this.options.baseUrl();
    if (!baseUrl) throw new SyncNetworkError("not paired");
    if (authorize) {
      const credential = this.options.credential();
      if (credential) headers.set("authorization", `Bearer ${credential}`);
    }
    if (body !== undefined) headers.set("content-type", "application/json");
    try {
      const fetchImpl = this.options.fetchImpl ?? fetch;
      return await fetchImpl(`${baseUrl}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : "network unavailable";
      throw new SyncNetworkError(message);
    }
  }

  private async raise(response: Response): Promise<never> {
    let code = "bad_request";
    let message = response.statusText || "request failed";
    try {
      const body = (await response.json()) as { error?: { code?: string; message?: string } };
      if (body.error?.code) code = body.error.code;
      if (body.error?.message) message = body.error.message;
    } catch {
      // non-JSON error body
    }
    throw new SyncApiError(response.status, code, message);
  }
}
