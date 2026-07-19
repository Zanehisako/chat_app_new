import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'chat_models.dart';
import 'e2ee_draft_protector.dart';
import 'offline_outbox_storage.dart';
import 'outbox_database.dart';
import 'outbox_message_sender.dart';

enum OutboxSendStatus { pending, sending, failed }

/// Whether a queued draft can be restored and sent on this device.
///
/// Authenticated queues only persist [protected] content. [locked] and
/// [discardRequired] deliberately cannot be flushed, even if a caller asks to
/// ignore retry backoff.
enum OutboxDraftEncryptionState {
  localPreview,
  protected,
  locked,
  discardRequired,
}

typedef OutboxTimerFactory =
    Timer Function(Duration duration, void Function() callback);

class OutboxScope {
  const OutboxScope({required this.backendOrigin, required this.userId});

  static const localPreview = OutboxScope(
    backendOrigin: 'local-preview',
    userId: ChatSeed.localUserId,
  );

  final String backendOrigin;
  final String userId;

  factory OutboxScope.fromBackend({
    required String backendUrl,
    required String userId,
  }) {
    final parsed = Uri.tryParse(backendUrl.trim());
    final origin = parsed != null && parsed.hasScheme && parsed.host.isNotEmpty
        ? parsed.origin.toLowerCase()
        : backendUrl.trim().toLowerCase().replaceFirst(RegExp(r'/+$'), '');
    return OutboxScope(backendOrigin: origin, userId: userId.trim());
  }

  bool matches(OutboxScope other) {
    return backendOrigin == other.backendOrigin && userId == other.userId;
  }

  @override
  bool operator ==(Object other) {
    return other is OutboxScope && matches(other);
  }

  @override
  int get hashCode => Object.hash(backendOrigin, userId);
}

class OutboxMessage {
  const OutboxMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    required this.body,
    required this.createdAt,
    required this.status,
    required this.attemptCount,
    this.nextAttemptAt,
    this.lastError,
    this.media,
    this.replyTo,
    this.isForwarded = false,
    this.encryptionState = OutboxDraftEncryptionState.localPreview,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String senderName;
  final String body;
  final DateTime createdAt;
  final OutboxSendStatus status;
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? lastError;
  final QueuedOutboxMedia? media;
  final MessageReplyPreview? replyTo;
  final bool isForwarded;
  final OutboxDraftEncryptionState encryptionState;

  bool get canSend =>
      encryptionState == OutboxDraftEncryptionState.localPreview ||
      encryptionState == OutboxDraftEncryptionState.protected;

  bool isDueAt(DateTime now) {
    if (status == OutboxSendStatus.failed) {
      return false;
    }
    final next = nextAttemptAt;
    return next == null || !now.isBefore(next);
  }

  bool get isDue => isDueAt(DateTime.now());

  OutboxMessage copyWith({
    OutboxSendStatus? status,
    int? attemptCount,
    DateTime? nextAttemptAt,
    String? lastError,
    QueuedOutboxMedia? media,
    OutboxDraftEncryptionState? encryptionState,
    bool clearNextAttemptAt = false,
    bool clearLastError = false,
  }) {
    return OutboxMessage(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      senderName: senderName,
      body: body,
      createdAt: createdAt,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      nextAttemptAt: clearNextAttemptAt
          ? null
          : nextAttemptAt ?? this.nextAttemptAt,
      lastError: clearLastError ? null : lastError ?? this.lastError,
      media: media ?? this.media,
      replyTo: replyTo,
      isForwarded: isForwarded,
      encryptionState: encryptionState ?? this.encryptionState,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'senderId': senderId,
      'senderName': senderName,
      'body': body,
      'createdAt': createdAt.toIso8601String(),
      'status': status.name,
      'attemptCount': attemptCount,
      'nextAttemptAt': nextAttemptAt?.toIso8601String(),
      'lastError': lastError,
      'media': media?.toJson(),
      'replyTo': replyTo == null
          ? null
          : {
              'messageId': replyTo!.messageId,
              'senderName': replyTo!.senderName,
              'preview': replyTo!.preview,
              'messageType': replyTo!.messageType.value,
              'isDeleted': replyTo!.isDeleted,
            },
      'isForwarded': isForwarded,
      'encryptionState': encryptionState.name,
    };
  }

  factory OutboxMessage.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status']?.toString();
    final status = OutboxSendStatus.values.firstWhere(
      (value) => value.name == rawStatus,
      orElse: () => OutboxSendStatus.pending,
    );

    final replyJson = json['replyTo'] is Map
        ? Map<String, dynamic>.from(json['replyTo'] as Map)
        : null;
    final encryptionState = OutboxDraftEncryptionState.values.firstWhere(
      (value) => value.name == json['encryptionState']?.toString(),
      orElse: () => OutboxDraftEncryptionState.localPreview,
    );
    return OutboxMessage(
      id: json['id']?.toString() ?? const Uuid().v4(),
      conversationId: json['conversationId']?.toString() ?? '',
      senderId: json['senderId']?.toString() ?? ChatSeed.localUserId,
      senderName: json['senderName']?.toString() ?? 'You',
      body: json['body']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      status: status == OutboxSendStatus.sending
          ? OutboxSendStatus.pending
          : status,
      attemptCount: _readInt(json['attemptCount']),
      nextAttemptAt: DateTime.tryParse(json['nextAttemptAt']?.toString() ?? ''),
      lastError: json['lastError']?.toString(),
      media: json['media'] is Map
          ? QueuedOutboxMedia.fromJson(
              Map<String, dynamic>.from(json['media'] as Map),
            )
          : null,
      replyTo: replyJson == null
          ? null
          : MessageReplyPreview(
              messageId: replyJson['messageId']?.toString() ?? '',
              senderName: replyJson['senderName']?.toString() ?? 'Unknown',
              preview: replyJson['preview']?.toString() ?? 'Message',
              messageType: ChatMessageType.fromValue(
                replyJson['messageType']?.toString(),
              ),
              isDeleted: replyJson['isDeleted'] == true,
            ),
      isForwarded: json['isForwarded'] == true,
      encryptionState: encryptionState,
    );
  }
}

