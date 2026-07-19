import 'dart:convert';
import 'dart:typed_data';

import 'package:bip39_mnemonic/bip39_mnemonic.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sodium/sodium.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'e2ee_draft_protector.dart';
import 'outbox_message_sender.dart';

/// Protocol errors are deliberately safe to display: they never include
/// plaintext, private keys, or ciphertext values.
class E2eeCryptoException implements NonRetryableOutboxSendError {
  const E2eeCryptoException(this.message, [this.cause]);

  @override
  final String message;
  final Object? cause;

  @override
  String toString() => 'E2eeCryptoException: $message';
}

abstract interface class E2eeSecureStore {
  Future<String?> read(String key);

  Future<void> write({required String key, required String value});

  Future<void> delete(String key);
}

class FlutterE2eeSecureStore implements E2eeSecureStore {
  FlutterE2eeSecureStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) {
    return _storage.write(key: key, value: value);
  }
}

/// A small deterministic store for crypto unit tests. App code must use the
/// platform-backed [FlutterE2eeSecureStore].
class InMemoryE2eeSecureStore implements E2eeSecureStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }
}

class E2eeAccount {
  const E2eeAccount({
    required this.userId,
    required this.recoveryPublicKey,
    required this.signingPublicKey,
    this.protocolVersion = E2eeCryptoService.protocolVersion,
  });

  final String userId;
  final String recoveryPublicKey;
  final String signingPublicKey;
  final int protocolVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'user_id': userId,
    'recovery_public_key': recoveryPublicKey,
    'signing_public_key': signingPublicKey,
    'protocol_version': protocolVersion,
  };

  factory E2eeAccount.fromJson(Map<String, dynamic> value) => E2eeAccount(
    userId: value['user_id']?.toString() ?? '',
    recoveryPublicKey: value['recovery_public_key']?.toString() ?? '',
    signingPublicKey: value['signing_public_key']?.toString() ?? '',
    protocolVersion: _asInt(value['protocol_version']) ?? 1,
  );
}

class E2eeDevice {
  const E2eeDevice({
    required this.id,
    required this.userId,
    required this.encryptionPublicKey,
    required this.signingPublicKey,
    required this.certificate,
    this.label,
    this.protocolVersion = E2eeCryptoService.protocolVersion,
  });

  final String id;
  final String userId;
  final String encryptionPublicKey;
  final String signingPublicKey;
  final String certificate;
  final String? label;
  final int protocolVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'user_id': userId,
    'encryption_public_key': encryptionPublicKey,
    'signing_public_key': signingPublicKey,
    'certificate': certificate,
    'label': label,
    'protocol_version': protocolVersion,
  };

  factory E2eeDevice.fromJson(Map<String, dynamic> value) => E2eeDevice(
    id: value['id']?.toString() ?? value['device_id']?.toString() ?? '',
    userId: value['user_id']?.toString() ?? '',
    encryptionPublicKey: value['encryption_public_key']?.toString() ?? '',
    signingPublicKey: value['signing_public_key']?.toString() ?? '',
    certificate:
        value['certificate']?.toString() ??
        value['device_certificate']?.toString() ??
        '',
    label: _nullableText(value['label']),
    protocolVersion: _asInt(value['protocol_version']) ?? 1,
  );
}

/// Public material used to authenticate a device before consuming any data it
/// signed. The account signing key is supplied by the server’s key-material
/// RPC and independently TOFU-pinned by the client.
class E2eeDeviceIdentity {
  const E2eeDeviceIdentity({
    required this.deviceId,
    required this.userId,
    required this.encryptionPublicKey,
    required this.signingPublicKey,
    required this.certificate,
    required this.accountSigningPublicKey,
  });

  final String deviceId;
  final String userId;
  final String encryptionPublicKey;
  final String signingPublicKey;
  final String certificate;
  final String accountSigningPublicKey;

  factory E2eeDeviceIdentity.fromBackend(Map<String, dynamic> value) {
    return E2eeDeviceIdentity(
      deviceId:
          value['device_id']?.toString() ??
          value['recipient_device_id']?.toString() ??
          value['created_by_device_id']?.toString() ??
          '',
      userId:
          value['user_id']?.toString() ??
          value['recipient_user_id']?.toString() ??
          value['created_by_user_id']?.toString() ??
          '',
      encryptionPublicKey: value['encryption_public_key']?.toString() ?? '',
      signingPublicKey:
          value['signing_public_key']?.toString() ??
          value['creator_device_signing_public_key']?.toString() ??
          value['creator_signing_public_key']?.toString() ??
          '',
      certificate:
          value['certificate']?.toString() ??
          value['device_certificate']?.toString() ??
          value['creator_certificate']?.toString() ??
          value['creator_device_certificate']?.toString() ??
          '',
      accountSigningPublicKey:
          value['account_signing_public_key']?.toString() ??
          value['creator_account_signing_public_key']?.toString() ??
          '',
    );
  }
}

class E2eeEpochRecipient {
  const E2eeEpochRecipient({
    required this.kind,
    required this.userId,
    required this.encryptionPublicKey,
    this.deviceId,
  });

  final String kind;
  final String userId;
  final String? deviceId;
  final String encryptionPublicKey;

  bool get isDevice => kind == 'device';

  factory E2eeEpochRecipient.fromBackend(Map<String, dynamic> value) {
    return E2eeEpochRecipient(
      kind: value['recipient_kind']?.toString() ?? '',
      userId: value['recipient_user_id']?.toString() ?? '',
      deviceId: _nullableText(value['recipient_device_id']),
      encryptionPublicKey: value['encryption_public_key']?.toString() ?? '',
    );
  }
}

class E2eePublishedEnvelope {
  const E2eePublishedEnvelope({
    required this.recipientKind,
    required this.recipientUserId,
    required this.ciphertext,
    this.recipientDeviceId,
  });

  final String recipientKind;
  final String recipientUserId;
  final String? recipientDeviceId;
  final String ciphertext;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'recipient_kind': recipientKind,
    'recipient_user_id': recipientUserId,
    'recipient_device_id': recipientDeviceId,
    'ciphertext': ciphertext,
  };
}

class E2eeKeyEnvelope {
  const E2eeKeyEnvelope({
    required this.conversationId,
    required this.epochId,
    required this.epochNumber,
    required this.membershipVersion,
    required this.commitment,
    required this.epochSignature,
    required this.createdByUserId,
    required this.createdByDeviceId,
    required this.ciphertext,
    required this.creator,
  });

  final String conversationId;
  final String epochId;
  final int epochNumber;
  final int membershipVersion;
  final String commitment;
  final String epochSignature;
  final String createdByUserId;
  final String createdByDeviceId;
  final String ciphertext;
  final E2eeDeviceIdentity creator;

