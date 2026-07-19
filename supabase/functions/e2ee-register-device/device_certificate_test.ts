import {
  deviceCertificatePayload,
  verifyDeviceCertificate,
} from "./device_certificate.ts";

Deno.test("device certificate binds the account, device, and both public keys", async () => {
  const generatedKeys = await crypto.subtle.generateKey(
    { name: "Ed25519" },
    true,
    ["sign", "verify"],
  );
  if (!("publicKey" in generatedKeys)) {
    throw new Error("Ed25519 did not return a key pair.");
  }
  const keys = generatedKeys;
  const publicKey = new Uint8Array(
    await crypto.subtle.exportKey("raw", keys.publicKey),
  );
  const payload = {
    userId: "10000000-0000-4000-8000-000000000001",
    deviceId: "10000000-0000-4000-8000-000000000002",
    encryptionPublicKey: base64Url(new Uint8Array(32).fill(7)),
    signingPublicKey: base64Url(new Uint8Array(32).fill(8)),
  };
  const certificate = new Uint8Array(await crypto.subtle.sign(
    "Ed25519",
    keys.privateKey,
    deviceCertificatePayload(payload),
  ));

  if (!await verifyDeviceCertificate({
    ...payload,
    accountSigningPublicKey: base64Url(publicKey),
    certificate: base64Url(certificate),
  })) {
    throw new Error("A valid device certificate was rejected.");
  }
  if (await verifyDeviceCertificate({
    ...payload,
    deviceId: "10000000-0000-4000-8000-000000000003",
    accountSigningPublicKey: base64Url(publicKey),
    certificate: base64Url(certificate),
  })) {
    throw new Error("A certificate was accepted for a different device.");
  }
});

function base64Url(value: Uint8Array) {
  return btoa(String.fromCharCode(...value))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}