class QueuedOutboxMedia {
  const QueuedOutboxMedia({
    required this.mimeType,
    required this.sizeBytes,
    this.storageRef,
    this.remoteBucket,
    this.remotePath,
    this.width,
    this.height,
    this.durationMs,
    this.waveform = const [],
    this.originalName,
    this.isEncrypted = false,
    this.conversationId,
    this.messageId,
    this.encryptionEpoch,
    this.encryptionEpochId,
    this.encryptionSenderDeviceId,
    this.encryptionMetadata,
  });

  final String mimeType;
  final int sizeBytes;
  final String? storageRef;
  final String? remoteBucket;
  final String? remotePath;
  final int? width;
  final int? height;
  final int? durationMs;
  final List<double> waveform;
  final String? originalName;
  final bool isEncrypted;
  final String? conversationId;
  final String? messageId;
  final int? encryptionEpoch;
  final String? encryptionEpochId;
  final String? encryptionSenderDeviceId;
  final Map<String, dynamic>? encryptionMetadata;

  bool get isRemote => remotePath != null && remotePath!.isNotEmpty;
  bool get isGif => mimeType.toLowerCase() == 'image/gif';
  bool get isVoice => mimeType.toLowerCase().startsWith('audio/');

  ChatMessageType get messageType => isVoice
      ? ChatMessageType.voice
      : isGif
      ? ChatMessageType.gif
      : ChatMessageType.image;

  QueuedOutboxMedia copyWith({
    String? storageRef,
    String? remoteBucket,
    String? remotePath,
    String? mimeType,
    int? sizeBytes,
    int? width,
    int? height,
    int? durationMs,
    List<double>? waveform,
    String? originalName,
    bool? isEncrypted,
    String? conversationId,
    String? messageId,
    int? encryptionEpoch,
    String? encryptionEpochId,
    String? encryptionSenderDeviceId,
    Map<String, dynamic>? encryptionMetadata,
  }) {
    return QueuedOutboxMedia(
      storageRef: storageRef ?? this.storageRef,
      remoteBucket: remoteBucket ?? this.remoteBucket,
      remotePath: remotePath ?? this.remotePath,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      width: width ?? this.width,
      height: height ?? this.height,
      durationMs: durationMs ?? this.durationMs,
      waveform: waveform ?? this.waveform,
      originalName: originalName ?? this.originalName,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      conversationId: conversationId ?? this.conversationId,
      messageId: messageId ?? this.messageId,
      encryptionEpoch: encryptionEpoch ?? this.encryptionEpoch,
      encryptionEpochId: encryptionEpochId ?? this.encryptionEpochId,
      encryptionSenderDeviceId:
          encryptionSenderDeviceId ?? this.encryptionSenderDeviceId,
      encryptionMetadata: encryptionMetadata ?? this.encryptionMetadata,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'storageRef': storageRef,
      'remoteBucket': remoteBucket,
      'remotePath': remotePath,
      'width': width,
      'height': height,
      'durationMs': durationMs,
      'waveform': waveform,
      'originalName': originalName,
      'isEncrypted': isEncrypted,
      'conversationId': conversationId,
      'messageId': messageId,
      'encryptionEpoch': encryptionEpoch,
      'encryptionEpochId': encryptionEpochId,
      'encryptionSenderDeviceId': encryptionSenderDeviceId,
      'encryptionMetadata': encryptionMetadata,
    };
  }

  factory QueuedOutboxMedia.fromJson(Map<String, dynamic> json) {
    return QueuedOutboxMedia(
      mimeType: json['mimeType']?.toString() ?? 'application/octet-stream',
      sizeBytes: _readInt(json['sizeBytes']),
      storageRef: json['storageRef']?.toString(),
      remoteBucket: json['remoteBucket']?.toString(),
      remotePath: json['remotePath']?.toString(),
      width: _readNullableInt(json['width']),
      height: _readNullableInt(json['height']),
      durationMs: _readNullableInt(json['durationMs']),
      waveform: _readWaveform(json['waveform']),
      originalName: json['originalName']?.toString(),
      isEncrypted: json['isEncrypted'] == true,
      conversationId: json['conversationId']?.toString(),
      messageId: json['messageId']?.toString(),
      encryptionEpoch: _readNullableInt(json['encryptionEpoch']),
      encryptionEpochId: json['encryptionEpochId']?.toString(),
      encryptionSenderDeviceId: json['encryptionSenderDeviceId']?.toString(),
      encryptionMetadata: json['encryptionMetadata'] is Map
          ? Map<String, dynamic>.from(json['encryptionMetadata'] as Map)
          : null,
    );
  }

  factory QueuedOutboxMedia.fromPicked({
    String? storageRef,
    required PickedChatMedia media,
  }) {
    return QueuedOutboxMedia(
      storageRef: storageRef,
      mimeType: media.mimeType,
      sizeBytes: media.sizeBytes,
      width: media.width,
      height: media.height,
      durationMs: media.duration?.inMilliseconds,
      waveform: media.waveform,
      originalName: media.originalName,
    );
  }

  factory QueuedOutboxMedia.fromUploaded(UploadedChatMedia uploaded) {
    final media = uploaded.media;
    return QueuedOutboxMedia(
      remoteBucket: media.bucket,
      remotePath: media.path,
      mimeType: media.mimeType,
      sizeBytes: media.sizeBytes,
      width: media.width,
      height: media.height,
      durationMs: media.duration?.inMilliseconds,
      waveform: media.waveform,
      originalName: media.originalName,
      isEncrypted: media.isEncrypted,
      conversationId: media.conversationId,
      messageId: media.messageId,
      encryptionEpoch: media.encryptionEpoch,
      encryptionEpochId: media.encryptionEpochId,
      encryptionSenderDeviceId: media.encryptionSenderDeviceId,
      encryptionMetadata: media.encryptionMetadata == null
          ? null
          : Map<String, dynamic>.from(media.encryptionMetadata!),
    );
  }

  ChatMedia toChatMedia({Uint8List? localBytes}) {
    return ChatMedia(
      bucket: remoteBucket ?? 'chat-media',
      path: remotePath ?? storageRef ?? '',
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      width: width,
      height: height,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs!),
      waveform: waveform,
      originalName: originalName,
      localBytes: localBytes,
      isEncrypted: isEncrypted,
      conversationId: conversationId,
      messageId: messageId,
      encryptionEpoch: encryptionEpoch,
      encryptionEpochId: encryptionEpochId,
      encryptionSenderDeviceId: encryptionSenderDeviceId,
      encryptionMetadata: encryptionMetadata == null
          ? null
          : Map<String, dynamic>.from(encryptionMetadata!),
    );
  }

  PickedChatMedia toPicked(Uint8List bytes) {
    return PickedChatMedia(
      bytes: bytes,
      originalName:
          originalName ?? 'queued-media${_extensionForMime(mimeType)}',
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      width: width,
      height: height,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs!),
      waveform: waveform,
    );
  }
}