  factory E2eeKeyEnvelope.fromBackend(Map<String, dynamic> value) {
    return E2eeKeyEnvelope(
      conversationId: value['conversation_id']?.toString() ?? '',
      epochId: value['epoch_id']?.toString() ?? '',
      epochNumber: _asInt(value['epoch_number']) ?? 0,
      membershipVersion: _asInt(value['membership_version']) ?? 0,
      commitment: value['commitment']?.toString() ?? '',
      epochSignature: value['epoch_signature']?.toString() ?? '',
      createdByUserId: value['created_by_user_id']?.toString() ?? '',
      createdByDeviceId: value['created_by_device_id']?.toString() ?? '',
      ciphertext:
          value['envelope_ciphertext']?.toString() ??
          value['ciphertext']?.toString() ??
          '',
      creator: E2eeDeviceIdentity.fromBackend(value),
    );
  }
}

class E2eeEpoch {
  E2eeEpoch({
    required this.conversationId,
    required this.epochNumber,
    required this.membershipVersion,
    required Uint8List keyBytes,
    required this.commitment,
    required this.signature,
    this.serverEpochId,
  }) : _keyBytes = Uint8List.fromList(keyBytes);

  final String conversationId;
  final int epochNumber;
  final int membershipVersion;
  final Uint8List _keyBytes;
  final String commitment;
  final String signature;
  final String? serverEpochId;

  Uint8List get keyBytes => Uint8List.fromList(_keyBytes);

  E2eeEpoch copyWith({String? serverEpochId}) => E2eeEpoch(
    conversationId: conversationId,
    epochNumber: epochNumber,
    membershipVersion: membershipVersion,
    keyBytes: _keyBytes,
    commitment: commitment,
    signature: signature,
    serverEpochId: serverEpochId ?? this.serverEpochId,
  );

  Map<String, dynamic> toLocalJson() => <String, dynamic>{
    'conversation_id': conversationId,
    'epoch_number': epochNumber,
    'membership_version': membershipVersion,
    'key': _encode(_keyBytes),
    'commitment': commitment,
    'signature': signature,
    'server_epoch_id': serverEpochId,
  };

  factory E2eeEpoch.fromLocalJson(Map<String, dynamic> value) => E2eeEpoch(
    conversationId: value['conversation_id']?.toString() ?? '',
    epochNumber: _asInt(value['epoch_number']) ?? 0,
    membershipVersion: _asInt(value['membership_version']) ?? 0,
    keyBytes: _decode(value['key']?.toString() ?? ''),
    commitment: value['commitment']?.toString() ?? '',
    signature: value['signature']?.toString() ?? '',
    serverEpochId: _nullableText(value['server_epoch_id']),
  );
}

class E2eeEncryptedPayload {
  const E2eeEncryptedPayload({
    required this.ciphertext,
    required this.nonce,
    required this.signature,
    required this.revision,
  });

  final String ciphertext;
  final String nonce;
  final String signature;
  final int revision;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'protocol_version': E2eeCryptoService.protocolVersion,
    'ciphertext': ciphertext,
    'nonce': nonce,
    'signature': signature,
    'revision': revision,
  };

  factory E2eeEncryptedPayload.fromBackend(Map<String, dynamic> value) {
    return E2eeEncryptedPayload(
      ciphertext:
          value['e2ee_ciphertext']?.toString() ??
          value['ciphertext']?.toString() ??
          '',
      nonce:
          value['e2ee_nonce']?.toString() ?? value['nonce']?.toString() ?? '',
      signature:
          value['e2ee_signature']?.toString() ??
          value['signature']?.toString() ??
          '',
      revision: _asInt(value['e2ee_revision'] ?? value['revision']) ?? 1,
    );
  }
}

class E2eeEncryptedMedia {
  E2eeEncryptedMedia({
    required this.mediaId,
    required this.revision,
    required this.nonce,
    required this.signature,
    Uint8List? ciphertextBytes,
  }) : _ciphertextBytes = ciphertextBytes == null
           ? null
           : Uint8List.fromList(ciphertextBytes);

  final String mediaId;
  final int revision;
  final String nonce;
  final String signature;
  final Uint8List? _ciphertextBytes;

  Uint8List? get ciphertextBytes {
    final bytes = _ciphertextBytes;
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  int? get ciphertextSize => _ciphertextBytes?.length;

  E2eeEncryptedMedia withCiphertextBytes(Uint8List bytes) => E2eeEncryptedMedia(
    mediaId: mediaId,
    revision: revision,
    nonce: nonce,
    signature: signature,
    ciphertextBytes: bytes,
  );

  Uint8List toStorageBytes() {
    final bytes = _ciphertextBytes;
    if (bytes == null) {
      throw const E2eeCryptoException('Encrypted media bytes are unavailable.');
    }
    return Uint8List.fromList(bytes);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'protocol_version': E2eeCryptoService.protocolVersion,
    'media_id': mediaId,
    'revision': revision,
    'nonce': nonce,
    'signature': signature,
    'ciphertext_size': _ciphertextBytes?.length,
  };

  factory E2eeEncryptedMedia.fromJson(Map<String, dynamic> value) {
    return E2eeEncryptedMedia(
      mediaId: value['media_id']?.toString() ?? '',
      revision: _asInt(value['revision']) ?? 1,
      nonce: value['nonce']?.toString() ?? '',
      signature: value['signature']?.toString() ?? '',
    );
  }
}

class E2eeEncryptedReaction {
  const E2eeEncryptedReaction({
    required this.reactionTag,
    required this.ciphertext,
    required this.nonce,
    required this.signature,
  });

  final String reactionTag;
  final String ciphertext;
  final String nonce;
  final String signature;

  factory E2eeEncryptedReaction.fromBackend(Map<String, dynamic> value) {
    return E2eeEncryptedReaction(
      reactionTag: value['reaction_tag']?.toString() ?? '',
      ciphertext: value['ciphertext']?.toString() ?? '',
      nonce: value['nonce']?.toString() ?? '',
      signature: value['signature']?.toString() ?? '',
    );
  }
}

class E2eeIdentityTrustState {
  const E2eeIdentityTrustState({
    required this.fingerprint,
    required this.isVerified,
    required this.hasChanged,
  });

  final String fingerprint;
  final bool isVerified;
  final bool hasChanged;

  bool get isSendBlocked => isVerified && hasChanged;
}

class E2eeReadyState {
  const E2eeReadyState({
    this.account,
    this.device,
    this.requiresRecoveryPhraseConfirmation = false,
    this.requiresRecoveryPhraseRestore = false,
  });

  final E2eeAccount? account;
  final E2eeDevice? device;
  final bool requiresRecoveryPhraseConfirmation;
  final bool requiresRecoveryPhraseRestore;

