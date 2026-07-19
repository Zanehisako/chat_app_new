import 'dart:typed_data';

import 'package:chat_app/src/e2ee_crypto_service.dart';
import 'package:chat_app/src/e2ee_draft_protector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';

const _userId = 'user-a';
const _conversationId = 'conversation-a';

void main() {
  late Sodium sodium;

  setUpAll(() async {
    sodium = await SodiumInit.init();
  });

  test(
    'requires exact 24-word recovery phrase confirmation before sending',
    () async {
      final fixture = await _newFixture(sodium);

      expect(fixture.initial.requiresRecoveryPhraseConfirmation, isTrue);
      expect(fixture.initial.isReadyForSending, isFalse);
      final phrase = await fixture.service.getRecoveryPhrase(_userId);
      expect(phrase, isNotNull);
      expect(phrase!.split(' '), hasLength(24));

      await expectLater(
        fixture.service.confirmRecoveryPhrase(
          userId: _userId,
          phrase: '$phrase extra',
        ),
        throwsA(isA<E2eeCryptoException>()),
      );

      await fixture.service.confirmRecoveryPhrase(
        userId: _userId,
        phrase: phrase,
      );
      final ready = await fixture.service.ensureReady(userId: _userId);

      expect(ready.isReadyForSending, isTrue);
      expect(await fixture.service.getRecoveryPhrase(_userId), isNull);
    },
  );

  test('seals and opens a signed epoch envelope for a local device', () async {
    final fixture = await _readyFixture(sodium);
    final epoch = await fixture.service.createEpoch(
      userId: _userId,
      conversationId: _conversationId,
      epochNumber: 1,
      membershipVersion: 4,
      serverEpochId: 'epoch-1',
    );
    final recipient = E2eeEpochRecipient(
      kind: 'device',
      userId: _userId,
      deviceId: fixture.device.id,
      encryptionPublicKey: fixture.device.encryptionPublicKey,
    );
    final sealed = await fixture.service.sealEpochForRecipient(
      epoch: epoch,
      recipient: recipient,
    );
    final envelope = E2eeKeyEnvelope(
      conversationId: _conversationId,
      epochId: 'epoch-1',
      epochNumber: epoch.epochNumber,
      membershipVersion: epoch.membershipVersion,
      commitment: epoch.commitment,
      epochSignature: epoch.signature,
      createdByUserId: _userId,
      createdByDeviceId: fixture.device.id,
      ciphertext: sealed.ciphertext,
      creator: fixture.deviceIdentity,
    );

    final opened = await fixture.service.openEpochEnvelope(
      userId: _userId,
      envelope: envelope,
      useRecoveryKey: false,
    );

    expect(opened.keyBytes, orderedEquals(epoch.keyBytes));
    expect(opened.commitment, epoch.commitment);
    expect(opened.serverEpochId, 'epoch-1');
    final cached = await fixture.service.cachedEpoch(
      userId: _userId,
      conversationId: _conversationId,
      epochNumber: 1,
    );
    expect(cached?.keyBytes, orderedEquals(epoch.keyBytes));
  });

  test(
    'encrypts payloads, media, and reactions and rejects tampering',
    () async {
      final fixture = await _readyFixture(sodium);
      final epoch = await fixture.service.createEpoch(
        userId: _userId,
        conversationId: _conversationId,
        epochNumber: 2,
        membershipVersion: 5,
      );

      final message = await fixture.service.encryptMessage(
        userId: _userId,
        conversationId: _conversationId,
        messageId: 'message-a',
        epoch: epoch,
        plaintext: 'private message',
      );
      expect(message.ciphertext, isNot(contains('private message')));
      expect(
        await fixture.service.decryptMessage(
          conversationId: _conversationId,
          messageId: 'message-a',
          envelope: message,
          epoch: epoch,
          senderDevice: fixture.deviceIdentity,
        ),
        'private message',
      );
      await expectLater(
        fixture.service.decryptMessage(
          conversationId: _conversationId,
          messageId: 'message-a',
          envelope: E2eeEncryptedPayload(
            ciphertext: _tamperBase64Url(message.ciphertext),
            nonce: message.nonce,
            signature: message.signature,
            revision: message.revision,
          ),
          epoch: epoch,
          senderDevice: fixture.deviceIdentity,
        ),
        throwsA(isA<E2eeCryptoException>()),
      );

      final media = await fixture.service.encryptMedia(
        userId: _userId,
        conversationId: _conversationId,
        messageId: 'message-a',
        epoch: epoch,
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
        mediaId: 'media-a',
        mimeType: 'image/jpeg',
        fileName: 'private.jpg',
      );
      expect(
        await fixture.service.decryptMedia(
          conversationId: _conversationId,
          messageId: 'message-a',
          encryptedMedia: media,
          epoch: epoch,
          senderDevice: fixture.deviceIdentity,
          mimeType: 'image/jpeg',
          fileName: 'private.jpg',
        ),
        orderedEquals(<int>[1, 2, 3, 4, 5]),
      );
      final tamperedMediaBytes = media.ciphertextBytes!;
      tamperedMediaBytes[0] ^= 1;
      await expectLater(
        fixture.service.decryptMedia(
          conversationId: _conversationId,
          messageId: 'message-a',
          encryptedMedia: media.withCiphertextBytes(tamperedMediaBytes),
          epoch: epoch,
          senderDevice: fixture.deviceIdentity,
          mimeType: 'image/jpeg',
          fileName: 'private.jpg',
        ),
        throwsA(isA<E2eeCryptoException>()),
      );

      final reaction = await fixture.service.encryptReaction(
        userId: _userId,
        conversationId: _conversationId,
        messageId: 'message-a',
        epoch: epoch,
        emoji: '👍',
      );
      expect(
        await fixture.service.decryptReaction(
          conversationId: _conversationId,
          messageId: 'message-a',
          encryptedReaction: reaction,
          epoch: epoch,
          senderDevice: fixture.deviceIdentity,
        ),
        '👍',
      );
      await expectLater(
        fixture.service.decryptReaction(
          conversationId: _conversationId,
          messageId: 'message-a',
          encryptedReaction: E2eeEncryptedReaction(
            reactionTag: reaction.reactionTag,
            ciphertext: _tamperBase64Url(reaction.ciphertext),
            nonce: reaction.nonce,
            signature: reaction.signature,
          ),
          epoch: epoch,
          senderDevice: fixture.deviceIdentity,
        ),
        throwsA(isA<E2eeCryptoException>()),
      );
    },
  );

  test('a verified account identity change blocks sending', () async {
    final fixture = await _newFixture(sodium);

    await fixture.service.observeAccountIdentity(
      userId: 'peer-a',
      signingPublicKey: 'initial-root-key',
    );
    await fixture.service.markAccountIdentityVerified(
      userId: 'peer-a',
      signingPublicKey: 'initial-root-key',
    );
    final changed = await fixture.service.observeAccountIdentity(
      userId: 'peer-a',
      signingPublicKey: 'replacement-root-key',
    );

    expect(changed.isVerified, isTrue);
    expect(changed.hasChanged, isTrue);
    expect(changed.isSendBlocked, isTrue);
  });

  test('protects local drafts with their complete outbox context', () async {
    final fixture = await _readyFixture(sodium);
    final protector = CryptoServiceDraftProtector(crypto: fixture.service);
    const context = E2eeDraftProtectionContext(
      backendOrigin: 'https://example.supabase.co',
      userId: _userId,
      conversationId: _conversationId,
      draftId: 'draft-a',
    );
    final plaintext = Uint8List.fromList('private queued draft'.codeUnits);

    final protected = await protector.protectDraft(
      context: context,
      plaintext: plaintext,
    );
    expect(protected, isNot(orderedEquals(plaintext)));
    expect(
      await protector.unprotectDraft(
        context: context,
        protectedDraft: protected,
      ),
      orderedEquals(plaintext),
    );

    await expectLater(
      protector.unprotectDraft(
        context: const E2eeDraftProtectionContext(
          backendOrigin: 'https://example.supabase.co',
          userId: _userId,
          conversationId: 'other-conversation',
          draftId: 'draft-a',
        ),
        protectedDraft: protected,
      ),
      throwsA(isA<E2eeCryptoException>()),
    );
  });
}