class OfflineOutboxService {
  OfflineOutboxService({
    this.scope = OutboxScope.localPreview,
    OutboxDatabase? database,
    OutboxMediaStore? mediaStore,
    this.draftProtector,
    DateTime Function()? clock,
    OutboxTimerFactory? timerFactory,
    this.networkOperationTimeout = const Duration(seconds: 20),
    this.mediaOperationTimeout = const Duration(minutes: 2),
  }) : _database = database ?? OutboxDatabase(),
       _ownsDatabase = database == null,
       _legacyMediaStore = mediaStore ?? createOutboxMediaStore(),
       _clock = clock ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new;

  static const _legacyPrefsKey = 'chat_app.outbox.messages';
  static const _maxAttempts = 8;
  static const _draftPayloadVersion = 1;
  static const _storedDraftStateLocalPreview = 'local-preview';
  static const _storedDraftStateProtected = 'protected';
  static const _storedDraftStateDiscardRequired = 'discard-required';

  final OutboxScope scope;
  final OutboxDatabase _database;
  final bool _ownsDatabase;
  final OutboxMediaStore _legacyMediaStore;
  final E2eeDraftProtector? draftProtector;
  final DateTime Function() _clock;
  final OutboxTimerFactory _timerFactory;
  final Duration networkOperationTimeout;
  final Duration mediaOperationTimeout;
  final Uuid _uuid = const Uuid();
  final StreamController<List<OutboxMessage>> _controller =
      StreamController<List<OutboxMessage>>.broadcast();
  final List<OutboxMessage> _items = [];
  final Map<String, Uint8List?> _localMediaByMessageId = {};

  OutboxMessageSender? _sender;
  Timer? _retryTimer;
  Future<void>? _initializing;
  Completer<void>? _flushCompletion;
  bool _initialized = false;
  bool _isFlushing = false;
  bool _flushRequested = false;
  bool _forceFlushRequested = false;
  bool _disposed = false;

  Stream<List<OutboxMessage>> get stream => _controller.stream;

  List<OutboxMessage> get items => List.unmodifiable(_items);

  /// True only for the non-authenticated local preview seed data.
  bool get isLocalPreviewScope => scope == OutboxScope.localPreview;

  /// Authenticated queues need a device-local draft protector before they can
  /// accept any content for durable storage.
  bool get requiresDraftProtection => !isLocalPreviewScope;

  Future<void> initialize() async {
    if (_disposed) {
      return;
    }
    if (_initialized) {
      return;
    }
    final initializing = _initializing;
    if (initializing != null) {
      return initializing;
    }

    final future = _initialize();
    _initializing = future;
    return future;
  }

  Future<void> _initialize() async {
    try {
      await _migrateUnprotectedDatabaseEntries();
      await _reload();
      await _restoreInterruptedSends();
      await _migrateLegacyItems();
      await _reload();
      _initialized = true;
      _scheduleRetry();
    } finally {
      _initializing = null;
    }
  }

  Future<void> start(OutboxMessageSender sender) async {
    _sender = sender;
    await initialize();
    await flushNow(ignoreBackoff: true);
  }

  Future<OutboxMessage> enqueue({
    required String conversationId,
    required String senderId,
    required String senderName,
    required String body,
    PickedChatMedia? pickedMedia,
    UploadedChatMedia? uploadedMedia,
    MessageReplyPreview? replyTo,
    bool isForwarded = false,
  }) async {
    if (_disposed) {
      throw StateError('The offline outbox is already disposed.');
    }
    await initialize();
    if (senderId != scope.userId) {
      throw StateError('Queued messages must belong to the active account.');
    }
    if (requiresDraftProtection && draftProtector == null) {
      throw StateError(
        'End-to-end encryption is not ready for this account. '
        'The message was not queued.',
      );
    }

    final id = uploadedMedia?.messageId ?? _uuid.v4();
    final existing = _findById(id);
    if (existing != null) {
      return existing;
    }

    final media = uploadedMedia != null
        ? QueuedOutboxMedia.fromUploaded(uploadedMedia)
        : pickedMedia == null
        ? null
        : QueuedOutboxMedia.fromPicked(media: pickedMedia);
    final item = OutboxMessage(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      senderName: senderName,
      body: body.trim(),
      createdAt: _clock().toUtc(),
      status: OutboxSendStatus.pending,
      attemptCount: 0,
      media: media,
      replyTo: replyTo,
      isForwarded: isForwarded,
      encryptionState: isLocalPreviewScope
          ? OutboxDraftEncryptionState.localPreview
          : OutboxDraftEncryptionState.protected,
    );
    await _persistItem(item, localMediaBytes: pickedMedia?.bytes);
    _items.add(item);
    _localMediaByMessageId[id] = pickedMedia == null
        ? null
        : Uint8List.fromList(pickedMedia.bytes);
    _emit();
    _scheduleRetry();
    return item;
  }

  Future<void> flush(
    OutboxMessageSender sender, {
    bool ignoreBackoff = false,
  }) async {
    _sender = sender;
    await initialize();
    await flushNow(ignoreBackoff: ignoreBackoff);
  }

  Future<void> flushNow({bool ignoreBackoff = false}) async {
    await initialize();
    if (_disposed) {
      return;
    }
    final sender = _sender;
    if (sender == null || !sender.isOutboxReady || !_matchesSender(sender)) {
      return;
    }

    if (_isFlushing) {
      _flushRequested = true;
      _forceFlushRequested = _forceFlushRequested || ignoreBackoff;
      return;
    }

    _isFlushing = true;
    final completion = Completer<void>();
    _flushCompletion = completion;
    var force = ignoreBackoff;
    try {
      do {
        _flushRequested = false;
        _forceFlushRequested = false;
        await _flushPass(sender, ignoreBackoff: force);
        force = _forceFlushRequested;
      } while (_flushRequested && !_disposed);
    } finally {
      _isFlushing = false;
      _scheduleRetry();
      if (!completion.isCompleted) {
        completion.complete();
      }
      if (identical(_flushCompletion, completion)) {
        _flushCompletion = null;
      }
    }
  }