  bool get isReadyForSending =>
      account != null &&
      device != null &&
      !requiresRecoveryPhraseConfirmation &&
      !requiresRecoveryPhraseRestore;
}

/// Cryptographic state for ChatApp’s practical E2EE v1 protocol.
///
/// It deliberately does not write any private material to Supabase. The
/// repository publishes only [E2eeAccount], [E2eeDevice], epoch envelopes, and
/// ciphertext generated by this service.
class E2eeCryptoService {
  E2eeCryptoService({
    E2eeSecureStore? secureStore,
    Future<Sodium> Function()? sodiumLoader,
  }) : _secureStore = secureStore ?? FlutterE2eeSecureStore(),
       _sodiumLoader = sodiumLoader ?? (() async => await SodiumInit.init());

  static final E2eeCryptoService instance = E2eeCryptoService();
  static const int protocolVersion = 1;
  static const _namespace = 'chat-app.e2ee.v1';

  final E2eeSecureStore _secureStore;
  final Future<Sodium> Function() _sodiumLoader;
  final Uuid _uuid = const Uuid();
  final Map<String, E2eeEpoch> _epochCache = <String, E2eeEpoch>{};
  final Map<String, E2eeAccount> _remoteAccounts = <String, E2eeAccount>{};
  Future<Sodium>? _sodiumFuture;

  Future<void> initialize() async {
    await _sodium();
  }

  Future<E2eeReadyState> ensureReady({
    SupabaseClient? client,
    required String userId,
  }) async {
    _requireId(userId, 'user');
    final sodium = await _sodium();
    final remote = await _readRemoteAccount(client, userId);
    if (remote != null) {
      _remoteAccounts[userId] = remote;
    }

    final localAccount = await _readLocalAccount(userId);
    if (localAccount == null) {
      if (remote != null) {
        return const E2eeReadyState(requiresRecoveryPhraseRestore: true);
      }
      return _createInitialIdentity(userId, sodium);
    }

    if (remote != null &&
        (remote.recoveryPublicKey != localAccount.recoveryPublicKey ||
            remote.signingPublicKey != localAccount.signingPublicKey)) {
      throw const E2eeCryptoException(
        'The stored recovery identity does not match this account. Restore the recovery phrase.',
      );
    }

    var device = await _readLocalDevice(userId);
    device ??= await _createAndStoreDevice(
      sodium: sodium,
      account: localAccount,
    );
    final confirmed = await _secureStore.read(
      _key(userId, 'recovery-confirmed'),
    );
    return E2eeReadyState(
      account: localAccount,
      device: device,
      requiresRecoveryPhraseConfirmation: confirmed != '1',
    );
  }

  /// Returns the newly-generated phrase only until it has been explicitly
  /// confirmed. It is never logged or sent to the server.
  Future<String?> getRecoveryPhrase(String userId) {
    return _secureStore.read(_key(userId, 'pending-recovery-phrase'));
  }

  Future<void> confirmRecoveryPhrase({
    required String userId,
    required String phrase,
  }) async {
    final pending = await getRecoveryPhrase(userId);
    if (pending == null ||
        !_constantTimeTextEquals(pending, _normalizePhrase(phrase))) {
      throw const E2eeCryptoException(
        'The recovery phrase confirmation does not match.',
      );
    }
    await _secureStore.write(
      key: _key(userId, 'recovery-confirmed'),
      value: '1',
    );
    await _secureStore.delete(_key(userId, 'pending-recovery-phrase'));
  }

  Future<E2eeReadyState> restoreFromRecoveryPhrase({
    required String userId,
    required String phrase,
  }) async {
    final sodium = await _sodium();
    final remote = _remoteAccounts[userId];
    if (remote == null) {
      throw const E2eeCryptoException(
        'Open the signed-in account before restoring its recovery phrase.',
      );
    }
    final derived = _deriveAccountFromPhrase(userId, phrase, sodium);
    if (derived.account.recoveryPublicKey != remote.recoveryPublicKey ||
        derived.account.signingPublicKey != remote.signingPublicKey) {
      derived.dispose();
      throw const E2eeCryptoException(
        'That recovery phrase belongs to another account.',
      );
    }
    try {
      await _storeAccount(userId, derived);
      await _secureStore.write(
        key: _key(userId, 'recovery-confirmed'),
        value: '1',
      );
      await _secureStore.delete(_key(userId, 'pending-recovery-phrase'));
      final device = await _createAndStoreDevice(
        sodium: sodium,
        account: derived.account,
      );
      return E2eeReadyState(account: derived.account, device: device);
    } finally {
      derived.dispose();
    }
  }

  /// Replaces a locally retained device identity after the server has revoked
  /// it. The replacement remains certified by the same recovery-derived
  /// account root, so it can open historical recovery envelopes.
  Future<E2eeReadyState> replaceLocalDevice({required String userId}) async {
    final sodium = await _sodium();
    final account = await _readLocalAccount(userId);
    if (account == null) {
      throw const E2eeCryptoException(
        'Restore the recovery phrase before replacing this device.',
      );
    }
    final confirmed = await _secureStore.read(
      _key(userId, 'recovery-confirmed'),
    );
    if (confirmed != '1') {
      throw const E2eeCryptoException(
        'Confirm the recovery phrase before replacing this device.',
      );
    }
    await _secureStore.delete(_key(userId, 'device'));
    await _secureStore.delete(_key(userId, 'device-encryption-private'));
    await _secureStore.delete(_key(userId, 'device-signing-private'));
    final device = await _createAndStoreDevice(
      sodium: sodium,
      account: account,
    );
    return E2eeReadyState(account: account, device: device);
  }

  Future<E2eeIdentityTrustState> observeAccountIdentity({
    required String userId,
    required String signingPublicKey,
  }) async {
    final fingerprint = _fingerprint(signingPublicKey);
    final key = _key(userId, 'account-trust');
    final raw = await _secureStore.read(key);
    if (raw == null) {
      await _secureStore.write(
        key: key,
        value: jsonEncode(<String, dynamic>{
          'observed': fingerprint,
          'verified': false,
          'verified_fingerprint': null,
        }),
      );
      return E2eeIdentityTrustState(
        fingerprint: fingerprint,
        isVerified: false,
        hasChanged: false,
      );
    }
    final data = _jsonMap(raw);
    final verified = data['verified'] == true;
    final verifiedFingerprint = _nullableText(data['verified_fingerprint']);
    final changed =
        verified &&
        verifiedFingerprint != null &&
        verifiedFingerprint != fingerprint;
    await _secureStore.write(
      key: key,
      value: jsonEncode(<String, dynamic>{
        ...data,
        'observed': fingerprint,
        'changed': changed,
      }),
    );
    return E2eeIdentityTrustState(
      fingerprint: fingerprint,
      isVerified: verified,
      hasChanged: changed,
    );
  }

