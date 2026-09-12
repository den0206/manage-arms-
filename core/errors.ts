export type ErrorCode =
  | "WRITE_GUARD_DENIED"
  | "INVALID_NAME"
  | "NOT_IN_REGISTRY"
  | "SYMLINK_OUTSIDE_STORE"
  | "LOCK_TIMEOUT"
  | "NOT_FOUND"
  | "ALREADY_EXISTS"
  | "FETCH_FAILED"
  | "REMOTE_ENV"
  | "UNTRUSTED_WORKSPACE"
  | "SCHEMA_UNSUPPORTED"
  | "OPERATION_FAILED";

export class AgentToolError extends Error {
  constructor(readonly code: ErrorCode, message: string) {
    super(message);
    this.name = "AgentToolError";
  }
}
