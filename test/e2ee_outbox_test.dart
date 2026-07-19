import 'dart:async';
import 'dart:io';

import 'package:chat_app/src/chat_models.dart';
import 'package:chat_app/src/e2ee_draft_protector.dart';
import 'package:chat_app/src/offline_outbox_service.dart';
import 'package:chat_app/src/outbox_database.dart';
import 'package:chat_app/src/outbox_message_sender.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'authenticated drafts are encrypted at rest and restore after reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = OutboxDatabase.forTesting(NativeDatabase.memory());
      const scope = OutboxScope(
        backendOrigin: 'https://example.supabase.co',
        userId: 'account-a',
      );
      final protector = _TestDraftProtector();
      final outbox = OfflineOutboxService(
        database: database,
        scope: scope,
        draftProtector: protector,
      );

      final queued = await outbox.enqueue(
        conversationId: 'conversation-a',
        senderId: 'account-a',
        senderName: 'Amina',
        body: 'top secret caption',
        pickedMedia: PickedChatMedia(
          bytes: Uint8List.fromList([1, 2, 3, 4]),
          originalName: 'secret-photo.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 4,
          waveform: const [0.1, 0.9],
        ),
        replyTo: const MessageReplyPreview(
          messageId: 'reply-source',
          senderName: 'Mina',
          preview: 'private reply preview',
          messageType: ChatMessageType.text,
        ),
        isForwarded: true,
      );

      final row = (await database.select(database.outboxEntries).getSingle());
      expect(row.id, queued.id);
      expect(row.draftEncryptionState, 'protected');
      expect(row.draftEncryptionVersion, 1);
      expect(row.encryptedDraft, isNotNull);
      expect(row.body, isEmpty);
      expect(row.mediaMimeType, isNull);
      expect(row.mediaOriginalName, isNull);
      expect(row.localMediaBytes, isNull);
      expect(row.replyPreview, isNull);
      expect(
        String.fromCharCodes(row.encryptedDraft!),
        isNot(contains('top secret caption')),
      );
      expect(
        String.fromCharCodes(row.encryptedDraft!),
        isNot(contains('secret-photo.jpg')),
      );

      final local = (await outbox.localMessages()).single;
      expect(local.body, 'top secret caption');
      expect(local.encryptionState, ChatMessageEncryptionState.encrypted);
      expect(local.media?.localBytes, Uint8List.fromList([1, 2, 3, 4]));
      expect(local.replyTo?.preview, 'private reply preview');
      expect(local.isForwarded, isTrue);

      final reloaded = OfflineOutboxService(
        database: database,
        scope: scope,
        draftProtector: protector,
      );
      await reloaded.initialize();
      final restored = (await reloaded.localMessages()).single;
      expect(restored.id, queued.id);
      expect(restored.body, 'top secret caption');
      expect(restored.media?.localBytes, Uint8List.fromList([1, 2, 3, 4]));
      expect(restored.replyTo?.messageId, 'reply-source');
      expect(restored.isForwarded, isTrue);

      await outbox.dispose();
      await reloaded.dispose();
      await database.close();
    },
  );

  test(
    'authenticated scopes refuse to persist drafts without a protector',
    () async {
      final database = OutboxDatabase.forTesting(NativeDatabase.memory());
      const scope = OutboxScope(
        backendOrigin: 'https://example.supabase.co',
        userId: 'account-a',
      );
      final outbox = OfflineOutboxService(database: database, scope: scope);

      await expectLater(
        outbox.enqueue(
          conversationId: 'conversation-a',
          senderId: 'account-a',
          senderName: 'Amina',
          body: 'must not reach disk',
        ),
        throwsA(isA<StateError>()),
      );
      expect(await database.select(database.outboxEntries).get(), isEmpty);

      await outbox.dispose();
      await database.close();
    },
  );

  test(
    'v3 authenticated rows are protected and plaintext columns are cleared',
    () async {
      final fixture = await _createV3Fixture();
      final database = OutboxDatabase.forTesting(NativeDatabase(fixture.file));
      const scope = OutboxScope(
        backendOrigin: 'https://example.supabase.co',
        userId: 'account-a',
      );
      final outbox = OfflineOutboxService(
        database: database,
        scope: scope,
        draftProtector: _TestDraftProtector(),
      );

      await outbox.initialize();

      final row = (await database.select(database.outboxEntries).getSingle());
      expect(row.draftEncryptionState, 'protected');
      expect(row.encryptedDraft, isNotNull);
      expect(row.body, isEmpty);
      expect(row.mediaMimeType, isNull);
      expect(row.localMediaBytes, isNull);
      final local = (await outbox.localMessages()).single;
      expect(local.body, 'v3 private message');
      expect(local.media?.localBytes, Uint8List.fromList([7, 8, 9]));

      await outbox.dispose();
      await database.close();
      await fixture.dispose();
    },
  );

  test(
    'v3 authenticated rows without keys are wiped and require discard',
    () async {
      final fixture = await _createV3Fixture();
      final database = OutboxDatabase.forTesting(NativeDatabase(fixture.file));
      const scope = OutboxScope(
        backendOrigin: 'https://example.supabase.co',
        userId: 'account-a',
      );
      final outbox = OfflineOutboxService(database: database, scope: scope);

      await outbox.initialize();

      final row = (await database.select(database.outboxEntries).getSingle());
      expect(row.draftEncryptionState, 'discard-required');
      expect(row.body, isEmpty);
      expect(row.mediaMimeType, isNull);
      expect(row.localMediaBytes, isNull);
      expect(
        outbox.items.single.encryptionState,
        OutboxDraftEncryptionState.discardRequired,
      );
      await expectLater(
        outbox.retryNow('legacy-draft'),
        throwsA(isA<StateError>()),
      );
      await outbox.discard('legacy-draft');
      expect(await database.select(database.outboxEntries).get(), isEmpty);

      await outbox.dispose();
      await database.close();
      await fixture.dispose();
    },
  );

  test('queued encrypted media preserves its decryption context', () {
    final queued = QueuedOutboxMedia.fromUploaded(
      UploadedChatMedia(
        messageId: 'message-a',
        media: ChatMedia(
          bucket: 'chat-media',
          path: 'opaque-object',
          mimeType: 'application/octet-stream',
          sizeBytes: 9,
          isEncrypted: true,
          conversationId: 'conversation-a',
          messageId: 'message-a',
          encryptionEpoch: 4,
          encryptionEpochId: 'epoch-4',
          encryptionMetadata: const {'nonce': 'base64-nonce'},
        ),
      ),
    );

    final restored = queued.toChatMedia();
    expect(restored.isEncrypted, isTrue);
    expect(restored.conversationId, 'conversation-a');
    expect(restored.messageId, 'message-a');
    expect(restored.encryptionEpoch, 4);
    expect(restored.encryptionEpochId, 'epoch-4');
    expect(restored.encryptionMetadata, {'nonce': 'base64-nonce'});
  });

  test('non-retryable E2EE failures stop syncing after one attempt', () async {
    SharedPreferences.setMockInitialValues({});
    final database = OutboxDatabase.forTesting(NativeDatabase.memory());
    final outbox = OfflineOutboxService(
      database: database,
      timerFactory: (duration, callback) => _NoopTimer(),
    );
    await outbox.enqueue(
      conversationId: 'conversation-a',
      senderId: ChatSeed.localUserId,
      senderName: 'You',
      body: 'encrypted message',
    );

    await outbox.flush(_MissingRecipientDeviceSender());

    expect(outbox.items.single.status, OutboxSendStatus.failed);
    expect(outbox.items.single.attemptCount, 1);
    expect(outbox.items.single.lastError, contains('encryption device'));
    await outbox.dispose();
    await database.close();
  });
}