  Future<E2eeIdentityTrustState> trustStateForAccount({
    required String userId,
    required String signingPublicKey,
  }) async {
    return observeAccountIdentity(
      userId: userId,
      signingPublicKey: signingPublicKey,
    );
  }

  Future<void> markAccountIdentityVerified({
    required String userId,
    required String signingPublicKey,
  }) async {
    final fingerprint = _fingerprint(signingPublicKey);
    await _secureStore.write(
      key: _key(userId, 'account-trust'),
      value: jsonEncode(<String, dynamic>{
        'observed': fingerprint,
        'verified': true,
        'verified_fingerprint': fingerprint,
        'changed': false,
      }),
    );
  }

  /// Explicitly clears the send block after the user has independently checked
  /// the changed identity. It leaves the new identity unverified until it is
  /// marked verified through a safety-number check.
  Future<void> acknowledgeAccountIdentityChange({
    required String userId,
    required String signingPublicKey,
  }) async {
    final fingerprint = _fingerprint(signingPublicKey);
    await _secureStore.write(
      key: _key(userId, 'account-trust'),
      value: jsonEncode(<String, dynamic>{
        'observed': fingerprint,
        'verified': false,
        'verified_fingerprint': null,
        'changed': false,
      }),
    );
  }

  Future<E2eeEpoch> createEpoch({
    required String userId,
    required String conversationId,
    required int epochNumber,
    required int membershipVersion,
    String? serverEpochId,
  }) async {
    _requireId(conversationId, 'conversation');
    if (epochNumber < 1 || membershipVersion < 0) {
      throw const E2eeCryptoException('Invalid E2EE epoch metadata.');
    }
    final sodium = await _sodium();
    final device = await _requireLocalDeviceSecrets(userId, sodium);
    final key = sodium.randombytes.buf(
      sodium.crypto.aeadXChaCha20Poly1305IETF.keyBytes,
    );
    final commitment = _encode(
      sodium.crypto.genericHash.call(message: key, outLen: 32),
    );
    final signature = sodium.crypto.sign.detached(
      message: _epochSigningBytes(
        conversationId: conversationId,
        epochNumber: epochNumber,
        membershipVersion: membershipVersion,
        commitment: commitment,
      ),
      secretKey: device.signingPrivateKey,
    );
    device.dispose();
    return E2eeEpoch(
      conversationId: conversationId,
      epochNumber: epochNumber,
      membershipVersion: membershipVersion,
      keyBytes: key,
      commitment: commitment,
      signature: _encode(signature),
      serverEpochId: serverEpochId,
    );
  }

  Future<void> rememberEpoch({
    required String userId,
    required E2eeEpoch epoch,
  }) async {
    _epochCache[_epochCacheKey(
          userId,
          epoch.conversationId,
          epoch.epochNumber,
        )] =
        epoch;
    await _secureStore.write(
      key: _key(userId, 'epoch:${epoch.conversationId}:${epoch.epochNumber}'),
      value: jsonEncode(epoch.toLocalJson()),
    );
  }

  Future<E2eeEpoch?> cachedEpoch({
    required String userId,
    required String conversationId,
    required int epochNumber,
  }) async {
    final cacheKey = _epochCacheKey(userId, conversationId, epochNumber);
    final cached = _epochCache[cacheKey];
    if (cached != null) return cached;
    final raw = await _secureStore.read(
      _key(userId, 'epoch:$conversationId:$epochNumber'),
    );
    if (raw == null) return null;
    try {
      final epoch = E2eeEpoch.fromLocalJson(_jsonMap(raw));
      if (epoch.conversationId != conversationId ||
          epoch.epochNumber != epochNumber) {
        throw const FormatException('Epoch cache context mismatch.');
      }
      _epochCache[cacheKey] = epoch;
      return epoch;
    } catch (error) {
      throw E2eeCryptoException(
        'The local conversation key is invalid.',
        error,
      );
    }
  }

