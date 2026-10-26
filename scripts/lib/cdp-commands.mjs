export class CDPCommandError extends Error {
  constructor(method, sessionId, reason, fatal = false) {
    super(`CDP ${method}${sessionId ? ` [${sessionId}]` : ""}: ${reason}`);
    this.fatal = fatal;
  }
}

// Every DevTools command has a deadline. Register before sending: a fast reply must not be lost.
export function createCDPSender(socket, { timeoutMs = 15_000 } = {}) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error("CDP timeout must be positive and finite");
  let nextId = 1, closed = false;
  const pending = new Map();
  function finish(id, error, result, fatal = false) {
    const request = pending.get(id);
    if (!request) return;
    pending.delete(id);
    clearTimeout(request.timer);
    if (error) request.reject(new CDPCommandError(request.method, request.sessionId, error, fatal));
    else request.resolve(result);
  }
  function close(reason) {
    closed = true;
    for (const id of pending.keys()) finish(id, reason, undefined, true);
  }
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id) finish(message.id, message.error?.message, message.result);
  });
  socket.addEventListener("close", () => close("connection closed"));
  socket.addEventListener("error", () => close("connection error"));
  return {
    get pendingCount() { return pending.size; },
    send(method, params = {}, sessionId) {
      if (closed) return Promise.reject(new CDPCommandError(method, sessionId, "connection closed", true));
      const id = nextId++;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          finish(id, `timed out after ${timeoutMs} ms`, undefined, true);
          close("connection stopped after a command timeout");
        }, timeoutMs);
        pending.set(id, { resolve, reject, timer, method, sessionId });
        try { socket.send(JSON.stringify({ id, method, params, sessionId })); }
        catch (error) { finish(id, error.message, undefined, true); }
      });
    },
  };
}
