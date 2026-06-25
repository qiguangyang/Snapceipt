// Uniform error contract. Every error response body is:
//   { error: { code, message, details?, requestId } }  with the matching HTTP status.
// Success bodies are the raw resource/envelope (no wrapper).

export const ERROR = {
  AUTH_INVALID_TOKEN: 401,
  AUTH_SESSION_REVOKED: 401,
  AUTH_DEVICE_MISMATCH: 401,
  AUTH_INVALID_CREDENTIALS: 401,
  VALIDATION_FAILED: 400,
  NOT_FOUND: 404,
  FORBIDDEN: 403,
  RATE_LIMITED: 429,
  CONFLICT: 409,
  GONE: 410,
  NOT_IMPLEMENTED: 501,
  INTERNAL: 500,
} as const;

export type ErrorCode = keyof typeof ERROR;

export type ErrorEnvelope = {
  error: {
    code: ErrorCode;
    message: string;
    details?: unknown;
    requestId: string;
  };
};

export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  readonly details?: unknown;

  constructor(code: ErrorCode, message?: string, details?: unknown) {
    super(message ?? code);
    this.name = "ApiError";
    this.code = code;
    this.status = ERROR[code];
    if (details !== undefined) this.details = details;
  }
}

// Serialize any thrown value into the uniform envelope. Known ApiErrors keep their
// code/message/details; anything else is coerced to a safe 500 INTERNAL (no leak).
export function toEnvelope(err: unknown, requestId: string): ErrorEnvelope {
  if (err instanceof ApiError) {
    const body: ErrorEnvelope["error"] = {
      code: err.code,
      message: err.message,
      requestId,
    };
    if (err.details !== undefined) body.details = err.details;
    return { error: body };
  }
  return {
    error: {
      code: "INTERNAL",
      message: "Internal Server Error",
      requestId,
    },
  };
}