  Future<void> retryNow(String messageId) async {
    await initialize();
    final item = _findById(messageId);
    if (item == null) {
      return;
    }
    if (!item.canSend) {
      throw StateError(
        item.encryptionState == OutboxDraftEncryptionState.discardRequired
            ? 'This legacy queued draft must be discarded before sending.'
            : 'This encrypted queued draft is locked on this device.',
      );
    }
    await _replace(
      item.copyWith(
        status: OutboxSendStatus.pending,
        attemptCount: 0,
        clearNextAttemptAt: true,
        clearLastError: true,
      ),
    );
    await flushNow(ignoreBackoff: true);
  }

  Future<List<ChatMessage>> localMessages() async {
    await initialize();
    return _items
        .map((item) {
          final media = item.media;
          return ChatMessage(
            id: item.id,
            threadId: item.conversationId,
            senderId: item.senderId,
            senderName: item.senderName,
            body: item.body,
            createdAt: item.createdAt.toLocal(),
            isMine: true,
            isDelivered: false,
            isRead: false,
            messageType: media?.messageType ?? ChatMessageType.text,
            media: media?.toChatMedia(
              localBytes: _localMediaByMessageId[item.id],
            ),
            sendState: switch (item.status) {
              OutboxSendStatus.pending => ChatMessageSendState.pending,
              OutboxSendStatus.sending => ChatMessageSendState.sending,
              OutboxSendStatus.failed => ChatMessageSendState.failed,
            },
            sendError: item.lastError,
            replyTo: item.replyTo,
            isForwarded: item.isForwarded,
            encryptionState: switch (item.encryptionState) {
              OutboxDraftEncryptionState.localPreview =>
                ChatMessageEncryptionState.legacy,
              OutboxDraftEncryptionState.protected =>
                ChatMessageEncryptionState.encrypted,
              OutboxDraftEncryptionState.locked =>
                ChatMessageEncryptionState.locked,
              OutboxDraftEncryptionState.discardRequired =>
                ChatMessageEncryptionState.invalid,
            },
            encryptionError:
                item.encryptionState == OutboxDraftEncryptionState.protected ||
                    item.encryptionState ==
                        OutboxDraftEncryptionState.localPreview
                ? null
                : item.lastError,
          );
        })
        .toList(growable: false);
  }

  /// Removes a queued draft without attempting delivery.
  ///
  /// This is the required recovery path for legacy plaintext rows that could
  /// not be protected during the v3-to-v4 migration.
  Future<void> discard(String messageId) async {
    await initialize();
    if (_findById(messageId) == null) {
      return;
    }
    await _remove(messageId);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _retryTimer?.cancel();
    await _controller.close();
    final initializing = _initializing;
    if (initializing != null) {
      try {
        await initializing;
      } catch (_) {
        // Initialization failures do not prevent the owned database closing.
      }
    }
    await _flushCompletion?.future;
    if (_ownsDatabase) {
      await _database.close();
    }
  }

  Future<void> _flushPass(
    OutboxMessageSender sender, {
    required bool ignoreBackoff,
  }) async {
    final now = _clock();
    final due =
        _items
            .where(
              (item) =>
                  item.status != OutboxSendStatus.failed &&
                  item.canSend &&
                  (ignoreBackoff || item.isDueAt(now)),
            )
            .toList()
          ..sort((left, right) => left.createdAt.compareTo(right.createdAt));

    for (final candidate in due) {
      final item = _findById(candidate.id);
      if (item == null) {
        continue;
      }
      await _replace(
        item.copyWith(
          status: OutboxSendStatus.sending,
          clearNextAttemptAt: true,
          clearLastError: true,
        ),
      );

      try {
        await _sendItem(sender, item.id);
        await _remove(item.id);
      } catch (error) {
        await _markFailed(item.id, error);
      }
    }
  }

  Future<void> _sendItem(OutboxMessageSender sender, String messageId) async {
    var item = _findById(messageId);
    if (item == null) {
      return;
    }

    // The stable outbox id makes a probe safe when Supabase accepted a request
    // but the client lost its response.
    if (await _networkOperation(
      sender.messageExists(item.id),
      'Message status check',
    )) {
      return;
    }

    final media = item.media;
    if (media == null) {
      await _networkOperation(
        sender.sendMessage(
          conversationId: item.conversationId,
          messageId: item.id,
          body: item.body,
          replyToMessageId: item.replyTo?.messageId,
          isForwarded: item.isForwarded,
        ),
        'Message send',
      );
      return;
    }

    final bytes = _localMediaByMessageId[item.id];
    UploadedChatMedia uploaded;
    if (bytes != null && bytes.isNotEmpty) {
      // Always prefer the locally protected source. A membership/device
      // change can invalidate a previously staged ciphertext; re-encrypting
      // here binds the upload to the epoch that is current at delivery time.
      uploaded = await _mediaOperation(
        sender.uploadMediaAttachment(
          conversationId: item.conversationId,
          pickedMedia: media.toPicked(bytes),
          onProgress: (_) {},
          messageId: item.id,
          upsert: true,
        ),
        'Media upload',
      );

      item = item.copyWith(media: QueuedOutboxMedia.fromUploaded(uploaded));
      await _replace(item);
    } else if (media.isRemote) {
      uploaded = UploadedChatMedia(
        messageId: item.id,
        media: media.toChatMedia(),
      );
    } else {
      throw StateError('Queued media is missing local storage.');
    }

    await _networkOperation(
      sender.sendMediaMessage(
        conversationId: item.conversationId,
        messageId: uploaded.messageId,
        body: item.body,
        media: uploaded.media,
        replyToMessageId: item.replyTo?.messageId,
        isForwarded: item.isForwarded,
      ),
      'Media message send',
    );
  }

  Future<T> _networkOperation<T>(Future<T> operation, String label) {
    return operation.timeout(
      networkOperationTimeout,
      onTimeout: () => throw TimeoutException('$label timed out.'),
    );
  }

  Future<T> _mediaOperation<T>(Future<T> operation, String label) {
    return operation.timeout(
      mediaOperationTimeout,
      onTimeout: () => throw TimeoutException('$label timed out.'),
    );
  }