class _TestDraftProtector implements E2eeDraftProtector {
  @override
  Future<Uint8List> protectDraft({
    required E2eeDraftProtectionContext context,
    required Uint8List plaintext,
  }) async {
    final seed = _seedFor(context);
    return Uint8List.fromList([
      seed,
      for (final byte in plaintext) byte ^ seed ^ 0xA5,
    ]);
  }

  @override
  Future<Uint8List> unprotectDraft({
    required E2eeDraftProtectionContext context,
    required Uint8List protectedDraft,
  }) async {
    if (protectedDraft.isEmpty || protectedDraft.first != _seedFor(context)) {
      throw const FormatException('Draft context did not match.');
    }
    final seed = protectedDraft.first;
    return Uint8List.fromList([
      for (final byte in protectedDraft.skip(1)) byte ^ seed ^ 0xA5,
    ]);
  }

  int _seedFor(E2eeDraftProtectionContext context) {
    return context.additionalData.fold<int>(0, (value, byte) => value ^ byte);
  }
}

class _MissingRecipientDeviceError implements NonRetryableOutboxSendError {
  const _MissingRecipientDeviceError();

  @override
  String get message =>
      'Waiting for every conversation member to register an encryption device.';

  @override
  String toString() => message;
}

class _MissingRecipientDeviceSender implements OutboxMessageSender {
  @override
  bool get isOutboxReady => true;

