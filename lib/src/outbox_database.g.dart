// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'outbox_database.dart';

// ignore_for_file: type=lint
class $OutboxEntriesTable extends OutboxEntries
    with TableInfo<$OutboxEntriesTable, OutboxEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OutboxEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _backendOriginMeta = const VerificationMeta(
    'backendOrigin',
  );
  @override
  late final GeneratedColumn<String> backendOrigin = GeneratedColumn<String>(
    'backend_origin',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ownerUserIdMeta = const VerificationMeta(
    'ownerUserId',
  );
  @override
  late final GeneratedColumn<String> ownerUserId = GeneratedColumn<String>(
    'owner_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderIdMeta = const VerificationMeta(
    'senderId',
  );
  @override
  late final GeneratedColumn<String> senderId = GeneratedColumn<String>(
    'sender_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderNameMeta = const VerificationMeta(
    'senderName',
  );
  @override
  late final GeneratedColumn<String> senderName = GeneratedColumn<String>(
    'sender_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<DateTime> nextAttemptAt =
      GeneratedColumn<DateTime>(
        'next_attempt_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaMimeTypeMeta = const VerificationMeta(
    'mediaMimeType',
  );
  @override
  late final GeneratedColumn<String> mediaMimeType = GeneratedColumn<String>(
    'media_mime_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaSizeBytesMeta = const VerificationMeta(
    'mediaSizeBytes',
  );
  @override
  late final GeneratedColumn<int> mediaSizeBytes = GeneratedColumn<int>(
    'media_size_bytes',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteBucketMeta = const VerificationMeta(
    'remoteBucket',
  );
  @override
  late final GeneratedColumn<String> remoteBucket = GeneratedColumn<String>(
    'remote_bucket',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remotePathMeta = const VerificationMeta(
    'remotePath',
  );
  @override
  late final GeneratedColumn<String> remotePath = GeneratedColumn<String>(
    'remote_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaWidthMeta = const VerificationMeta(
    'mediaWidth',
  );
  @override
  late final GeneratedColumn<int> mediaWidth = GeneratedColumn<int>(
    'media_width',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaHeightMeta = const VerificationMeta(
    'mediaHeight',
  );
  @override
  late final GeneratedColumn<int> mediaHeight = GeneratedColumn<int>(
    'media_height',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaDurationMsMeta = const VerificationMeta(
    'mediaDurationMs',
  );
  @override
  late final GeneratedColumn<int> mediaDurationMs = GeneratedColumn<int>(
    'media_duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaWaveformMeta = const VerificationMeta(
    'mediaWaveform',
  );
  @override
  late final GeneratedColumn<String> mediaWaveform = GeneratedColumn<String>(
    'media_waveform',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaOriginalNameMeta = const VerificationMeta(
    'mediaOriginalName',
  );
  @override
  late final GeneratedColumn<String> mediaOriginalName =
      GeneratedColumn<String>(
        'media_original_name',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _localMediaBytesMeta = const VerificationMeta(
    'localMediaBytes',
  );
  @override
  late final GeneratedColumn<Uint8List> localMediaBytes =
      GeneratedColumn<Uint8List>(
        'local_media_bytes',
        aliasedName,
        true,
        type: DriftSqlType.blob,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    backendOrigin,
    ownerUserId,
    conversationId,
    senderId,
    senderName,
    body,
    createdAt,
    status,
    attemptCount,
    nextAttemptAt,
    lastError,
    mediaMimeType,
    mediaSizeBytes,
    remoteBucket,
    remotePath,
    mediaWidth,
    mediaHeight,
    mediaDurationMs,
    mediaWaveform,
    mediaOriginalName,
    localMediaBytes,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<OutboxEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('backend_origin')) {
      context.handle(
        _backendOriginMeta,
        backendOrigin.isAcceptableOrUnknown(
          data['backend_origin']!,
          _backendOriginMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_backendOriginMeta);
    }
    if (data.containsKey('owner_user_id')) {
      context.handle(
        _ownerUserIdMeta,
        ownerUserId.isAcceptableOrUnknown(
          data['owner_user_id']!,
          _ownerUserIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_ownerUserIdMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('sender_id')) {
      context.handle(
        _senderIdMeta,
        senderId.isAcceptableOrUnknown(data['sender_id']!, _senderIdMeta),
      );
    } else if (isInserting) {
      context.missing(_senderIdMeta);
    }
    if (data.containsKey('sender_name')) {
      context.handle(
        _senderNameMeta,
        senderName.isAcceptableOrUnknown(data['sender_name']!, _senderNameMeta),
      );
    } else if (isInserting) {
      context.missing(_senderNameMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_attemptCountMeta);
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('media_mime_type')) {
      context.handle(
        _mediaMimeTypeMeta,
        mediaMimeType.isAcceptableOrUnknown(
          data['media_mime_type']!,
          _mediaMimeTypeMeta,
        ),
      );
    }
    if (data.containsKey('media_size_bytes')) {
      context.handle(
        _mediaSizeBytesMeta,
        mediaSizeBytes.isAcceptableOrUnknown(
          data['media_size_bytes']!,
          _mediaSizeBytesMeta,
        ),
      );
    }
    if (data.containsKey('remote_bucket')) {
      context.handle(
        _remoteBucketMeta,
        remoteBucket.isAcceptableOrUnknown(
          data['remote_bucket']!,
          _remoteBucketMeta,
        ),
      );
    }
    if (data.containsKey('remote_path')) {
      context.handle(
        _remotePathMeta,
        remotePath.isAcceptableOrUnknown(data['remote_path']!, _remotePathMeta),
      );
    }
    if (data.containsKey('media_width')) {
      context.handle(
        _mediaWidthMeta,
        mediaWidth.isAcceptableOrUnknown(data['media_width']!, _mediaWidthMeta),
      );
    }
    if (data.containsKey('media_height')) {
      context.handle(
        _mediaHeightMeta,
        mediaHeight.isAcceptableOrUnknown(
          data['media_height']!,
          _mediaHeightMeta,
        ),
      );
    }
    if (data.containsKey('media_duration_ms')) {
      context.handle(
        _mediaDurationMsMeta,
        mediaDurationMs.isAcceptableOrUnknown(
          data['media_duration_ms']!,
          _mediaDurationMsMeta,
        ),
      );
    }
    if (data.containsKey('media_waveform')) {
      context.handle(
        _mediaWaveformMeta,
        mediaWaveform.isAcceptableOrUnknown(
          data['media_waveform']!,
          _mediaWaveformMeta,
        ),
      );
    }
    if (data.containsKey('media_original_name')) {
      context.handle(
        _mediaOriginalNameMeta,
        mediaOriginalName.isAcceptableOrUnknown(
          data['media_original_name']!,
          _mediaOriginalNameMeta,
        ),
      );
    }
    if (data.containsKey('local_media_bytes')) {
      context.handle(
        _localMediaBytesMeta,
        localMediaBytes.isAcceptableOrUnknown(
          data['local_media_bytes']!,
          _localMediaBytesMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id, backendOrigin, ownerUserId};
  @override
  OutboxEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OutboxEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      backendOrigin: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}backend_origin'],
      )!,
      ownerUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner_user_id'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      senderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_id'],
      )!,
      senderName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_name'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}next_attempt_at'],
      ),
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      mediaMimeType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_mime_type'],
      ),
      mediaSizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}media_size_bytes'],
      ),
      remoteBucket: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_bucket'],
      ),
      remotePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_path'],
      ),
      mediaWidth: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}media_width'],
      ),
      mediaHeight: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}media_height'],
      ),
      mediaDurationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}media_duration_ms'],
      ),
      mediaWaveform: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_waveform'],
      ),
      mediaOriginalName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_original_name'],
      ),
      localMediaBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}local_media_bytes'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $OutboxEntriesTable createAlias(String alias) {
    return $OutboxEntriesTable(attachedDatabase, alias);
  }
}

