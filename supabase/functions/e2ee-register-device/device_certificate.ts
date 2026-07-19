const certificateDomain = "chat-app.e2ee.device-certificate/v1";
const encoder = new TextEncoder();

export type DeviceCertificatePayload = {
  userId: string;
  deviceId: string;
  encryptionPublicKey: string;
  signingPublicKey: string;
};

export type DeviceCertificateVerification = DeviceCertificatePayload & {
  accountSigningPublicKey: string;
  certificate: string;
};

export function deviceCertificatePayload(
  value: DeviceCertificatePayload,
): Uint8Array<ArrayBuffer> {
  return encoder.encode(JSON.stringify([
    certificateDomain,
    value.userId,
    value.deviceId,
    value.encryptionPublicKey,
    value.signingPublicKey,
  ]));
}

export async function verifyDeviceCertificate(
  value: DeviceCertificateVerification,
): Promise<boolean> {
  try {
    const accountSigningKey = base64UrlBytes(value.accountSigningPublicKey);
    const certificate = base64UrlBytes(value.certificate);
    if (accountSigningKey.byteLength !== 32 || certificate.byteLength !== 64) {
      return false;
    }
    const key = await crypto.subtle.importKey(
      "raw",
      accountSigningKey,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      "Ed25519",
      key,
      certificate,
      deviceCertificatePayload(value),
    );
  } catch (_) {
    return false;
  }
}

export function isUnpaddedBase64Url(
  value: unknown,
  minimumLength: number,
  maximumLength: number,
): value is string {
  return typeof value === "string" &&
    value.length >= minimumLength &&
    value.length <= maximumLength &&
    /^[A-Za-z0-9_-]+$/.test(value);
}

function base64UrlBytes(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error("Invalid base64url value");
  }
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}