  @override
  Future<bool> messageExists(String messageId) async => false;

  @override
  Future<void> sendMessage({
    required String conversationId,
    required String body,
    String? messageId,
    String? replyToMessageId,
    bool isForwarded = false,
  }) async {
    throw const _MissingRecipientDeviceError();
  }

  @override
  Future<void> sendMediaMessage({
    required String conversationId,
    required String messageId,
    required String body,
    required ChatMedia media,
    String? replyToMessageId,
    bool isForwarded = false,
  }) async {
    throw const _MissingRecipientDeviceError();
  }

  @override
  Future<UploadedChatMedia> uploadMediaAttachment({
    required String conversationId,
    required PickedChatMedia pickedMedia,
    required void Function(double progress) onProgress,
    String? messageId,
    bool upsert = false,
  }) async {
    throw const _MissingRecipientDeviceError();
  }
}

class _NoopTimer implements Timer {
  @override
  bool get isActive => false;

  @override
  int get tick => 0;

  @override
  void cancel() {}
}

class _V3Fixture {
  const _V3Fixture(this.directory, this.file);

  final Directory directory;
  final File file;

  Future<void> dispose() => directory.delete(recursive: true);
}

Future<_V3Fixture> _createV3Fixture() async {
  final directory = await Directory.systemTemp.createTemp('chat-outbox-v3-');
  final file = File('${directory.path}/outbox.sqlite');
  final database = OutboxDatabase.forTesting(NativeDatabase(file));
  await database.customStatement(
    'DROP INDEX IF EXISTS outbox_entries_scope_due_idx',
  );
  await database.customStatement('DROP TABLE outbox_entries');
  await database.customStatement('''
    CREATE TABLE outbox_entries (
      id TEXT NOT NULL,
      backend_origin TEXT NOT NULL,
      owner_user_id TEXT NOT NULL,
      conversation_id TEXT NOT NULL,
      sender_id TEXT NOT NULL,
      sender_name TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      status TEXT NOT NULL,
      attempt_count INTEGER NOT NULL,
      next_attempt_at INTEGER,
      last_error TEXT,
      media_mime_type TEXT,
      media_size_bytes INTEGER,
      remote_bucket TEXT,
      remote_path TEXT,
      media_width INTEGER,
      media_height INTEGER,
      media_duration_ms INTEGER,
      media_waveform TEXT,
      media_original_name TEXT,
      local_media_bytes BLOB,
      reply_to_message_id TEXT,
      reply_sender_name TEXT,
      reply_preview TEXT,
      reply_message_type TEXT,
      reply_is_deleted INTEGER NOT NULL DEFAULT 0,
      is_forwarded INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (id, backend_origin, owner_user_id)
    )
  ''');
  await database
      .into(database.outboxEntries)
      .insert(
        OutboxEntriesCompanion.insert(
          id: 'legacy-draft',
          backendOrigin: 'https://example.supabase.co',
          ownerUserId: 'account-a',
          conversationId: 'conversation-a',
          senderId: 'account-a',
          senderName: 'Amina',
          body: 'v3 private message',
          createdAt: DateTime.utc(2026, 7, 15),
          status: 'pending',
          attemptCount: 0,
          mediaMimeType: const Value('image/jpeg'),
          mediaSizeBytes: const Value(3),
          mediaOriginalName: const Value('v3-secret.jpg'),
          localMediaBytes: Value(Uint8List.fromList([7, 8, 9])),
          replyToMessageId: const Value('source-message'),
          replySenderName: const Value('Mina'),
          replyPreview: const Value('v3 reply preview'),
          replyMessageType: const Value('text'),
          updatedAt: DateTime.utc(2026, 7, 15),
        ),
      );
  await database.customStatement('PRAGMA user_version = 3');
  await database.close();
  return _V3Fixture(directory, file);
}