  Future<E2eePublishedEnvelope> sealEpochForRecipient({
    required E2eeEpoch epoch,
    required E2eeEpochRecipient recipient,
  }) async {
    if (recipient.kind != 'device' && recipient.kind != 'recovery') {
      throw const E2eeCryptoException('Invalid E2EE envelope recipient.');
    }
    if (recipient.isDevice &&
        (recipient.deviceId == null || recipient.deviceId!.isEmpty)) {
      throw const E2eeCryptoException(
        'A device envelope requires a device id.',
      );
    }
    final sodium = await _sodium();
    final plaintext = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'protocol_version': protocolVersion,
          'conversation_id': epoch.conversationId,
          'epoch_number': epoch.epochNumber,
          'membership_version': epoch.membershipVersion,
          'key': _encode(epoch.keyBytes),
          'commitment': epoch.commitment,
        }),
      ),
    );
    try {
      final ciphertext = sodium.crypto.box.seal(
        message: plaintext,
        publicKey: _decode(recipient.encryptionPublicKey),
      );
      return E2eePublishedEnvelope(
        recipientKind: recipient.kind,
        recipientUserId: recipient.userId,
        recipientDeviceId: recipient.deviceId,
        ciphertext: _encode(ciphertext),
      );
    } catch (error) {
      throw E2eeCryptoException('Could not seal the conversation key.', error);
    }
  }

  Future<E2eeEpoch> openEpochEnvelope({
    required String userId,
    required E2eeKeyEnvelope envelope,
    required bool useRecoveryKey,
  }) async {
    final sodium = await _sodium();
    await verifyDeviceIdentity(envelope.creator);
    if (!_verifyEpochSignature(envelope, sodium)) {
      throw const E2eeCryptoException(
        'The conversation key epoch signature is invalid.',
      );
    }
    late final String publicKey;
    late final SecureKey privateKey;
    late final void Function() disposeSecrets;
    if (useRecoveryKey) {
      final local = await _requireLocalAccountSecrets(userId, sodium);
      publicKey = local.recoveryPublicKey;
      privateKey = local.recoveryPrivateKey;
      disposeSecrets = local.dispose;
    } else {
      final local = await _requireLocalDeviceSecrets(userId, sodium);
      publicKey = local.encryptionPublicKey;
      privateKey = local.encryptionPrivateKey;
      disposeSecrets = local.dispose;
    }
    try {
      final plaintext = sodium.crypto.box.sealOpen(
        cipherText: _decode(envelope.ciphertext),
        publicKey: _decode(publicKey),
        secretKey: privateKey,
      );
      final payload = _jsonMap(utf8.decode(plaintext));
      if (_asInt(payload['protocol_version']) != protocolVersion ||
          payload['conversation_id']?.toString() != envelope.conversationId ||
          _asInt(payload['epoch_number']) != envelope.epochNumber ||
          _asInt(payload['membership_version']) != envelope.membershipVersion ||
          payload['commitment']?.toString() != envelope.commitment) {
        throw const FormatException('Epoch envelope context mismatch.');
      }
      final keyBytes = _decode(payload['key']?.toString() ?? '');
      final commitment = _encode(
        sodium.crypto.genericHash.call(message: keyBytes, outLen: 32),
      );
      if (!_constantTimeTextEquals(commitment, envelope.commitment)) {
        throw const FormatException('Epoch commitment mismatch.');
      }
      final epoch = E2eeEpoch(
        conversationId: envelope.conversationId,
        epochNumber: envelope.epochNumber,
        membershipVersion: envelope.membershipVersion,
        keyBytes: keyBytes,
        commitment: envelope.commitment,
        signature: envelope.epochSignature,
        serverEpochId: envelope.epochId,
      );
      await rememberEpoch(userId: userId, epoch: epoch);
      return epoch;
    } catch (error) {
      if (error is E2eeCryptoException) rethrow;
      throw E2eeCryptoException(
        'Could not open the conversation key envelope.',
        error,
      );
    } finally {
      disposeSecrets();
    }
  }

  Future<E2eeEncryptedPayload> encryptMessage({
    required String userId,
    required String conversationId,
    required String messageId,
    required E2eeEpoch epoch,
    required String plaintext,
    int revision = 1,
  }) {
    return _encryptPayload(
      userId: userId,
      purpose: 'message',
      conversationId: conversationId,
      itemId: messageId,
      epoch: epoch,
      revision: revision,
      plaintext: Uint8List.fromList(utf8.encode(plaintext)),
      extraAad: const <Object?>[],
    );
  }

  Future<String> decryptMessage({
    required String conversationId,
    required String messageId,
    required E2eeEncryptedPayload envelope,
    required E2eeEpoch epoch,
    required E2eeDeviceIdentity senderDevice,
  }) async {
    final plaintext = await _decryptPayload(
      purpose: 'message',
      conversationId: conversationId,
      itemId: messageId,
      epoch: epoch,
      revision: envelope.revision,
      ciphertext: _decode(envelope.ciphertext),
      nonce: _decode(envelope.nonce),
      signature: _decode(envelope.signature),
      senderDevice: senderDevice,
      extraAad: const <Object?>[],
    );
    try {
      return utf8.decode(plaintext);
    } catch (error) {
      throw E2eeCryptoException(
        'The encrypted message text is invalid.',
        error,
      );
    }
  }

  Future<E2eeEncryptedMedia> encryptMedia({
    required String userId,
    required String conversationId,
    required String messageId,
    required E2eeEpoch epoch,
    required Uint8List bytes,
    required String mediaId,
    required String mimeType,
    required String fileName,
    int revision = 1,
  }) async {
    final result = await _encryptPayload(
      userId: userId,
      purpose: 'media',
      conversationId: conversationId,
      itemId: messageId,
      epoch: epoch,
      revision: revision,
      plaintext: bytes,
      extraAad: <Object?>[mediaId, mimeType, fileName],
    );
    return E2eeEncryptedMedia(
      mediaId: mediaId,
      revision: revision,
      nonce: result.nonce,
      signature: result.signature,
      ciphertextBytes: _decode(result.ciphertext),
    );
  }

  Future<Uint8List> decryptMedia({
    required String conversationId,
    required String messageId,
    required E2eeEncryptedMedia encryptedMedia,
    required E2eeEpoch epoch,
    required E2eeDeviceIdentity senderDevice,
    required String mimeType,
    required String fileName,
  }) async {
    final ciphertext = encryptedMedia.ciphertextBytes;
    if (ciphertext == null) {
      throw const E2eeCryptoException('Encrypted media bytes are unavailable.');
    }
    return _decryptPayload(
      purpose: 'media',
      conversationId: conversationId,
      itemId: messageId,
      epoch: epoch,
      revision: encryptedMedia.revision,
      ciphertext: ciphertext,
      nonce: _decode(encryptedMedia.nonce),
      signature: _decode(encryptedMedia.signature),
      senderDevice: senderDevice,
      extraAad: <Object?>[encryptedMedia.mediaId, mimeType, fileName],
    );
  }

  Future<E2eeEncryptedReaction> encryptReaction({
    required String userId,
    required String conversationId,
    required String messageId,
    required E2eeEpoch epoch,
    required String emoji,
  }) async {
    final tag = await reactionTag(
      messageId: messageId,
      emoji: emoji,
      epoch: epoch,
    );
    final payload = await _encryptPayload(
      userId: userId,
      purpose: 'reaction',
      conversationId: conversationId,
      itemId: messageId,
      epoch: epoch,
      revision: 1,
      plaintext: Uint8List.fromList(utf8.encode(emoji)),
      extraAad: <Object?>[tag],
    );
    return E2eeEncryptedReaction(
      reactionTag: tag,
      ciphertext: payload.ciphertext,
      nonce: payload.nonce,
      signature: payload.signature,
    );
  }

  Future<String> decryptReaction({
    required String conversationId,
    required String messageId,
    required E2eeEncryptedReaction encryptedReaction,
    required E2eeEpoch epoch,
    required E2eeDeviceIdentity senderDevice,
  }) async {
    final plaintext = await _decryptPayload(
      purpose: 'reaction',
      conversationId: conversationId,
      itemId: messageId,
      epoch: epoch,
      revision: 1,
      ciphertext: _decode(encryptedReaction.ciphertext),
      nonce: _decode(encryptedReaction.nonce),
      signature: _decode(encryptedReaction.signature),
      senderDevice: senderDevice,
      extraAad: <Object?>[encryptedReaction.reactionTag],
    );
    try {
      return utf8.decode(plaintext);
    } catch (error) {
      throw E2eeCryptoException('The encrypted reaction is invalid.', error);
    }
  }

  Future<String> reactionTag({
    required String messageId,
    required String emoji,
    required E2eeEpoch epoch,
  }) async {
    final sodium = await _sodium();
    final key = SecureKey.fromList(sodium, epoch.keyBytes);
    try {
      return _encode(
        sodium.crypto.genericHash.call(
          message: _canonical(<Object?>[
            'chat-app.e2ee.reaction-tag/v1',
            messageId,
            emoji,
          ]),
          key: key,
          outLen: 16,
        ),
      );
    } finally {
      key.dispose();
    }
  }

  Future<Uint8List> protectLocalDraft({
    required String userId,
    required String draftId,
    required Uint8List plaintext,
    Uint8List? additionalData,
  }) async {
    final sodium = await _sodium();
    final key = await _draftKey(userId, sodium);
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = sodium.randombytes.buf(aead.nonceBytes);
    try {
      final ciphertext = aead.encrypt(
        message: plaintext,
        nonce: nonce,
        key: key,
        additionalData: additionalData ?? _canonical(<Object?>[draftId]),
      );
      return Uint8List.fromList(<int>[
        protocolVersion,
        ...nonce,
        ...ciphertext,
      ]);
    } catch (error) {
      throw E2eeCryptoException('Could not protect the local draft.', error);
    } finally {
      key.dispose();
    }
  }

  Future<Uint8List> unprotectLocalDraft({
    required String userId,
    required String draftId,
    required Uint8List protectedDraft,
    Uint8List? additionalData,
  }) async {
    final sodium = await _sodium();
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    if (protectedDraft.length <= 1 + aead.nonceBytes ||
        protectedDraft.first != protocolVersion) {
      throw const E2eeCryptoException(
        'The local draft encryption format is invalid.',
      );
    }
    final key = await _draftKey(userId, sodium);
    try {
      final nonce = Uint8List.sublistView(
        protectedDraft,
        1,
        1 + aead.nonceBytes,
      );
      final ciphertext = Uint8List.sublistView(
        protectedDraft,
        1 + aead.nonceBytes,
      );
      return aead.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: key,
        additionalData: additionalData ?? _canonical(<Object?>[draftId]),
      );
    } catch (error) {
      throw E2eeCryptoException(
        'This encrypted local draft cannot be opened.',
        error,
      );
    } finally {
      key.dispose();
    }
  }

  /// Clears process-memory keys/caches on sign out. It intentionally retains
  /// OS-secure key material so the same device can open its messages again.
  Future<void> disposeForUser(String userId) async {
    _epochCache.removeWhere((key, _) => key.startsWith('$userId|'));
    _remoteAccounts.remove(userId);
  }

  Future<void> verifyDeviceIdentity(E2eeDeviceIdentity device) async {
    final sodium = await _sodium();
    try {
      final valid = sodium.crypto.sign.verifyDetached(
        message: _deviceCertificateBytes(
          userId: device.userId,
          deviceId: device.deviceId,
          encryptionPublicKey: device.encryptionPublicKey,
          signingPublicKey: device.signingPublicKey,
        ),
        signature: _decode(device.certificate),
        publicKey: _decode(device.accountSigningPublicKey),
      );
      if (!valid) {
        throw const E2eeCryptoException(
          'The device identity certificate is invalid.',
        );
      }
    } catch (error) {
      if (error is E2eeCryptoException) rethrow;
      throw E2eeCryptoException('The device identity is invalid.', error);
    }
  }

  Future<E2eeEncryptedPayload> _encryptPayload({
    required String userId,
    required String purpose,
    required String conversationId,
    required String itemId,
    required E2eeEpoch epoch,
    required int revision,
    required Uint8List plaintext,
    required List<Object?> extraAad,
  }) async {
    if (revision < 1) {
      throw const E2eeCryptoException('Invalid encrypted message revision.');
    }
    final sodium = await _sodium();
    final device = await _requireLocalDeviceSecrets(userId, sodium);
    final key = SecureKey.fromList(sodium, epoch.keyBytes);
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final aad = _payloadAad(
      purpose: purpose,
      conversationId: conversationId,
      itemId: itemId,
      epoch: epoch,
      revision: revision,
      extra: extraAad,
    );
    final nonce = sodium.randombytes.buf(aead.nonceBytes);
    try {
      final ciphertext = aead.encrypt(
        message: plaintext,
        nonce: nonce,
        key: key,
        additionalData: aad,
      );
      final signature = sodium.crypto.sign.detached(
        message: _signatureInput(
          purpose: purpose,
          aad: aad,
          nonce: nonce,
          ciphertext: ciphertext,
        ),
        secretKey: device.signingPrivateKey,
      );
      return E2eeEncryptedPayload(
        ciphertext: _encode(ciphertext),
        nonce: _encode(nonce),
        signature: _encode(signature),
        revision: revision,
      );
    } catch (error) {
      throw E2eeCryptoException(
        'Could not encrypt the $purpose payload.',
        error,
      );
    } finally {
      key.dispose();
      device.dispose();
    }
  }

  Future<Uint8List> _decryptPayload({
    required String purpose,
    required String conversationId,
    required String itemId,
    required E2eeEpoch epoch,
    required int revision,
    required Uint8List ciphertext,
    required Uint8List nonce,
    required Uint8List signature,
    required E2eeDeviceIdentity senderDevice,
    required List<Object?> extraAad,
  }) async {
    final sodium = await _sodium();
    await verifyDeviceIdentity(senderDevice);
    final aad = _payloadAad(
      purpose: purpose,
      conversationId: conversationId,
      itemId: itemId,
      epoch: epoch,
      revision: revision,
      extra: extraAad,
    );
    final input = _signatureInput(
      purpose: purpose,
      aad: aad,
      nonce: nonce,
      ciphertext: ciphertext,
    );
    try {
      final valid = sodium.crypto.sign.verifyDetached(
        message: input,
        signature: signature,
        publicKey: _decode(senderDevice.signingPublicKey),
      );
      if (!valid) {
        throw E2eeCryptoException(
          'The encrypted $purpose signature is invalid.',
        );
      }
      final key = SecureKey.fromList(sodium, epoch.keyBytes);
      try {
        return sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: ciphertext,
          nonce: nonce,
          key: key,
          additionalData: aad,
        );
      } finally {
        key.dispose();
      }
    } catch (error) {
      if (error is E2eeCryptoException) rethrow;
      throw E2eeCryptoException(
        'Could not verify or decrypt the $purpose.',
        error,
      );
    }
  }

  Future<E2eeReadyState> _createInitialIdentity(
    String userId,
    Sodium sodium,
  ) async {
    final mnemonic = Mnemonic.generate(
      Language.english,
      length: MnemonicLength.words24,
    );
    final phrase = _normalizePhrase(mnemonic.sentence);
    final derived = _deriveAccountFromPhrase(userId, phrase, sodium);
    try {
      await _storeAccount(userId, derived);
      await _secureStore.write(
        key: _key(userId, 'pending-recovery-phrase'),
        value: phrase,
      );
      await _secureStore.delete(_key(userId, 'recovery-confirmed'));
      final device = await _createAndStoreDevice(
        sodium: sodium,
        account: derived.account,
      );
      return E2eeReadyState(
        account: derived.account,
        device: device,
        requiresRecoveryPhraseConfirmation: true,
      );
    } finally {
      derived.dispose();
    }
  }

  _DerivedAccount _deriveAccountFromPhrase(
    String userId,
    String phrase,
    Sodium sodium,
  ) {
    try {
      final mnemonic = Mnemonic.fromSentence(
        _normalizePhrase(phrase),
        Language.english,
      );
      final seed = Uint8List.fromList(mnemonic.seed);
      final recoverySeed = _deriveSeed(
        seed,
        'chat-app.e2ee.recovery-x25519/v1',
      );
      final signingSeed = _deriveSeed(seed, 'chat-app.e2ee.account-ed25519/v1');
      final recoverySeedKey = SecureKey.fromList(sodium, recoverySeed);
      final signingSeedKey = SecureKey.fromList(sodium, signingSeed);
      final recoveryPair = sodium.crypto.box.seedKeyPair(recoverySeedKey);
      final signingPair = sodium.crypto.sign.seedKeyPair(signingSeedKey);
      try {
        final account = E2eeAccount(
          userId: userId,
          recoveryPublicKey: _encode(recoveryPair.publicKey),
          signingPublicKey: _encode(signingPair.publicKey),
        );
        return _DerivedAccount(
          account: account,
          recoveryPrivateBytes: recoveryPair.secretKey.extractBytes(),
          signingPrivateBytes: signingPair.secretKey.extractBytes(),
        );
      } finally {
        recoveryPair.dispose();
        signingPair.dispose();
        recoverySeedKey.dispose();
        signingSeedKey.dispose();
        seed.fillRange(0, seed.length, 0);
        recoverySeed.fillRange(0, recoverySeed.length, 0);
        signingSeed.fillRange(0, signingSeed.length, 0);
      }
    } catch (error) {
      if (error is E2eeCryptoException) rethrow;
      throw E2eeCryptoException(
        'The recovery phrase is not a valid 24-word phrase.',
        error,
      );
    }
  }

  Future<void> _storeAccount(String userId, _DerivedAccount account) async {
    await _secureStore.write(
      key: _key(userId, 'account'),
      value: jsonEncode(account.account.toJson()),
    );
    await _secureStore.write(
      key: _key(userId, 'recovery-private'),
      value: _encode(account.recoveryPrivateBytes),
    );
    await _secureStore.write(
      key: _key(userId, 'account-signing-private'),
      value: _encode(account.signingPrivateBytes),
    );
  }

  Future<E2eeAccount?> _readLocalAccount(String userId) async {
    final raw = await _secureStore.read(_key(userId, 'account'));
    if (raw == null) return null;
    try {
      final account = E2eeAccount.fromJson(_jsonMap(raw));
      final recovery = await _secureStore.read(
        _key(userId, 'recovery-private'),
      );
      final signing = await _secureStore.read(
        _key(userId, 'account-signing-private'),
      );
      if (account.userId != userId || recovery == null || signing == null) {
        throw const FormatException('Incomplete account identity.');
      }
      return account;
    } catch (error) {
      throw E2eeCryptoException(
        'The local E2EE account identity is invalid.',
        error,
      );
    }
  }

  Future<E2eeDevice?> _readLocalDevice(String userId) async {
    final raw = await _secureStore.read(_key(userId, 'device'));
    if (raw == null) return null;
    try {
      final device = E2eeDevice.fromJson(_jsonMap(raw));
      final encryption = await _secureStore.read(
        _key(userId, 'device-encryption-private'),
      );
      final signing = await _secureStore.read(
        _key(userId, 'device-signing-private'),
      );
      if (device.userId != userId ||
          device.id.isEmpty ||
          encryption == null ||
          signing == null) {
        throw const FormatException('Incomplete device identity.');
      }
      return device;
    } catch (error) {
      throw E2eeCryptoException(
        'The local E2EE device identity is invalid.',
        error,
      );
    }
  }

  Future<E2eeDevice> _createAndStoreDevice({
    required Sodium sodium,
    required E2eeAccount account,
  }) async {
    final accountSecrets = await _requireLocalAccountSecrets(
      account.userId,
      sodium,
    );
    final encryptionPair = sodium.crypto.box.keyPair();
    final signingPair = sodium.crypto.sign.keyPair();
    try {
      final id = _uuid.v4();
      final encryptionPublicKey = _encode(encryptionPair.publicKey);
      final signingPublicKey = _encode(signingPair.publicKey);
      final certificate = sodium.crypto.sign.detached(
        message: _deviceCertificateBytes(
          userId: account.userId,
          deviceId: id,
          encryptionPublicKey: encryptionPublicKey,
          signingPublicKey: signingPublicKey,
        ),
        secretKey: accountSecrets.signingPrivateKey,
      );
      final device = E2eeDevice(
        id: id,
        userId: account.userId,
        encryptionPublicKey: encryptionPublicKey,
        signingPublicKey: signingPublicKey,
        certificate: _encode(certificate),
      );
      await _secureStore.write(
        key: _key(account.userId, 'device'),
        value: jsonEncode(device.toJson()),
      );
      await _secureStore.write(
        key: _key(account.userId, 'device-encryption-private'),
        value: _encode(encryptionPair.secretKey.extractBytes()),
      );
      await _secureStore.write(
        key: _key(account.userId, 'device-signing-private'),
        value: _encode(signingPair.secretKey.extractBytes()),
      );
      return device;
    } finally {
      accountSecrets.dispose();
      encryptionPair.dispose();
      signingPair.dispose();
    }
  }

  Future<_LocalAccountSecrets> _requireLocalAccountSecrets(
    String userId,
    Sodium sodium,
  ) async {
    final account = await _readLocalAccount(userId);
    final recoveryPrivate = await _secureStore.read(
      _key(userId, 'recovery-private'),
    );
    final signingPrivate = await _secureStore.read(
      _key(userId, 'account-signing-private'),
    );
    if (account == null || recoveryPrivate == null || signingPrivate == null) {
      throw const E2eeCryptoException(
        'Restore the recovery phrase on this device first.',
      );
    }
    return _LocalAccountSecrets(
      account: account,
      recoveryPrivateKey: SecureKey.fromList(sodium, _decode(recoveryPrivate)),
      signingPrivateKey: SecureKey.fromList(sodium, _decode(signingPrivate)),
    );
  }

  Future<_LocalDeviceSecrets> _requireLocalDeviceSecrets(
    String userId,
    Sodium sodium,
  ) async {
    final device = await _readLocalDevice(userId);
    final encryptionPrivate = await _secureStore.read(
      _key(userId, 'device-encryption-private'),
    );
    final signingPrivate = await _secureStore.read(
      _key(userId, 'device-signing-private'),
    );
    if (device == null || encryptionPrivate == null || signingPrivate == null) {
      throw const E2eeCryptoException(
        'This device does not have an E2EE identity.',
      );
    }
    return _LocalDeviceSecrets(
      device: device,
      encryptionPrivateKey: SecureKey.fromList(
        sodium,
        _decode(encryptionPrivate),
      ),
      signingPrivateKey: SecureKey.fromList(sodium, _decode(signingPrivate)),
    );
  }

  Future<SecureKey> _draftKey(String userId, Sodium sodium) async {
    final keyName = _key(userId, 'draft-key');
    final raw = await _secureStore.read(keyName);
    if (raw != null) {
      return SecureKey.fromList(sodium, _decode(raw));
    }
    final key = sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
    try {
      await _secureStore.write(
        key: keyName,
        value: _encode(key.extractBytes()),
      );
      return key.copy();
    } finally {
      key.dispose();
    }
  }

  Future<E2eeAccount?> _readRemoteAccount(
    SupabaseClient? client,
    String userId,
  ) async {
    if (client == null) return null;
    final row = await client
        .from('e2ee_accounts')
        .select(
          'user_id, recovery_public_key, signing_public_key, protocol_version',
        )
        .eq('user_id', userId)
        .maybeSingle();
    return row == null ? null : E2eeAccount.fromJson(row);
  }

  bool _verifyEpochSignature(E2eeKeyEnvelope envelope, Sodium sodium) {
    return sodium.crypto.sign.verifyDetached(
      message: _epochSigningBytes(
        conversationId: envelope.conversationId,
        epochNumber: envelope.epochNumber,
        membershipVersion: envelope.membershipVersion,
        commitment: envelope.commitment,
      ),
      signature: _decode(envelope.epochSignature),
      publicKey: _decode(envelope.creator.signingPublicKey),
    );
  }

  Uint8List _payloadAad({
    required String purpose,
    required String conversationId,
    required String itemId,
    required E2eeEpoch epoch,
    required int revision,
    required List<Object?> extra,
  }) {
    return _canonical(<Object?>[
      'chat-app.e2ee.aad/v1',
      purpose,
      conversationId,
      itemId,
      epoch.epochNumber,
      epoch.membershipVersion,
      revision,
      ...extra,
    ]);
  }

  Uint8List _signatureInput({
    required String purpose,
    required Uint8List aad,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) {
    return _canonical(<Object?>[
      'chat-app.e2ee.signature/v1',
      purpose,
      _encode(aad),
      _encode(nonce),
      _encode(ciphertext),
    ]);
  }

  Uint8List _epochSigningBytes({
    required String conversationId,
    required int epochNumber,
    required int membershipVersion,
    required String commitment,
  }) {
    return _canonical(<Object?>[
      'chat-app.e2ee.epoch/v1',
      conversationId,
      epochNumber,
      membershipVersion,
      commitment,
    ]);
  }

  Uint8List _deviceCertificateBytes({
    required String userId,
    required String deviceId,
    required String encryptionPublicKey,
    required String signingPublicKey,
  }) {
    return _canonical(<Object?>[
      'chat-app.e2ee.device-certificate/v1',
      userId,
      deviceId,
      encryptionPublicKey,
      signingPublicKey,
    ]);
  }

  Future<Sodium> _sodium() => _sodiumFuture ??= _sodiumLoader();

  String _key(String userId, String suffix) => '$_namespace:$userId:$suffix';

  String _epochCacheKey(
    String userId,
    String conversationId,
    int epochNumber,
  ) => '$userId|$conversationId|$epochNumber';
}

