import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'chat_models.dart';
import 'offline_outbox_storage.dart';
import 'outbox_database.dart';
import 'outbox_message_sender.dart';

enum OutboxSendStatus { pending, sending, failed }

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
    };
  }

  factory OutboxMessage.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status']?.toString();
    final status = OutboxSendStatus.values.firstWhere(
      (value) => value.name == rawStatus,
      orElse: () => OutboxSendStatus.pending,
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

  final OutboxScope scope;
  final OutboxDatabase _database;
  final bool _ownsDatabase;
  final OutboxMediaStore _legacyMediaStore;
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
  }) async {
    if (_disposed) {
      throw StateError('The offline outbox is already disposed.');
    }
    await initialize();
    if (senderId != scope.userId) {
      throw StateError('Queued messages must belong to the active account.');
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
          );
        })
        .toList(growable: false);
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
        ),
        'Message send',
      );
      return;
    }

    UploadedChatMedia uploaded;
    if (media.isRemote) {
      uploaded = UploadedChatMedia(
        messageId: item.id,
        media: media.toChatMedia(),
      );
    } else {
      final bytes = _localMediaByMessageId[item.id];
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Queued media is missing local storage.');
      }
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
    }

    await _networkOperation(
      sender.sendMediaMessage(
        conversationId: item.conversationId,
        messageId: uploaded.messageId,
        body: item.body,
        media: uploaded.media,
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
    final terminal = attempts >= _maxAttempts;
    final delaySeconds = math.min(1800, math.pow(2, attempts).toInt());
    await _replace(
      item.copyWith(
        status: terminal ? OutboxSendStatus.failed : OutboxSendStatus.pending,
        attemptCount: attempts,
        nextAttemptAt: terminal
            ? null
            : _clock().add(Duration(seconds: delaySeconds)),
        lastError: _compactError(error),
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
    _localMediaByMessageId.remove(messageId);
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
    final media = item.media;
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
            body: item.body,
            createdAt: item.createdAt.toUtc(),
            status: item.status.name,
            attemptCount: item.attemptCount,
            nextAttemptAt: Value(item.nextAttemptAt?.toUtc()),
            lastError: Value(item.lastError),
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
              localMediaBytes == null
                  ? null
                  : Uint8List.fromList(localMediaBytes),
            ),
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
    _items
      ..clear()
      ..addAll(rows.map(_messageFromEntry));
    _localMediaByMessageId
      ..clear()
      ..addEntries(
        rows.map(
          (row) => MapEntry(
            row.id,
            row.localMediaBytes == null
                ? null
                : Uint8List.fromList(row.localMediaBytes!),
          ),
        ),
      );
    _emit();
  }

  Future<void> _restoreInterruptedSends() async {
    final interrupted = _items
        .where((item) => item.status == OutboxSendStatus.sending)
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
        return;
      }

      final remaining = <Map<String, dynamic>>[];
      final removableRefs = <String>[];
      for (final raw in decoded.whereType<Map>()) {
        final json = Map<String, dynamic>.from(raw);
        final item = OutboxMessage.fromJson(json);
        if (item.senderId != scope.userId) {
          remaining.add(json);
          continue;
        }

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
          await _persistItem(migratedItem, localMediaBytes: localBytes);
        } catch (error) {
          debugPrint('[Outbox] Could not migrate queued message: $error');
          remaining.add(json);
        }
      }

      if (remaining.isEmpty) {
        await prefs.remove(_legacyPrefsKey);
      } else {
        await prefs.setString(_legacyPrefsKey, jsonEncode(remaining));
      }
      for (final ref in removableRefs) {
        try {
          await _legacyMediaStore.deleteMedia(ref);
        } catch (_) {
          // A later startup can safely sweep the now-unreferenced legacy file.
        }
      }
    } catch (error) {
      debugPrint('[Outbox] Could not read legacy queued messages: $error');
    }
  }

  OutboxMessage _messageFromEntry(OutboxEntry entry) {
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
    );
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
      if (item.status == OutboxSendStatus.failed) {
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
  final message = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (message.length <= 180) {
    return message;
  }
  return '${message.substring(0, 180)}...';
}