  Future<void> _markFailed(String messageId, Object error) async {
    final item = _findById(messageId);
    if (item == null) {
      return;
    }
    final attempts = item.attemptCount + 1;
    final safeError = _compactError(error);
    final terminal =
        error is NonRetryableOutboxSendError || attempts >= _maxAttempts;
    final delaySeconds = math.min(1800, math.pow(2, attempts).toInt());
    debugPrint('[Outbox] Delivery failed for $messageId: $safeError');
    await _replace(
      item.copyWith(
        status: terminal ? OutboxSendStatus.failed : OutboxSendStatus.pending,
        attemptCount: attempts,
        nextAttemptAt: terminal
            ? null
            : _clock().add(Duration(seconds: delaySeconds)),
        lastError: safeError,
      ),
    );
  }

  Future<void> _remove(String messageId) async {
    await (_database.delete(_database.outboxEntries)..where(
          (row) =>
              row.id.equals(messageId) &
              row.backendOrigin.equals(scope.backendOrigin) &
              row.ownerUserId.equals(scope.userId),
        ))
        .go();
    _items.removeWhere((item) => item.id == messageId);
    final localBytes = _localMediaByMessageId.remove(messageId);
    _wipeBytes(localBytes);
    _emit();
  }

  Future<void> _replace(OutboxMessage item) async {
    await _persistItem(item, localMediaBytes: _localMediaByMessageId[item.id]);
    final index = _items.indexWhere((existing) => existing.id == item.id);
    if (index != -1) {
      _items[index] = item;
      _emit();
    }
  }

  Future<void> _persistItem(
    OutboxMessage item, {
    Uint8List? localMediaBytes,
  }) async {
    final useLocalPreviewStorage =
        isLocalPreviewScope &&
        item.encryptionState == OutboxDraftEncryptionState.localPreview;
    final useProtectedStorage =
        item.encryptionState == OutboxDraftEncryptionState.protected;
    final discardRequired =
        item.encryptionState == OutboxDraftEncryptionState.discardRequired;
    final persistedError = useLocalPreviewStorage
        ? item.lastError
        : discardRequired
        ? 'Queued draft could not be secured. Discard it and create it again.'
        : item.lastError == null
        ? null
        : 'Encrypted message delivery failed. Try again.';
    if (!useLocalPreviewStorage && !useProtectedStorage && !discardRequired) {
      throw StateError('A locked draft cannot be written back to the outbox.');
    }
    if (requiresDraftProtection && !useProtectedStorage && !discardRequired) {
      throw StateError(
        'Authenticated queued messages must be encrypted before persistence.',
      );
    }

    Uint8List? protectedDraft;
    if (useProtectedStorage) {
      final protector = draftProtector;
      if (protector == null) {
        throw StateError(
          'End-to-end encryption is not ready for this account. '
          'The message was not queued.',
        );
      }
      final plaintext = _encodeProtectedPayload(item, localMediaBytes);
      try {
        protectedDraft = await protector.protectDraft(
          context: _draftContextFor(item),
          plaintext: plaintext,
        );
        if (protectedDraft.isEmpty) {
          throw StateError('Draft encryption returned an empty payload.');
        }
      } finally {
        _wipeBytes(plaintext);
      }
    }

    final media = useLocalPreviewStorage ? item.media : null;
    await _database
        .into(_database.outboxEntries)
        .insertOnConflictUpdate(
          OutboxEntriesCompanion.insert(
            id: item.id,
            backendOrigin: scope.backendOrigin,
            ownerUserId: scope.userId,
            conversationId: item.conversationId,
            senderId: item.senderId,
            senderName: item.senderName,
            body: useLocalPreviewStorage ? item.body : '',
            createdAt: item.createdAt.toUtc(),
            status: discardRequired
                ? OutboxSendStatus.failed.name
                : item.status.name,
            attemptCount: item.attemptCount,
            nextAttemptAt: Value(item.nextAttemptAt?.toUtc()),
            lastError: Value(persistedError),
            mediaMimeType: Value(media?.mimeType),
            mediaSizeBytes: Value(media?.sizeBytes),
            remoteBucket: Value(media?.remoteBucket),
            remotePath: Value(media?.remotePath),
            mediaWidth: Value(media?.width),
            mediaHeight: Value(media?.height),
            mediaDurationMs: Value(media?.durationMs),
            mediaWaveform: Value(
              media == null ? null : jsonEncode(media.waveform),
            ),
            mediaOriginalName: Value(media?.originalName),
            localMediaBytes: Value(
              !useLocalPreviewStorage || localMediaBytes == null
                  ? null
                  : Uint8List.fromList(localMediaBytes),
            ),
            replyToMessageId: Value(
              useLocalPreviewStorage ? item.replyTo?.messageId : null,
            ),
            replySenderName: Value(
              useLocalPreviewStorage ? item.replyTo?.senderName : null,
            ),
            replyPreview: Value(
              useLocalPreviewStorage ? item.replyTo?.preview : null,
            ),
            replyMessageType: Value(
              useLocalPreviewStorage ? item.replyTo?.messageType.value : null,
            ),
            replyIsDeleted: Value(
              useLocalPreviewStorage && (item.replyTo?.isDeleted ?? false),
            ),
            isForwarded: Value(
              useLocalPreviewStorage ? item.isForwarded : false,
            ),
            draftEncryptionVersion: Value(
              useProtectedStorage ? _draftPayloadVersion : 0,
            ),
            draftEncryptionState: Value(
              useProtectedStorage
                  ? _storedDraftStateProtected
                  : discardRequired
                  ? _storedDraftStateDiscardRequired
                  : _storedDraftStateLocalPreview,
            ),
            encryptedDraft: Value(protectedDraft),
            updatedAt: _clock().toUtc(),
          ),
        );
  }

