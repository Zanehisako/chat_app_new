export function webhookEventTimestamp(
  createdAt: bigint | number | string | undefined,
  fallback = new Date(),
): string {
  if (createdAt === undefined) return fallback.toISOString();
  const seconds = Number(createdAt);
  if (!Number.isFinite(seconds) || seconds <= 0) return fallback.toISOString();
  return new Date(seconds * 1000).toISOString();
}