class CryptoServiceDraftProtector implements E2eeDraftProtector {
  CryptoServiceDraftProtector({E2eeCryptoService? crypto})
    : _crypto = crypto ?? E2eeCryptoService.instance;

  final E2eeCryptoService _crypto;

  @override
  Future<Uint8List> protectDraft({
    required E2eeDraftProtectionContext context,
    required Uint8List plaintext,
  }) {
    return _crypto.protectLocalDraft(
      userId: context.userId,
      draftId: context.draftId,
      plaintext: plaintext,
      additionalData: context.additionalData,
    );
  }

  @override
  Future<Uint8List> unprotectDraft({
    required E2eeDraftProtectionContext context,
    required Uint8List protectedDraft,
  }) {
    return _crypto.unprotectLocalDraft(
      userId: context.userId,
      draftId: context.draftId,
      protectedDraft: protectedDraft,
      additionalData: context.additionalData,
    );
  }
}

class _DerivedAccount {
  _DerivedAccount({
    required this.account,
    required this.recoveryPrivateBytes,
    required this.signingPrivateBytes,
  });

  final E2eeAccount account;
  final Uint8List recoveryPrivateBytes;
  final Uint8List signingPrivateBytes;

  void dispose() {
    recoveryPrivateBytes.fillRange(0, recoveryPrivateBytes.length, 0);
    signingPrivateBytes.fillRange(0, signingPrivateBytes.length, 0);
  }
}

