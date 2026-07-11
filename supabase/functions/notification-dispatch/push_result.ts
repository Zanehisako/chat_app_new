export type SendResult = {
  ok: boolean;
  retryable?: boolean;
  invalidToken?: boolean;
  error?: string;
  providerMessageId?: string;
};

export function fcmResponseResult(status: number, body: string): SendResult {
  if (status >= 200 && status < 300) {
    return { ok: true };
  }
  return {
    ok: false,
    invalidToken: /UNREGISTERED|SENDER_ID_MISMATCH/.test(body),
    retryable: status === 408 || status === 429 || status >= 500,
  };
}

export function wnsResponseResult(status: number): SendResult {
  if (status >= 200 && status < 300) {
    return { ok: true };
  }
  return {
    ok: false,
    invalidToken: status === 404 || status === 410,
    retryable: status === 408 || status === 429 || status >= 500,
  };
}

export function retryDecision(attemptCount: number, nowMs = Date.now()) {
  const terminal = attemptCount >= 8;
  const delaySeconds = Math.min(1800, 2 ** Math.min(attemptCount, 10));
  return {
    status: terminal ? "failed" : "retry",
    nextAttemptAt: new Date(
      terminal ? nowMs : nowMs + delaySeconds * 1000,
    ).toISOString(),
  } as const;
}