class OutboxEntry extends DataClass implements Insertable<OutboxEntry> {
  final String id;
  final String backendOrigin;
  final String ownerUserId;
  final String conversationId;
  final String senderId;
  final String senderName;
  final String body;
  final DateTime createdAt;
  final String status;
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? lastError;
  final String? mediaMimeType;
  final int? mediaSizeBytes;
  final String? remoteBucket;
  final String? remotePath;
  final int? mediaWidth;
  final int? mediaHeight;
  final int? mediaDurationMs;
  final String? mediaWaveform;
  final String? mediaOriginalName;
  final Uint8List? localMediaBytes;
  final DateTime updatedAt;
  const OutboxEntry({
    required this.id,
    required this.backendOrigin,
    required this.ownerUserId,
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    required this.body,
    required this.createdAt,
    required this.status,
    required this.attemptCount,
    this.nextAttemptAt,
    this.lastError,
    this.mediaMimeType,
    this.mediaSizeBytes,
    this.remoteBucket,
    this.remotePath,
    this.mediaWidth,
    this.mediaHeight,
    this.mediaDurationMs,
    this.mediaWaveform,
    this.mediaOriginalName,
    this.localMediaBytes,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['backend_origin'] = Variable<String>(backendOrigin);
    map['owner_user_id'] = Variable<String>(ownerUserId);
    map['conversation_id'] = Variable<String>(conversationId);
    map['sender_id'] = Variable<String>(senderId);
    map['sender_name'] = Variable<String>(senderName);
    map['body'] = Variable<String>(body);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['status'] = Variable<String>(status);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt);
    }
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    if (!nullToAbsent || mediaMimeType != null) {
      map['media_mime_type'] = Variable<String>(mediaMimeType);
    }
    if (!nullToAbsent || mediaSizeBytes != null) {
      map['media_size_bytes'] = Variable<int>(mediaSizeBytes);
    }
    if (!nullToAbsent || remoteBucket != null) {
      map['remote_bucket'] = Variable<String>(remoteBucket);
    }
    if (!nullToAbsent || remotePath != null) {
      map['remote_path'] = Variable<String>(remotePath);
    }
    if (!nullToAbsent || mediaWidth != null) {
      map['media_width'] = Variable<int>(mediaWidth);
    }
    if (!nullToAbsent || mediaHeight != null) {
      map['media_height'] = Variable<int>(mediaHeight);
    }
    if (!nullToAbsent || mediaDurationMs != null) {
      map['media_duration_ms'] = Variable<int>(mediaDurationMs);
    }
    if (!nullToAbsent || mediaWaveform != null) {
      map['media_waveform'] = Variable<String>(mediaWaveform);
    }
    if (!nullToAbsent || mediaOriginalName != null) {
      map['media_original_name'] = Variable<String>(mediaOriginalName);
    }
    if (!nullToAbsent || localMediaBytes != null) {
      map['local_media_bytes'] = Variable<Uint8List>(localMediaBytes);
    }
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  OutboxEntriesCompanion toCompanion(bool nullToAbsent) {
    return OutboxEntriesCompanion(
      id: Value(id),
      backendOrigin: Value(backendOrigin),
      ownerUserId: Value(ownerUserId),
      conversationId: Value(conversationId),
      senderId: Value(senderId),
      senderName: Value(senderName),
      body: Value(body),
      createdAt: Value(createdAt),
      status: Value(status),
      attemptCount: Value(attemptCount),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      mediaMimeType: mediaMimeType == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaMimeType),
      mediaSizeBytes: mediaSizeBytes == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaSizeBytes),
      remoteBucket: remoteBucket == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteBucket),
      remotePath: remotePath == null && nullToAbsent
          ? const Value.absent()
          : Value(remotePath),
      mediaWidth: mediaWidth == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaWidth),
      mediaHeight: mediaHeight == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaHeight),
      mediaDurationMs: mediaDurationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaDurationMs),
      mediaWaveform: mediaWaveform == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaWaveform),
      mediaOriginalName: mediaOriginalName == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaOriginalName),
      localMediaBytes: localMediaBytes == null && nullToAbsent
          ? const Value.absent()
          : Value(localMediaBytes),
      updatedAt: Value(updatedAt),
    );
  }

  factory OutboxEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OutboxEntry(
      id: serializer.fromJson<String>(json['id']),
      backendOrigin: serializer.fromJson<String>(json['backendOrigin']),
      ownerUserId: serializer.fromJson<String>(json['ownerUserId']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      senderId: serializer.fromJson<String>(json['senderId']),
      senderName: serializer.fromJson<String>(json['senderName']),
      body: serializer.fromJson<String>(json['body']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      status: serializer.fromJson<String>(json['status']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      nextAttemptAt: serializer.fromJson<DateTime?>(json['nextAttemptAt']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      mediaMimeType: serializer.fromJson<String?>(json['mediaMimeType']),
      mediaSizeBytes: serializer.fromJson<int?>(json['mediaSizeBytes']),
      remoteBucket: serializer.fromJson<String?>(json['remoteBucket']),
      remotePath: serializer.fromJson<String?>(json['remotePath']),
      mediaWidth: serializer.fromJson<int?>(json['mediaWidth']),
      mediaHeight: serializer.fromJson<int?>(json['mediaHeight']),
      mediaDurationMs: serializer.fromJson<int?>(json['mediaDurationMs']),
      mediaWaveform: serializer.fromJson<String?>(json['mediaWaveform']),
      mediaOriginalName: serializer.fromJson<String?>(
        json['mediaOriginalName'],
      ),
      localMediaBytes: serializer.fromJson<Uint8List?>(json['localMediaBytes']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'backendOrigin': serializer.toJson<String>(backendOrigin),
      'ownerUserId': serializer.toJson<String>(ownerUserId),
      'conversationId': serializer.toJson<String>(conversationId),
      'senderId': serializer.toJson<String>(senderId),
      'senderName': serializer.toJson<String>(senderName),
      'body': serializer.toJson<String>(body),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'status': serializer.toJson<String>(status),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'nextAttemptAt': serializer.toJson<DateTime?>(nextAttemptAt),
      'lastError': serializer.toJson<String?>(lastError),
      'mediaMimeType': serializer.toJson<String?>(mediaMimeType),
      'mediaSizeBytes': serializer.toJson<int?>(mediaSizeBytes),
      'remoteBucket': serializer.toJson<String?>(remoteBucket),
      'remotePath': serializer.toJson<String?>(remotePath),
      'mediaWidth': serializer.toJson<int?>(mediaWidth),
      'mediaHeight': serializer.toJson<int?>(mediaHeight),
      'mediaDurationMs': serializer.toJson<int?>(mediaDurationMs),
      'mediaWaveform': serializer.toJson<String?>(mediaWaveform),
      'mediaOriginalName': serializer.toJson<String?>(mediaOriginalName),
      'localMediaBytes': serializer.toJson<Uint8List?>(localMediaBytes),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  OutboxEntry copyWith({
    String? id,
    String? backendOrigin,
    String? ownerUserId,
    String? conversationId,
    String? senderId,
    String? senderName,
    String? body,
    DateTime? createdAt,
    String? status,
    int? attemptCount,
    Value<DateTime?> nextAttemptAt = const Value.absent(),
    Value<String?> lastError = const Value.absent(),
    Value<String?> mediaMimeType = const Value.absent(),
    Value<int?> mediaSizeBytes = const Value.absent(),
    Value<String?> remoteBucket = const Value.absent(),
    Value<String?> remotePath = const Value.absent(),
    Value<int?> mediaWidth = const Value.absent(),
    Value<int?> mediaHeight = const Value.absent(),
    Value<int?> mediaDurationMs = const Value.absent(),
    Value<String?> mediaWaveform = const Value.absent(),
    Value<String?> mediaOriginalName = const Value.absent(),
    Value<Uint8List?> localMediaBytes = const Value.absent(),
    DateTime? updatedAt,
  }) => OutboxEntry(
    id: id ?? this.id,
    backendOrigin: backendOrigin ?? this.backendOrigin,
    ownerUserId: ownerUserId ?? this.ownerUserId,
    conversationId: conversationId ?? this.conversationId,
    senderId: senderId ?? this.senderId,
    senderName: senderName ?? this.senderName,
    body: body ?? this.body,
    createdAt: createdAt ?? this.createdAt,
    status: status ?? this.status,
    attemptCount: attemptCount ?? this.attemptCount,
    nextAttemptAt: nextAttemptAt.present
        ? nextAttemptAt.value
        : this.nextAttemptAt,
    lastError: lastError.present ? lastError.value : this.lastError,
    mediaMimeType: mediaMimeType.present
        ? mediaMimeType.value
        : this.mediaMimeType,
    mediaSizeBytes: mediaSizeBytes.present
        ? mediaSizeBytes.value
        : this.mediaSizeBytes,
    remoteBucket: remoteBucket.present ? remoteBucket.value : this.remoteBucket,
    remotePath: remotePath.present ? remotePath.value : this.remotePath,
    mediaWidth: mediaWidth.present ? mediaWidth.value : this.mediaWidth,
    mediaHeight: mediaHeight.present ? mediaHeight.value : this.mediaHeight,
    mediaDurationMs: mediaDurationMs.present
        ? mediaDurationMs.value
        : this.mediaDurationMs,
    mediaWaveform: mediaWaveform.present
        ? mediaWaveform.value
        : this.mediaWaveform,
    mediaOriginalName: mediaOriginalName.present
        ? mediaOriginalName.value
        : this.mediaOriginalName,
    localMediaBytes: localMediaBytes.present
        ? localMediaBytes.value
        : this.localMediaBytes,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  OutboxEntry copyWithCompanion(OutboxEntriesCompanion data) {
    return OutboxEntry(
      id: data.id.present ? data.id.value : this.id,
      backendOrigin: data.backendOrigin.present
          ? data.backendOrigin.value
          : this.backendOrigin,
      ownerUserId: data.ownerUserId.present
          ? data.ownerUserId.value
          : this.ownerUserId,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      senderId: data.senderId.present ? data.senderId.value : this.senderId,
      senderName: data.senderName.present
          ? data.senderName.value
          : this.senderName,
      body: data.body.present ? data.body.value : this.body,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      status: data.status.present ? data.status.value : this.status,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      mediaMimeType: data.mediaMimeType.present
          ? data.mediaMimeType.value
          : this.mediaMimeType,
      mediaSizeBytes: data.mediaSizeBytes.present
          ? data.mediaSizeBytes.value
          : this.mediaSizeBytes,
      remoteBucket: data.remoteBucket.present
          ? data.remoteBucket.value
          : this.remoteBucket,
      remotePath: data.remotePath.present
          ? data.remotePath.value
          : this.remotePath,
      mediaWidth: data.mediaWidth.present
          ? data.mediaWidth.value
          : this.mediaWidth,
      mediaHeight: data.mediaHeight.present
          ? data.mediaHeight.value
          : this.mediaHeight,
      mediaDurationMs: data.mediaDurationMs.present
          ? data.mediaDurationMs.value
          : this.mediaDurationMs,
      mediaWaveform: data.mediaWaveform.present
          ? data.mediaWaveform.value
          : this.mediaWaveform,
      mediaOriginalName: data.mediaOriginalName.present
          ? data.mediaOriginalName.value
          : this.mediaOriginalName,
      localMediaBytes: data.localMediaBytes.present
          ? data.localMediaBytes.value
          : this.localMediaBytes,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OutboxEntry(')
          ..write('id: $id, ')
          ..write('backendOrigin: $backendOrigin, ')
          ..write('ownerUserId: $ownerUserId, ')
          ..write('conversationId: $conversationId, ')
          ..write('senderId: $senderId, ')
          ..write('senderName: $senderName, ')
          ..write('body: $body, ')
          ..write('createdAt: $createdAt, ')
          ..write('status: $status, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastError: $lastError, ')
          ..write('mediaMimeType: $mediaMimeType, ')
          ..write('mediaSizeBytes: $mediaSizeBytes, ')
          ..write('remoteBucket: $remoteBucket, ')
          ..write('remotePath: $remotePath, ')
          ..write('mediaWidth: $mediaWidth, ')
          ..write('mediaHeight: $mediaHeight, ')
          ..write('mediaDurationMs: $mediaDurationMs, ')
          ..write('mediaWaveform: $mediaWaveform, ')
          ..write('mediaOriginalName: $mediaOriginalName, ')
          ..write('localMediaBytes: $localMediaBytes, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    backendOrigin,
    ownerUserId,
    conversationId,
    senderId,
    senderName,
    body,
    createdAt,
    status,
    attemptCount,
    nextAttemptAt,
    lastError,
    mediaMimeType,
    mediaSizeBytes,
    remoteBucket,
    remotePath,
    mediaWidth,
    mediaHeight,
    mediaDurationMs,
    mediaWaveform,
    mediaOriginalName,
    $driftBlobEquality.hash(localMediaBytes),
    updatedAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OutboxEntry &&
          other.id == this.id &&
          other.backendOrigin == this.backendOrigin &&
          other.ownerUserId == this.ownerUserId &&
          other.conversationId == this.conversationId &&
          other.senderId == this.senderId &&
          other.senderName == this.senderName &&
          other.body == this.body &&
          other.createdAt == this.createdAt &&
          other.status == this.status &&
          other.attemptCount == this.attemptCount &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.lastError == this.lastError &&
          other.mediaMimeType == this.mediaMimeType &&
          other.mediaSizeBytes == this.mediaSizeBytes &&
          other.remoteBucket == this.remoteBucket &&
          other.remotePath == this.remotePath &&
          other.mediaWidth == this.mediaWidth &&
          other.mediaHeight == this.mediaHeight &&
          other.mediaDurationMs == this.mediaDurationMs &&
          other.mediaWaveform == this.mediaWaveform &&
          other.mediaOriginalName == this.mediaOriginalName &&
          $driftBlobEquality.equals(
            other.localMediaBytes,
            this.localMediaBytes,
          ) &&
          other.updatedAt == this.updatedAt);
}

class OutboxEntriesCompanion extends UpdateCompanion<OutboxEntry> {
  final Value<String> id;
  final Value<String> backendOrigin;
  final Value<String> ownerUserId;
  final Value<String> conversationId;
  final Value<String> senderId;
  final Value<String> senderName;
  final Value<String> body;
  final Value<DateTime> createdAt;
  final Value<String> status;
  final Value<int> attemptCount;
  final Value<DateTime?> nextAttemptAt;
  final Value<String?> lastError;
  final Value<String?> mediaMimeType;
  final Value<int?> mediaSizeBytes;
  final Value<String?> remoteBucket;
  final Value<String?> remotePath;
  final Value<int?> mediaWidth;
  final Value<int?> mediaHeight;
  final Value<int?> mediaDurationMs;
  final Value<String?> mediaWaveform;
  final Value<String?> mediaOriginalName;
  final Value<Uint8List?> localMediaBytes;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const OutboxEntriesCompanion({
    this.id = const Value.absent(),
    this.backendOrigin = const Value.absent(),
    this.ownerUserId = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.senderId = const Value.absent(),
    this.senderName = const Value.absent(),
    this.body = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.status = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastError = const Value.absent(),
    this.mediaMimeType = const Value.absent(),
    this.mediaSizeBytes = const Value.absent(),
    this.remoteBucket = const Value.absent(),
    this.remotePath = const Value.absent(),
    this.mediaWidth = const Value.absent(),
    this.mediaHeight = const Value.absent(),
    this.mediaDurationMs = const Value.absent(),
    this.mediaWaveform = const Value.absent(),
    this.mediaOriginalName = const Value.absent(),
    this.localMediaBytes = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OutboxEntriesCompanion.insert({
    required String id,
    required String backendOrigin,
    required String ownerUserId,
    required String conversationId,
    required String senderId,
    required String senderName,
    required String body,
    required DateTime createdAt,
    required String status,
    required int attemptCount,
    this.nextAttemptAt = const Value.absent(),
    this.lastError = const Value.absent(),
    this.mediaMimeType = const Value.absent(),
    this.mediaSizeBytes = const Value.absent(),
    this.remoteBucket = const Value.absent(),
    this.remotePath = const Value.absent(),
    this.mediaWidth = const Value.absent(),
    this.mediaHeight = const Value.absent(),
    this.mediaDurationMs = const Value.absent(),
    this.mediaWaveform = const Value.absent(),
    this.mediaOriginalName = const Value.absent(),
    this.localMediaBytes = const Value.absent(),
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       backendOrigin = Value(backendOrigin),
       ownerUserId = Value(ownerUserId),
       conversationId = Value(conversationId),
       senderId = Value(senderId),
       senderName = Value(senderName),
       body = Value(body),
       createdAt = Value(createdAt),
       status = Value(status),
       attemptCount = Value(attemptCount),
       updatedAt = Value(updatedAt);
  static Insertable<OutboxEntry> custom({
    Expression<String>? id,
    Expression<String>? backendOrigin,
    Expression<String>? ownerUserId,
    Expression<String>? conversationId,
    Expression<String>? senderId,
    Expression<String>? senderName,
    Expression<String>? body,
    Expression<DateTime>? createdAt,
    Expression<String>? status,
    Expression<int>? attemptCount,
    Expression<DateTime>? nextAttemptAt,
    Expression<String>? lastError,
    Expression<String>? mediaMimeType,
    Expression<int>? mediaSizeBytes,
    Expression<String>? remoteBucket,
    Expression<String>? remotePath,
    Expression<int>? mediaWidth,
    Expression<int>? mediaHeight,
    Expression<int>? mediaDurationMs,
    Expression<String>? mediaWaveform,
    Expression<String>? mediaOriginalName,
    Expression<Uint8List>? localMediaBytes,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (backendOrigin != null) 'backend_origin': backendOrigin,
      if (ownerUserId != null) 'owner_user_id': ownerUserId,
      if (conversationId != null) 'conversation_id': conversationId,
      if (senderId != null) 'sender_id': senderId,
      if (senderName != null) 'sender_name': senderName,
      if (body != null) 'body': body,
      if (createdAt != null) 'created_at': createdAt,
      if (status != null) 'status': status,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (lastError != null) 'last_error': lastError,
      if (mediaMimeType != null) 'media_mime_type': mediaMimeType,
      if (mediaSizeBytes != null) 'media_size_bytes': mediaSizeBytes,
      if (remoteBucket != null) 'remote_bucket': remoteBucket,
      if (remotePath != null) 'remote_path': remotePath,
      if (mediaWidth != null) 'media_width': mediaWidth,
      if (mediaHeight != null) 'media_height': mediaHeight,
      if (mediaDurationMs != null) 'media_duration_ms': mediaDurationMs,
      if (mediaWaveform != null) 'media_waveform': mediaWaveform,
      if (mediaOriginalName != null) 'media_original_name': mediaOriginalName,
      if (localMediaBytes != null) 'local_media_bytes': localMediaBytes,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OutboxEntriesCompanion copyWith({
    Value<String>? id,
    Value<String>? backendOrigin,
    Value<String>? ownerUserId,
    Value<String>? conversationId,
    Value<String>? senderId,
    Value<String>? senderName,
    Value<String>? body,
    Value<DateTime>? createdAt,
    Value<String>? status,
    Value<int>? attemptCount,
    Value<DateTime?>? nextAttemptAt,
    Value<String?>? lastError,
    Value<String?>? mediaMimeType,
    Value<int?>? mediaSizeBytes,
    Value<String?>? remoteBucket,
    Value<String?>? remotePath,
    Value<int?>? mediaWidth,
    Value<int?>? mediaHeight,
    Value<int?>? mediaDurationMs,
    Value<String?>? mediaWaveform,
    Value<String?>? mediaOriginalName,
    Value<Uint8List?>? localMediaBytes,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return OutboxEntriesCompanion(
      id: id ?? this.id,
      backendOrigin: backendOrigin ?? this.backendOrigin,
      ownerUserId: ownerUserId ?? this.ownerUserId,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      lastError: lastError ?? this.lastError,
      mediaMimeType: mediaMimeType ?? this.mediaMimeType,
      mediaSizeBytes: mediaSizeBytes ?? this.mediaSizeBytes,
      remoteBucket: remoteBucket ?? this.remoteBucket,
      remotePath: remotePath ?? this.remotePath,
      mediaWidth: mediaWidth ?? this.mediaWidth,
      mediaHeight: mediaHeight ?? this.mediaHeight,
      mediaDurationMs: mediaDurationMs ?? this.mediaDurationMs,
      mediaWaveform: mediaWaveform ?? this.mediaWaveform,
      mediaOriginalName: mediaOriginalName ?? this.mediaOriginalName,
      localMediaBytes: localMediaBytes ?? this.localMediaBytes,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (backendOrigin.present) {
      map['backend_origin'] = Variable<String>(backendOrigin.value);
    }
    if (ownerUserId.present) {
      map['owner_user_id'] = Variable<String>(ownerUserId.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (senderId.present) {
      map['sender_id'] = Variable<String>(senderId.value);
    }
    if (senderName.present) {
      map['sender_name'] = Variable<String>(senderName.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (mediaMimeType.present) {
      map['media_mime_type'] = Variable<String>(mediaMimeType.value);
    }
    if (mediaSizeBytes.present) {
      map['media_size_bytes'] = Variable<int>(mediaSizeBytes.value);
    }
    if (remoteBucket.present) {
      map['remote_bucket'] = Variable<String>(remoteBucket.value);
    }
    if (remotePath.present) {
      map['remote_path'] = Variable<String>(remotePath.value);
    }
    if (mediaWidth.present) {
      map['media_width'] = Variable<int>(mediaWidth.value);
    }
    if (mediaHeight.present) {
      map['media_height'] = Variable<int>(mediaHeight.value);
    }
    if (mediaDurationMs.present) {
      map['media_duration_ms'] = Variable<int>(mediaDurationMs.value);
    }
    if (mediaWaveform.present) {
      map['media_waveform'] = Variable<String>(mediaWaveform.value);
    }
    if (mediaOriginalName.present) {
      map['media_original_name'] = Variable<String>(mediaOriginalName.value);
    }
    if (localMediaBytes.present) {
      map['local_media_bytes'] = Variable<Uint8List>(localMediaBytes.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OutboxEntriesCompanion(')
          ..write('id: $id, ')
          ..write('backendOrigin: $backendOrigin, ')
          ..write('ownerUserId: $ownerUserId, ')
          ..write('conversationId: $conversationId, ')
          ..write('senderId: $senderId, ')
          ..write('senderName: $senderName, ')
          ..write('body: $body, ')
          ..write('createdAt: $createdAt, ')
          ..write('status: $status, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastError: $lastError, ')
          ..write('mediaMimeType: $mediaMimeType, ')
          ..write('mediaSizeBytes: $mediaSizeBytes, ')
          ..write('remoteBucket: $remoteBucket, ')
          ..write('remotePath: $remotePath, ')
          ..write('mediaWidth: $mediaWidth, ')
          ..write('mediaHeight: $mediaHeight, ')
          ..write('mediaDurationMs: $mediaDurationMs, ')
          ..write('mediaWaveform: $mediaWaveform, ')
          ..write('mediaOriginalName: $mediaOriginalName, ')
          ..write('localMediaBytes: $localMediaBytes, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$OutboxDatabase extends GeneratedDatabase {
  _$OutboxDatabase(QueryExecutor e) : super(e);
  $OutboxDatabaseManager get managers => $OutboxDatabaseManager(this);
  late final $OutboxEntriesTable outboxEntries = $OutboxEntriesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [outboxEntries];
}

typedef $$OutboxEntriesTableCreateCompanionBuilder =
    OutboxEntriesCompanion Function({
      required String id,
      required String backendOrigin,
      required String ownerUserId,
      required String conversationId,
      required String senderId,
      required String senderName,
      required String body,
      required DateTime createdAt,
      required String status,
      required int attemptCount,
      Value<DateTime?> nextAttemptAt,
      Value<String?> lastError,
      Value<String?> mediaMimeType,
      Value<int?> mediaSizeBytes,
      Value<String?> remoteBucket,
      Value<String?> remotePath,
      Value<int?> mediaWidth,
      Value<int?> mediaHeight,
      Value<int?> mediaDurationMs,
      Value<String?> mediaWaveform,
      Value<String?> mediaOriginalName,
      Value<Uint8List?> localMediaBytes,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$OutboxEntriesTableUpdateCompanionBuilder =
    OutboxEntriesCompanion Function({
      Value<String> id,
      Value<String> backendOrigin,
      Value<String> ownerUserId,
      Value<String> conversationId,
      Value<String> senderId,
      Value<String> senderName,
      Value<String> body,
      Value<DateTime> createdAt,
      Value<String> status,
      Value<int> attemptCount,
      Value<DateTime?> nextAttemptAt,
      Value<String?> lastError,
      Value<String?> mediaMimeType,
      Value<int?> mediaSizeBytes,
      Value<String?> remoteBucket,
      Value<String?> remotePath,
      Value<int?> mediaWidth,
      Value<int?> mediaHeight,
      Value<int?> mediaDurationMs,
      Value<String?> mediaWaveform,
      Value<String?> mediaOriginalName,
      Value<Uint8List?> localMediaBytes,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$OutboxEntriesTableFilterComposer
    extends Composer<_$OutboxDatabase, $OutboxEntriesTable> {
  $$OutboxEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get backendOrigin => $composableBuilder(
    column: $table.backendOrigin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderName => $composableBuilder(
    column: $table.senderName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaMimeType => $composableBuilder(
    column: $table.mediaMimeType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mediaSizeBytes => $composableBuilder(
    column: $table.mediaSizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteBucket => $composableBuilder(
    column: $table.remoteBucket,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remotePath => $composableBuilder(
    column: $table.remotePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mediaWidth => $composableBuilder(
    column: $table.mediaWidth,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mediaHeight => $composableBuilder(
    column: $table.mediaHeight,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mediaDurationMs => $composableBuilder(
    column: $table.mediaDurationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaWaveform => $composableBuilder(
    column: $table.mediaWaveform,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaOriginalName => $composableBuilder(
    column: $table.mediaOriginalName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get localMediaBytes => $composableBuilder(
    column: $table.localMediaBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OutboxEntriesTableOrderingComposer
    extends Composer<_$OutboxDatabase, $OutboxEntriesTable> {
  $$OutboxEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get backendOrigin => $composableBuilder(
    column: $table.backendOrigin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderName => $composableBuilder(
    column: $table.senderName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaMimeType => $composableBuilder(
    column: $table.mediaMimeType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mediaSizeBytes => $composableBuilder(
    column: $table.mediaSizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteBucket => $composableBuilder(
    column: $table.remoteBucket,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remotePath => $composableBuilder(
    column: $table.remotePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mediaWidth => $composableBuilder(
    column: $table.mediaWidth,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mediaHeight => $composableBuilder(
    column: $table.mediaHeight,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mediaDurationMs => $composableBuilder(
    column: $table.mediaDurationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaWaveform => $composableBuilder(
    column: $table.mediaWaveform,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaOriginalName => $composableBuilder(
    column: $table.mediaOriginalName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get localMediaBytes => $composableBuilder(
    column: $table.localMediaBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OutboxEntriesTableAnnotationComposer
    extends Composer<_$OutboxDatabase, $OutboxEntriesTable> {
  $$OutboxEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get backendOrigin => $composableBuilder(
    column: $table.backendOrigin,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ownerUserId => $composableBuilder(
    column: $table.ownerUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get senderId =>
      $composableBuilder(column: $table.senderId, builder: (column) => column);

  GeneratedColumn<String> get senderName => $composableBuilder(
    column: $table.senderName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<String> get mediaMimeType => $composableBuilder(
    column: $table.mediaMimeType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get mediaSizeBytes => $composableBuilder(
    column: $table.mediaSizeBytes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remoteBucket => $composableBuilder(
    column: $table.remoteBucket,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remotePath => $composableBuilder(
    column: $table.remotePath,
    builder: (column) => column,
  );

  GeneratedColumn<int> get mediaWidth => $composableBuilder(
    column: $table.mediaWidth,
    builder: (column) => column,
  );

  GeneratedColumn<int> get mediaHeight => $composableBuilder(
    column: $table.mediaHeight,
    builder: (column) => column,
  );

  GeneratedColumn<int> get mediaDurationMs => $composableBuilder(
    column: $table.mediaDurationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mediaWaveform => $composableBuilder(
    column: $table.mediaWaveform,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mediaOriginalName => $composableBuilder(
    column: $table.mediaOriginalName,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get localMediaBytes => $composableBuilder(
    column: $table.localMediaBytes,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$OutboxEntriesTableTableManager
    extends
        RootTableManager<
          _$OutboxDatabase,
          $OutboxEntriesTable,
          OutboxEntry,
          $$OutboxEntriesTableFilterComposer,
          $$OutboxEntriesTableOrderingComposer,
          $$OutboxEntriesTableAnnotationComposer,
          $$OutboxEntriesTableCreateCompanionBuilder,
          $$OutboxEntriesTableUpdateCompanionBuilder,
          (
            OutboxEntry,
            BaseReferences<_$OutboxDatabase, $OutboxEntriesTable, OutboxEntry>,
          ),
          OutboxEntry,
          PrefetchHooks Function()
        > {
  $$OutboxEntriesTableTableManager(
    _$OutboxDatabase db,
    $OutboxEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OutboxEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OutboxEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OutboxEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> backendOrigin = const Value.absent(),
                Value<String> ownerUserId = const Value.absent(),
                Value<String> conversationId = const Value.absent(),
                Value<String> senderId = const Value.absent(),
                Value<String> senderName = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<String?> mediaMimeType = const Value.absent(),
                Value<int?> mediaSizeBytes = const Value.absent(),
                Value<String?> remoteBucket = const Value.absent(),
                Value<String?> remotePath = const Value.absent(),
                Value<int?> mediaWidth = const Value.absent(),
                Value<int?> mediaHeight = const Value.absent(),
                Value<int?> mediaDurationMs = const Value.absent(),
                Value<String?> mediaWaveform = const Value.absent(),
                Value<String?> mediaOriginalName = const Value.absent(),
                Value<Uint8List?> localMediaBytes = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OutboxEntriesCompanion(
                id: id,
                backendOrigin: backendOrigin,
                ownerUserId: ownerUserId,
                conversationId: conversationId,
                senderId: senderId,
                senderName: senderName,
                body: body,
                createdAt: createdAt,
                status: status,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                lastError: lastError,
                mediaMimeType: mediaMimeType,
                mediaSizeBytes: mediaSizeBytes,
                remoteBucket: remoteBucket,
                remotePath: remotePath,
                mediaWidth: mediaWidth,
                mediaHeight: mediaHeight,
                mediaDurationMs: mediaDurationMs,
                mediaWaveform: mediaWaveform,
                mediaOriginalName: mediaOriginalName,
                localMediaBytes: localMediaBytes,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String backendOrigin,
                required String ownerUserId,
                required String conversationId,
                required String senderId,
                required String senderName,
                required String body,
                required DateTime createdAt,
                required String status,
                required int attemptCount,
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<String?> mediaMimeType = const Value.absent(),
                Value<int?> mediaSizeBytes = const Value.absent(),
                Value<String?> remoteBucket = const Value.absent(),
                Value<String?> remotePath = const Value.absent(),
                Value<int?> mediaWidth = const Value.absent(),
                Value<int?> mediaHeight = const Value.absent(),
                Value<int?> mediaDurationMs = const Value.absent(),
                Value<String?> mediaWaveform = const Value.absent(),
                Value<String?> mediaOriginalName = const Value.absent(),
                Value<Uint8List?> localMediaBytes = const Value.absent(),
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => OutboxEntriesCompanion.insert(
                id: id,
                backendOrigin: backendOrigin,
                ownerUserId: ownerUserId,
                conversationId: conversationId,
                senderId: senderId,
                senderName: senderName,
                body: body,
                createdAt: createdAt,
                status: status,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                lastError: lastError,
                mediaMimeType: mediaMimeType,
                mediaSizeBytes: mediaSizeBytes,
                remoteBucket: remoteBucket,
                remotePath: remotePath,
                mediaWidth: mediaWidth,
                mediaHeight: mediaHeight,
                mediaDurationMs: mediaDurationMs,
                mediaWaveform: mediaWaveform,
                mediaOriginalName: mediaOriginalName,
                localMediaBytes: localMediaBytes,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OutboxEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$OutboxDatabase,
      $OutboxEntriesTable,
      OutboxEntry,
      $$OutboxEntriesTableFilterComposer,
      $$OutboxEntriesTableOrderingComposer,
      $$OutboxEntriesTableAnnotationComposer,
      $$OutboxEntriesTableCreateCompanionBuilder,
      $$OutboxEntriesTableUpdateCompanionBuilder,
      (
        OutboxEntry,
        BaseReferences<_$OutboxDatabase, $OutboxEntriesTable, OutboxEntry>,
      ),
      OutboxEntry,
      PrefetchHooks Function()
    >;

class $OutboxDatabaseManager {
  final _$OutboxDatabase _db;
  $OutboxDatabaseManager(this._db);
  $$OutboxEntriesTableTableManager get outboxEntries =>
      $$OutboxEntriesTableTableManager(_db, _db.outboxEntries);
}