  Future<void> _reload() async {
    final rows =
        await (_database.select(_database.outboxEntries)
              ..where(
                (row) =>
                    row.backendOrigin.equals(scope.backendOrigin) &
                    row.ownerUserId.equals(scope.userId),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get();
    for (final bytes in _localMediaByMessageId.values) {
      _wipeBytes(bytes);
    }
    final loaded = <_LoadedOutboxEntry>[];
    for (final row in rows) {
      loaded.add(await _loadEntry(row));
    }
    _items
      ..clear()
      ..addAll(loaded.map((entry) => entry.item));
    _localMediaByMessageId
      ..clear()
      ..addEntries(
        loaded.map((entry) => MapEntry(entry.item.id, entry.localMediaBytes)),
      );
    _emit();
  }

  Future<void> _restoreInterruptedSends() async {
    final interrupted = _items
        .where(
          (item) => item.status == OutboxSendStatus.sending && item.canSend,
        )
        .toList(growable: false);
    for (final item in interrupted) {
      await _replace(
        item.copyWith(
          status: OutboxSendStatus.pending,
          clearNextAttemptAt: true,
        ),
      );
    }
  }

  Future<void> _migrateLegacyItems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(_legacyPrefsKey);
      if (encoded == null || encoded.isEmpty) {
        return;
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! List) {
        // A malformed legacy value might still contain message content. It
        // cannot be safely reconstructed, so remove it rather than leaving a
        // plaintext draft behind indefinitely.
        await prefs.remove(_legacyPrefsKey);
        return;
      }

      final removableRefs = <String>[];
      for (final raw in decoded.whereType<Map>()) {
        final json = Map<String, dynamic>.from(raw);
        final item = OutboxMessage.fromJson(json);
        try {
          var migratedItem = item;
          Uint8List? localBytes;
          final storageRef = item.media?.storageRef;
          if (storageRef != null && storageRef.isNotEmpty) {
            localBytes = await _legacyMediaStore.readMedia(storageRef);
            if (localBytes.isEmpty && !(item.media?.isRemote ?? false)) {
              migratedItem = item.copyWith(
                status: OutboxSendStatus.failed,
                lastError:
                    'Queued media could not be migrated from local storage.',
              );
              localBytes = null;
            } else {
              removableRefs.add(storageRef);
            }
          }
          if (item.senderId != scope.userId) {
            // Legacy preferences have no backend scope. Keeping another
            // account's plaintext here after E2EE is enabled is unsafe.
            _wipeBytes(localBytes);
            continue;
          }
          if (requiresDraftProtection) {
            if (draftProtector == null) {
              await _persistDiscardRequiredMessage(migratedItem);
            } else {
              migratedItem = migratedItem.copyWith(
                encryptionState: OutboxDraftEncryptionState.protected,
              );
              try {
                await _persistItem(migratedItem, localMediaBytes: localBytes);
              } catch (_) {
                await _persistDiscardRequiredMessage(migratedItem);
              }
            }
          } else {
            await _persistItem(migratedItem, localMediaBytes: localBytes);
          }
          _wipeBytes(localBytes);
        } catch (error) {
          debugPrint('[Outbox] Could not migrate queued message: $error');
          if (item.senderId == scope.userId && requiresDraftProtection) {
            await _persistDiscardRequiredMessage(item);
          }
        }
      }

      // Do not retain a plaintext retry queue in SharedPreferences after its
      // entries have either been protected or marked for explicit discard.
      await prefs.remove(_legacyPrefsKey);
      for (final ref in removableRefs) {
        try {
          await _legacyMediaStore.deleteMedia(ref);
        } catch (_) {
          // A later startup can safely sweep the now-unreferenced legacy file.
        }
      }
    } catch (error) {
      debugPrint('[Outbox] Could not read legacy queued messages: $error');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_legacyPrefsKey);
      } catch (_) {
        // Storage may be unavailable; a later startup retries the wipe.
      }
    }
  }

  Future<void> _migrateUnprotectedDatabaseEntries() async {
    // Make SQLite overwrite reclaimed record payloads while replacing v3
    // plaintext. This complements clearing the live columns below; it is best
    // effort on platforms whose SQLite build supports secure deletion.
    try {
      await _database.customStatement('PRAGMA secure_delete = ON');
    } catch (_) {
      // The live plaintext columns are still cleared below on SQLite builds
      // that do not expose this optional hardening pragma.
    }
    final rows = await _database.select(_database.outboxEntries).get();
    for (final row in rows) {
      if (row.draftEncryptionState == _storedDraftStateProtected) {
        if (row.encryptedDraft != null && row.encryptedDraft!.isNotEmpty) {
          continue;
        }
        await _markEntryDiscardRequired(row);
        _wipeBytes(row.localMediaBytes);
        continue;
      }
      if (row.draftEncryptionState == _storedDraftStateDiscardRequired) {
        continue;
      }
      if (_isLocalPreviewEntry(row)) {
        // Preview data is deliberately isolated from authenticated accounts.
        continue;
      }

      final isActiveScope =
          row.backendOrigin == scope.backendOrigin &&
          row.ownerUserId == scope.userId;
      if (isActiveScope && draftProtector != null) {
        final legacy = _legacyMessageFromEntry(
          row,
        ).copyWith(encryptionState: OutboxDraftEncryptionState.protected);
        final localMediaBytes = row.localMediaBytes == null
            ? null
            : Uint8List.fromList(row.localMediaBytes!);
        try {
          await _persistItem(legacy, localMediaBytes: localMediaBytes);
        } catch (_) {
          await _markEntryDiscardRequired(row);
        } finally {
          _wipeBytes(localMediaBytes);
        }
      } else {
        await _markEntryDiscardRequired(row);
      }
      _wipeBytes(row.localMediaBytes);
    }
  }

  Future<_LoadedOutboxEntry> _loadEntry(OutboxEntry entry) async {
    if (entry.draftEncryptionState == _storedDraftStateDiscardRequired) {
      return _LoadedOutboxEntry(
        item: _discardRequiredMessageFromEntry(entry),
        localMediaBytes: null,
      );
    }
    if (entry.draftEncryptionState != _storedDraftStateProtected) {
      return _LoadedOutboxEntry(
        item: _legacyMessageFromEntry(entry),
        localMediaBytes: entry.localMediaBytes == null
            ? null
            : Uint8List.fromList(entry.localMediaBytes!),
      );
    }

    final protectedDraft = entry.encryptedDraft;
    final protector = draftProtector;
    if (protectedDraft == null || protectedDraft.isEmpty || protector == null) {
      return _LoadedOutboxEntry(
        item: _lockedMessageFromEntry(entry),
        localMediaBytes: null,
      );
    }

    Uint8List? plaintext;
    try {
      plaintext = await protector.unprotectDraft(
        context: _draftContextForEntry(entry),
        protectedDraft: Uint8List.fromList(protectedDraft),
      );
      final content = _decodeProtectedPayload(
        context: _draftContextForEntry(entry),
        plaintext: plaintext,
      );
      return _LoadedOutboxEntry(
        item: OutboxMessage(
          id: entry.id,
          conversationId: entry.conversationId,
          senderId: entry.senderId,
          senderName: entry.senderName,
          body: content.body,
          createdAt: entry.createdAt,
          status: _statusFromEntry(entry),
          attemptCount: entry.attemptCount,
          nextAttemptAt: entry.nextAttemptAt,
          lastError: entry.lastError,
          media: content.media,
          replyTo: content.replyTo,
          isForwarded: content.isForwarded,
          encryptionState: OutboxDraftEncryptionState.protected,
        ),
        localMediaBytes: content.localMediaBytes,
      );
    } catch (_) {
      return _LoadedOutboxEntry(
        item: _lockedMessageFromEntry(entry),
        localMediaBytes: null,
      );
    } finally {
      _wipeBytes(plaintext);
    }
  }

  OutboxMessage _legacyMessageFromEntry(OutboxEntry entry) {
    final rawStatus = entry.status;
    final parsedStatus = OutboxSendStatus.values.firstWhere(
      (status) => status.name == rawStatus,
      orElse: () => OutboxSendStatus.pending,
    );
    final media = entry.mediaMimeType == null
        ? null
        : QueuedOutboxMedia(
            mimeType: entry.mediaMimeType!,
            sizeBytes: entry.mediaSizeBytes ?? 0,
            remoteBucket: entry.remoteBucket,
            remotePath: entry.remotePath,
            width: entry.mediaWidth,
            height: entry.mediaHeight,
            durationMs: entry.mediaDurationMs,
            waveform: _readWaveformJson(entry.mediaWaveform),
            originalName: entry.mediaOriginalName,
          );
    return OutboxMessage(
      id: entry.id,
      conversationId: entry.conversationId,
      senderId: entry.senderId,
      senderName: entry.senderName,
      body: entry.body,
      createdAt: entry.createdAt,
      status: parsedStatus,
      attemptCount: entry.attemptCount,
      nextAttemptAt: entry.nextAttemptAt,
      lastError: entry.lastError,
      media: media,
      replyTo: entry.replyToMessageId == null
          ? null
          : MessageReplyPreview(
              messageId: entry.replyToMessageId!,
              senderName: entry.replySenderName ?? 'Unknown',
              preview: entry.replyPreview ?? 'Message',
              messageType: ChatMessageType.fromValue(entry.replyMessageType),
              isDeleted: entry.replyIsDeleted,
            ),
      isForwarded: entry.isForwarded,
      encryptionState: OutboxDraftEncryptionState.localPreview,
    );
  }

  OutboxMessage _lockedMessageFromEntry(OutboxEntry entry) {
    return OutboxMessage(
      id: entry.id,
      conversationId: entry.conversationId,
      senderId: entry.senderId,
      senderName: entry.senderName,
      body: '',
      createdAt: entry.createdAt,
      status: _statusFromEntry(entry),
      attemptCount: entry.attemptCount,
      nextAttemptAt: entry.nextAttemptAt,
      lastError: 'Encrypted queued draft is unavailable on this device.',
      encryptionState: OutboxDraftEncryptionState.locked,
    );
  }

  OutboxMessage _discardRequiredMessageFromEntry(OutboxEntry entry) {
    return OutboxMessage(
      id: entry.id,
      conversationId: entry.conversationId,
      senderId: entry.senderId,
      senderName: entry.senderName,
      body: '',
      createdAt: entry.createdAt,
      status: OutboxSendStatus.failed,
      attemptCount: entry.attemptCount,
      lastError:
          'Queued draft could not be secured. Discard it and create it again.',
      encryptionState: OutboxDraftEncryptionState.discardRequired,
    );
  }

  Future<void> _persistDiscardRequiredMessage(OutboxMessage source) {
    return _persistItem(
      OutboxMessage(
        id: source.id,
        conversationId: source.conversationId,
        senderId: source.senderId,
        senderName: source.senderName,
        body: '',
        createdAt: source.createdAt,
        status: OutboxSendStatus.failed,
        attemptCount: source.attemptCount,
        lastError:
            'Queued draft could not be secured. Discard it and create it again.',
        encryptionState: OutboxDraftEncryptionState.discardRequired,
      ),
    );
  }

  Future<void> _markEntryDiscardRequired(OutboxEntry entry) async {
    await (_database.update(_database.outboxEntries)..where(
          (row) =>
              row.id.equals(entry.id) &
              row.backendOrigin.equals(entry.backendOrigin) &
              row.ownerUserId.equals(entry.ownerUserId),
        ))
        .write(
          OutboxEntriesCompanion(
            body: const Value(''),
            status: const Value('failed'),
            nextAttemptAt: const Value(null),
            lastError: const Value(
              'Queued draft could not be secured. Discard it and create it again.',
            ),
            mediaMimeType: const Value(null),
            mediaSizeBytes: const Value(null),
            remoteBucket: const Value(null),
            remotePath: const Value(null),
            mediaWidth: const Value(null),
            mediaHeight: const Value(null),
            mediaDurationMs: const Value(null),
            mediaWaveform: const Value(null),
            mediaOriginalName: const Value(null),
            localMediaBytes: const Value(null),
            replyToMessageId: const Value(null),
            replySenderName: const Value(null),
            replyPreview: const Value(null),
            replyMessageType: const Value(null),
            replyIsDeleted: const Value(false),
            isForwarded: const Value(false),
            draftEncryptionVersion: const Value(0),
            draftEncryptionState: const Value(_storedDraftStateDiscardRequired),
            encryptedDraft: const Value(null),
            updatedAt: Value(_clock().toUtc()),
          ),
        );
  }

  E2eeDraftProtectionContext _draftContextFor(OutboxMessage item) {
    return E2eeDraftProtectionContext(
      backendOrigin: scope.backendOrigin,
      userId: scope.userId,
      conversationId: item.conversationId,
      draftId: item.id,
    );
  }

  E2eeDraftProtectionContext _draftContextForEntry(OutboxEntry entry) {
    return E2eeDraftProtectionContext(
      backendOrigin: entry.backendOrigin,
      userId: entry.ownerUserId,
      conversationId: entry.conversationId,
      draftId: entry.id,
    );
  }

  Uint8List _encodeProtectedPayload(
    OutboxMessage item,
    Uint8List? localMediaBytes,
  ) {
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': _draftPayloadVersion,
          'context': _draftContextFor(item).toJson(),
          'body': item.body,
          'media': item.media?.toJson(),
          'local_media_b64': localMediaBytes == null
              ? null
              : base64Encode(localMediaBytes),
          'reply_to': item.replyTo == null
              ? null
              : {
                  'message_id': item.replyTo!.messageId,
                  'sender_name': item.replyTo!.senderName,
                  'preview': item.replyTo!.preview,
                  'message_type': item.replyTo!.messageType.value,
                  'is_deleted': item.replyTo!.isDeleted,
                },
          'is_forwarded': item.isForwarded,
        }),
      ),
    );
  }

  _DecodedProtectedPayload _decodeProtectedPayload({
    required E2eeDraftProtectionContext context,
    required Uint8List plaintext,
  }) {
    final decoded = jsonDecode(utf8.decode(plaintext));
    if (decoded is! Map) {
      throw const FormatException('Invalid encrypted draft payload.');
    }
    final payload = Map<String, dynamic>.from(decoded);
    if (_readInt(payload['version']) != _draftPayloadVersion ||
        !context.matchesJson(payload['context'])) {
      throw const FormatException('Encrypted draft context did not match.');
    }
    final mediaJson = payload['media'] is Map
        ? Map<String, dynamic>.from(payload['media'] as Map)
        : null;
    final replyJson = payload['reply_to'] is Map
        ? Map<String, dynamic>.from(payload['reply_to'] as Map)
        : null;
    final localMedia = payload['local_media_b64']?.toString();
    return _DecodedProtectedPayload(
      body: payload['body']?.toString() ?? '',
      media: mediaJson == null ? null : QueuedOutboxMedia.fromJson(mediaJson),
      localMediaBytes: localMedia == null || localMedia.isEmpty
          ? null
          : Uint8List.fromList(base64Decode(localMedia)),
      replyTo: replyJson == null
          ? null
          : MessageReplyPreview(
              messageId: replyJson['message_id']?.toString() ?? '',
              senderName: replyJson['sender_name']?.toString() ?? 'Unknown',
              preview: replyJson['preview']?.toString() ?? 'Message',
              messageType: ChatMessageType.fromValue(
                replyJson['message_type']?.toString(),
              ),
              isDeleted: replyJson['is_deleted'] == true,
            ),
      isForwarded: payload['is_forwarded'] == true,
    );
  }

  OutboxSendStatus _statusFromEntry(OutboxEntry entry) {
    return OutboxSendStatus.values.firstWhere(
      (status) => status.name == entry.status,
      orElse: () => OutboxSendStatus.pending,
    );
  }

  bool _isLocalPreviewEntry(OutboxEntry entry) {
    return entry.backendOrigin == OutboxScope.localPreview.backendOrigin &&
        entry.ownerUserId == OutboxScope.localPreview.userId;
  }

  bool _matchesSender(OutboxMessageSender sender) {
    if (sender is! OutboxScopeProvider) {
      return true;
    }
    final scopedSender = sender as OutboxScopeProvider;
    return scopedSender.outboxUserId == scope.userId &&
        scopedSender.outboxBackendOrigin == scope.backendOrigin;
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_disposed || _sender == null || _items.isEmpty) {
      return;
    }
    final now = _clock();
    DateTime? earliest;
    for (final item in _items) {
      if (item.status == OutboxSendStatus.failed || !item.canSend) {
        continue;
      }
      final due = item.nextAttemptAt ?? now;
      if (earliest == null || due.isBefore(earliest)) {
        earliest = due;
      }
    }
    if (earliest == null) {
      return;
    }
    final delay = earliest.isAfter(now)
        ? earliest.difference(now)
        : Duration.zero;
    _retryTimer = _timerFactory(delay, () {
      unawaited(flushNow());
    });
  }

  OutboxMessage? _findById(String id) {
    for (final item in _items) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(List.unmodifiable(_items));
    }
  }
}