class _LocalAccountSecrets {
  _LocalAccountSecrets({
    required this.account,
    required this.recoveryPrivateKey,
    required this.signingPrivateKey,
  });

  final E2eeAccount account;
  final SecureKey recoveryPrivateKey;
  final SecureKey signingPrivateKey;

  String get recoveryPublicKey => account.recoveryPublicKey;

  void dispose() {
    recoveryPrivateKey.dispose();
    signingPrivateKey.dispose();
  }
}

class _LocalDeviceSecrets {
  _LocalDeviceSecrets({
    required this.device,
    required this.encryptionPrivateKey,
    required this.signingPrivateKey,
  });

  final E2eeDevice device;
  final SecureKey encryptionPrivateKey;
  final SecureKey signingPrivateKey;

  String get encryptionPublicKey => device.encryptionPublicKey;

  void dispose() {
    encryptionPrivateKey.dispose();
    signingPrivateKey.dispose();
  }
}

Uint8List _canonical(List<Object?> values) =>
    Uint8List.fromList(utf8.encode(jsonEncode(values)));

Uint8List _deriveSeed(Uint8List seed, String label) {
  final result = crypto.Hmac(crypto.sha256, seed).convert(utf8.encode(label));
  return Uint8List.fromList(result.bytes);
}

String _encode(Uint8List value) => base64UrlEncode(value).replaceAll('=', '');