Future<_Fixture> _newFixture(Sodium sodium) async {
  final service = E2eeCryptoService(
    secureStore: InMemoryE2eeSecureStore(),
    sodiumLoader: () async => sodium,
  );
  final initial = await service.ensureReady(userId: _userId);
  return _Fixture(service: service, initial: initial);
}

Future<_Fixture> _readyFixture(Sodium sodium) async {
  final fixture = await _newFixture(sodium);
  final phrase = await fixture.service.getRecoveryPhrase(_userId);
  await fixture.service.confirmRecoveryPhrase(userId: _userId, phrase: phrase!);
  final ready = await fixture.service.ensureReady(userId: _userId);
  return _Fixture(service: fixture.service, initial: ready);
}

String _tamperBase64Url(String encoded) {
  final replacement = encoded.startsWith('A') ? 'B' : 'A';
  return '$replacement${encoded.substring(1)}';
}

class _Fixture {
  const _Fixture({required this.service, required this.initial});

  final E2eeCryptoService service;
  final E2eeReadyState initial;

  E2eeAccount get account => initial.account!;

  E2eeDevice get device => initial.device!;

  E2eeDeviceIdentity get deviceIdentity => E2eeDeviceIdentity(
    deviceId: device.id,
    userId: device.userId,
    encryptionPublicKey: device.encryptionPublicKey,
    signingPublicKey: device.signingPublicKey,
    certificate: device.certificate,
    accountSigningPublicKey: account.signingPublicKey,
  );
}