class _LoadedOutboxEntry {
  const _LoadedOutboxEntry({required this.item, required this.localMediaBytes});

  final OutboxMessage item;
  final Uint8List? localMediaBytes;
}

class _DecodedProtectedPayload {
  const _DecodedProtectedPayload({
    required this.body,
    required this.media,
    required this.localMediaBytes,
    required this.replyTo,
    required this.isForwarded,
  });

  final String body;
  final QueuedOutboxMedia? media;
  final Uint8List? localMediaBytes;
  final MessageReplyPreview? replyTo;
  final bool isForwarded;
}

void _wipeBytes(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    return;
  }
  bytes.fillRange(0, bytes.length, 0);
}

int _readInt(Object? value) => _readNullableInt(value) ?? 0;

int? _readNullableInt(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '');
}

List<double> _readWaveform(Object? value) {
  if (value is! Iterable) {
    return const [];
  }
  return value
      .map(
        (entry) => entry is num ? entry.toDouble() : double.tryParse('$entry'),
      )
      .whereType<double>()
      .map((entry) => entry.clamp(0.0, 1.0).toDouble())
      .toList(growable: false);
}

List<double> _readWaveformJson(String? encoded) {
  if (encoded == null || encoded.isEmpty) {
    return const [];
  }
  try {
    return _readWaveform(jsonDecode(encoded));
  } catch (_) {
    return const [];
  }
}

String _extensionForMime(String mimeType) {
  return switch (mimeType.toLowerCase()) {
    'image/png' => '.png',
    'image/webp' => '.webp',
    'image/gif' => '.gif',
    'image/heic' => '.heic',
    'image/heif' => '.heif',
    'audio/aac' => '.aac',
    'audio/mpeg' || 'audio/mp3' => '.mp3',
    'audio/mp4' => '.m4a',
    'audio/webm' => '.webm',
    'audio/ogg' => '.ogg',
    'audio/wav' || 'audio/x-wav' => '.wav',
    _ => '.bin',
  };
}

String _compactError(Object error) {
  final rawMessage = error is NonRetryableOutboxSendError
      ? error.message
      : error.toString();
  final message = rawMessage.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (message.length <= 180) {
    return message;
  }
  return '${message.substring(0, 180)}...';
}