Uint8List _decode(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.contains(RegExp(r'\s'))) {
    throw const FormatException('Missing base64url data.');
  }
  final padding = (4 - normalized.length % 4) % 4;
  return Uint8List.fromList(base64Url.decode('$normalized${'=' * padding}'));
}

Map<String, dynamic> _jsonMap(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('Expected an object.');
  }
  return Map<String, dynamic>.from(decoded);
}

int? _asInt(Object? value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}

String? _nullableText(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

void _requireId(String value, String label) {
  if (value.trim().isEmpty) {
    throw E2eeCryptoException('A valid $label id is required.');
  }
}

String _normalizePhrase(String value) =>
    value.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

String _fingerprint(String publicKey) {
  final bytes = crypto.sha256.convert(utf8.encode(publicKey)).bytes;
  final groups = <String>[];
  for (var index = 0; index < 30; index += 5) {
    groups.add(
      bytes
          .sublist(index, index + 5)
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join(),
    );
  }
  return groups.join(' ');
}

bool _constantTimeTextEquals(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  var different = leftBytes.length ^ rightBytes.length;
  final length = leftBytes.length > rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < length; index += 1) {
    final a = index < leftBytes.length ? leftBytes[index] : 0;
    final b = index < rightBytes.length ? rightBytes[index] : 0;
    different |= a ^ b;
  }
  return different == 0;
}
