import 'dart:typed_data';

import 'package:flutter/material.dart';

class UserPresence {
  const UserPresence({
    required this.userId,
    required this.isOnline,
    this.displayName,
    this.lastSeenAt,
  });

  final String userId;
  final bool isOnline;
  final String? displayName;
  final DateTime? lastSeenAt;
}

class TypingState {
  const TypingState({
    required this.conversationId,
    required this.userId,
    required this.displayName,
    required this.isTyping,
  });

  final String conversationId;
  final String userId;
  final String displayName;
  final bool isTyping;

  factory TypingState.idle(String conversationId) {
    return TypingState(
      conversationId: conversationId,
      userId: '',
      displayName: '',
      isTyping: false,
    );
  }
}

class MessageReceipt {
  const MessageReceipt({
    required this.messageId,
    required this.userId,
    this.deliveredAt,
    this.readAt,
  });

  final String messageId;
  final String userId;
  final DateTime? deliveredAt;
  final DateTime? readAt;

  bool get isDelivered => deliveredAt != null || readAt != null;
  bool get isRead => readAt != null;

  factory MessageReceipt.fromSupabase(Map<String, dynamic> row) {
    return MessageReceipt(
      messageId: row['message_id']?.toString() ?? '',
      userId: row['user_id']?.toString() ?? '',
      deliveredAt: _readOptionalTimestamp(row['delivered_at']),
      readAt: _readOptionalTimestamp(row['read_at']),
    );
  }
}

class ChatThread {
  const ChatThread({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.avatarLabel,
    required this.accentColor,
    required this.lastActive,
    required this.unreadCount,
    required this.isOnline,
    required this.activityLabel,
    this.peerUserId,
    this.peerLastSeenAt,
    this.isTyping = false,
    this.typingUserName,
  });

  final String id;
  final String title;
  final String subtitle;
  final String avatarLabel;
  final Color accentColor;
  final String lastActive;
  final int unreadCount;
  final bool isOnline;
  final String activityLabel;
  final String? peerUserId;
  final DateTime? peerLastSeenAt;
  final bool isTyping;
  final String? typingUserName;

  String get displaySubtitle {
    if (!isTyping) {
      return subtitle;
    }

    final name = typingUserName?.trim();
    return '${name == null || name.isEmpty ? title : name} is typing...';
  }

  ChatThread copyWith({
    String? title,
    String? avatarLabel,
    String? subtitle,
    String? lastActive,
    int? unreadCount,
    bool? isOnline,
    String? activityLabel,
    DateTime? peerLastSeenAt,
    bool? isTyping,
    String? typingUserName,
  }) {
    final nextIsTyping = isTyping ?? this.isTyping;

    return ChatThread(
      id: id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      avatarLabel: avatarLabel ?? this.avatarLabel,
      accentColor: accentColor,
      lastActive: lastActive ?? this.lastActive,
      unreadCount: unreadCount ?? this.unreadCount,
      isOnline: isOnline ?? this.isOnline,
      activityLabel: activityLabel ?? this.activityLabel,
      peerUserId: peerUserId,
      peerLastSeenAt: peerLastSeenAt ?? this.peerLastSeenAt,
      isTyping: nextIsTyping,
      typingUserName: nextIsTyping
          ? typingUserName ?? this.typingUserName
          : null,
    );
  }
}

class ChatUser {
  const ChatUser({
    required this.id,
    required this.displayName,
    this.email,
    this.lastSeenAt,
  });

  final String id;
  final String displayName;
  final String? email;
  final DateTime? lastSeenAt;

  String get avatarLabel {
    final parts = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();

    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    if (parts.isNotEmpty) {
      return parts.first.characters.take(2).toString().toUpperCase();
    }
    return '?';
  }

  factory ChatUser.fromSupabase(Map<String, dynamic> row) {
    return ChatUser(
      id: row['id']?.toString() ?? '',
      displayName: row['display_name']?.toString() ?? 'Unknown user',
      email: row['email']?.toString(),
      lastSeenAt: _readOptionalTimestamp(row['last_seen_at']),
    );
  }
}

class CurrentUserProfile {
  const CurrentUserProfile({
    required this.id,
    required this.displayName,
    this.email,
    this.phone,
    this.updatedAt,
  });

  final String id;
  final String displayName;
  final String? email;
  final String? phone;
  final DateTime? updatedAt;

  String get avatarLabel {
    final parts = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();

    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    if (parts.isNotEmpty) {
      return parts.first.characters.take(2).toString().toUpperCase();
    }
    return '?';
  }

  factory CurrentUserProfile.local({
    String displayName = 'You',
    String? email,
    String? phone,
    DateTime? updatedAt,
  }) {
    return CurrentUserProfile(
      id: ChatSeed.localUserId,
      displayName: displayName,
      email: email,
      phone: phone,
      updatedAt: updatedAt,
    );
  }

  factory CurrentUserProfile.fromSupabase(
    Map<String, dynamic> row, {
    required String fallbackId,
    required String fallbackDisplayName,
    String? fallbackEmail,
    String? fallbackPhone,
  }) {
    final displayName = row['display_name']?.toString().trim();

    return CurrentUserProfile(
      id: row['id']?.toString() ?? fallbackId,
      displayName: displayName == null || displayName.isEmpty
          ? fallbackDisplayName
          : displayName,
      email: row['email']?.toString() ?? fallbackEmail,
      phone: row['phone']?.toString() ?? fallbackPhone,
      updatedAt: _readOptionalTimestamp(row['updated_at']),
    );
  }
}

enum ChatMessageType {
  text('text'),
  image('image'),
  gif('gif'),
  voice('voice'),
  call('call');

  const ChatMessageType(this.value);

  final String value;

  static ChatMessageType fromValue(String? value, {String? mimeType}) {
    final normalized = value?.trim().toLowerCase();
    for (final type in values) {
      if (type.value == normalized) {
        return type;
      }
    }

    if (mimeType?.toLowerCase() == 'image/gif') {
      return gif;
    }
    if (mimeType?.toLowerCase().startsWith('image/') ?? false) {
      return image;
    }
    if (mimeType?.toLowerCase().startsWith('audio/') ?? false) {
      return voice;
    }
    return text;
  }
}

enum ChatMessageSendState { sent, pending, sending, failed }

enum ChatMediaSource { gallery, camera, giphy }

class GiphyGif {
  const GiphyGif({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.originalUrl,
    this.width,
    this.height,
    this.sizeBytes,
  });

  final String id;
  final String title;
  final String previewUrl;
  final String originalUrl;
  final int? width;
  final int? height;
  final int? sizeBytes;
}

class ChatMedia {
  const ChatMedia({
    required this.bucket,
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
    this.width,
    this.height,
    this.duration,
    this.waveform = const [],
    this.originalName,
    this.localBytes,
  });

  final String bucket;
  final String path;
  final String mimeType;
  final int sizeBytes;
  final int? width;
  final int? height;
  final Duration? duration;
  final List<double> waveform;
  final String? originalName;
  final Uint8List? localBytes;

  bool get isGif => mimeType.toLowerCase() == 'image/gif';
  bool get isVoice => mimeType.toLowerCase().startsWith('audio/');

  String get cacheKey => '$bucket:$path';

  double? get aspectRatio {
    final mediaWidth = width;
    final mediaHeight = height;
    if (mediaWidth == null || mediaHeight == null || mediaHeight == 0) {
      return null;
    }
    return mediaWidth / mediaHeight;
  }

  ChatMedia copyWith({
    String? bucket,
    String? path,
    String? mimeType,
    int? sizeBytes,
    int? width,
    int? height,
    Duration? duration,
    List<double>? waveform,
    String? originalName,
    Uint8List? localBytes,
  }) {
    return ChatMedia(
      bucket: bucket ?? this.bucket,
      path: path ?? this.path,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      width: width ?? this.width,
      height: height ?? this.height,
      duration: duration ?? this.duration,
      waveform: waveform ?? this.waveform,
      originalName: originalName ?? this.originalName,
      localBytes: localBytes ?? this.localBytes,
    );
  }

  factory ChatMedia.fromSupabase(Map<String, dynamic> row) {
    final durationMs = _readOptionalInt(row['media_duration_ms']);
    return ChatMedia(
      bucket: row['media_bucket']?.toString() ?? '',
      path: row['media_path']?.toString() ?? '',
      mimeType: row['media_mime_type']?.toString() ?? 'image/jpeg',
      sizeBytes: _readInt(row['media_size_bytes']),
      width: _readOptionalInt(row['media_width']),
      height: _readOptionalInt(row['media_height']),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      waveform: _readWaveform(row['media_waveform']),
      originalName: row['media_original_name']?.toString(),
    );
  }
}

class PickedChatMedia {
  const PickedChatMedia({
    required this.bytes,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
    this.width,
    this.height,
    this.duration,
    this.waveform = const [],
  });

  final Uint8List bytes;
  final String originalName;
  final String mimeType;
  final int sizeBytes;
  final int? width;
  final int? height;
  final Duration? duration;
  final List<double> waveform;

  bool get isGif => mimeType.toLowerCase() == 'image/gif';
  bool get isVoice => mimeType.toLowerCase().startsWith('audio/');

  ChatMessageType get messageType => isVoice
      ? ChatMessageType.voice
      : isGif
      ? ChatMessageType.gif
      : ChatMessageType.image;
}

class UploadedChatMedia {
  const UploadedChatMedia({required this.messageId, required this.media});

  final String messageId;
  final ChatMedia media;
}

class MessageReplyPreview {
  const MessageReplyPreview({
    required this.messageId,
    required this.senderName,
    required this.preview,
    required this.messageType,
    this.isDeleted = false,
  });

  final String messageId;
  final String senderName;
  final String preview;
  final ChatMessageType messageType;
  final bool isDeleted;

  factory MessageReplyPreview.fromMessage(ChatMessage message) {
    return MessageReplyPreview(
      messageId: message.id,
      senderName: message.senderName,
      preview: message.actionPreview,
      messageType: message.messageType,
      isDeleted: message.isDeleted,
    );
  }
}

class MessageReactionSummary {
  const MessageReactionSummary({
    required this.emoji,
    required this.count,
    required this.reactedByMe,
  });

  final String emoji;
  final int count;
  final bool reactedByMe;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.threadId,
    required this.senderId,
    required this.senderName,
    required this.body,
    required this.createdAt,
    required this.isMine,
    required this.isDelivered,
    required this.isRead,
    this.messageType = ChatMessageType.text,
    this.media,
    this.sendState = ChatMessageSendState.sent,
    this.sendError,
    this.replyTo,
    this.reactions = const [],
    this.isForwarded = false,
    this.editedAt,
    this.deletedAt,
  });

  final String id;
  final String threadId;
  final String senderId;
  final String senderName;
  final String body;
  final DateTime createdAt;
  final bool isMine;
  final bool isDelivered;
  final bool isRead;
  final ChatMessageType messageType;
  final ChatMedia? media;
  final ChatMessageSendState sendState;
  final String? sendError;
  final MessageReplyPreview? replyTo;
  final List<MessageReactionSummary> reactions;
  final bool isForwarded;
  final DateTime? editedAt;
  final DateTime? deletedAt;

  bool get hasMedia => media != null && messageType != ChatMessageType.text;
  bool get isDeleted => deletedAt != null;
  bool get isEdited => editedAt != null && !isDeleted;

  String get actionPreview {
    if (isDeleted) {
      return 'Message deleted';
    }
    final text = body.trim();
    if (text.isNotEmpty) {
      return text;
    }
    return switch (messageType) {
      ChatMessageType.image => 'Photo',
      ChatMessageType.gif => 'GIF',
      ChatMessageType.voice => 'Voice message',
      ChatMessageType.call => 'Call event',
      ChatMessageType.text => 'Message',
    };
  }

  ChatMessage copyWith({
    String? body,
    ChatMessageType? messageType,
    ChatMedia? media,
    MessageReplyPreview? replyTo,
    List<MessageReactionSummary>? reactions,
    bool? isForwarded,
    DateTime? editedAt,
    DateTime? deletedAt,
    bool clearReply = false,
    bool clearMedia = false,
  }) {
    return ChatMessage(
      id: id,
      threadId: threadId,
      senderId: senderId,
      senderName: senderName,
      body: body ?? this.body,
      createdAt: createdAt,
      isMine: isMine,
      isDelivered: isDelivered,
      isRead: isRead,
      messageType: messageType ?? this.messageType,
      media: clearMedia ? null : media ?? this.media,
      sendState: sendState,
      sendError: sendError,
      replyTo: clearReply ? null : replyTo ?? this.replyTo,
      reactions: reactions ?? this.reactions,
      isForwarded: isForwarded ?? this.isForwarded,
      editedAt: editedAt ?? this.editedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  factory ChatMessage.fromSupabase(
    Map<String, dynamic> row, {
    required String localUserId,
    MessageReceipt? receipt,
    MessageReplyPreview? replyTo,
    List<MessageReactionSummary> reactions = const [],
  }) {
    final senderId = row['sender_id']?.toString() ?? '';
    final isMine = senderId == localUserId;
    final isRead = isMine && (receipt?.isRead ?? false);
    final isDelivered = isMine && ((receipt?.isDelivered ?? false) || isRead);
    final deletedAt = _readOptionalTimestamp(row['deleted_at']);
    final mediaPath = row['media_path']?.toString();
    final media = deletedAt != null || mediaPath == null || mediaPath.isEmpty
        ? null
        : ChatMedia.fromSupabase(row);
    final messageType = ChatMessageType.fromValue(
      row['message_type']?.toString(),
      mimeType: media?.mimeType,
    );

    return ChatMessage(
      id: row['id']?.toString() ?? '',
      threadId:
          row['conversation_id']?.toString() ??
          row['thread_id']?.toString() ??
          '',
      senderId: senderId,
      senderName: row['sender_name']?.toString() ?? 'Unknown',
      body: deletedAt == null ? row['body']?.toString() ?? '' : '',
      createdAt: _readRequiredTimestamp(row['created_at']),
      isMine: isMine,
      isDelivered: isDelivered,
      isRead: isRead,
      messageType: messageType,
      media: media,
      replyTo: deletedAt == null ? replyTo : null,
      reactions: deletedAt == null ? reactions : const [],
      isForwarded: row['is_forwarded'] == true,
      editedAt: _readOptionalTimestamp(row['edited_at']),
      deletedAt: deletedAt,
    );
  }
}

List<MessageReactionSummary> summarizeMessageReactions(
  Iterable<Map<String, dynamic>> rows, {
  required String localUserId,
}) {
  final counts = <String, int>{};
  final mine = <String>{};
  for (final row in rows) {
    final emoji = row['emoji']?.toString() ?? '';
    if (emoji.isEmpty) {
      continue;
    }
    counts[emoji] = (counts[emoji] ?? 0) + 1;
    if (row['user_id']?.toString() == localUserId) {
      mine.add(emoji);
    }
  }

  final summaries = counts.entries
      .map(
        (entry) => MessageReactionSummary(
          emoji: entry.key,
          count: entry.value,
          reactedByMe: mine.contains(entry.key),
        ),
      )
      .toList();
  summaries.sort((left, right) => left.emoji.compareTo(right.emoji));
  return List.unmodifiable(summaries);
}

int _readInt(Object? value) {
  return _readOptionalInt(value) ?? 0;
}

int? _readOptionalInt(Object? value) {
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
      .map((entry) {
        if (entry is num) {
          return entry.toDouble();
        }
        return double.tryParse(entry.toString());
      })
      .whereType<double>()
      .map((entry) => entry.clamp(0.0, 1.0).toDouble())
      .toList(growable: false);
}

DateTime _readRequiredTimestamp(Object? value) {
  return _readOptionalTimestamp(value) ?? DateTime.now();
}

DateTime? _readOptionalTimestamp(Object? value) {
  return DateTime.tryParse(value?.toString() ?? '')?.toLocal();
}

String activityLabelFor({required bool isOnline, DateTime? lastSeenAt}) {
  if (isOnline) {
    return 'Online';
  }
  if (lastSeenAt == null) {
    return 'Offline';
  }

  final difference = DateTime.now().difference(lastSeenAt);
  if (difference.inMinutes < 1) {
    return 'Active just now';
  }

  return 'Active since ${relativeTimeLabel(lastSeenAt)} ago';
}

String relativeTimeLabel(DateTime time) {
  final difference = DateTime.now().difference(time);
  if (difference.inMinutes < 1) {
    return 'now';
  }
  if (difference.inHours < 1) {
    return '${difference.inMinutes}m';
  }
  if (difference.inDays < 1) {
    return '${difference.inHours}h';
  }
  return '${difference.inDays}d';
}

class ChatSeed {
  ChatSeed._();

  static const localUserId = 'local-preview-user';

  static const users = [
    ChatUser(
      id: 'samira',
      displayName: 'Samira Haddad',
      email: 'samira@example.com',
    ),
    ChatUser(id: 'alex', displayName: 'Alex Morgan', email: 'alex@example.com'),
    ChatUser(
      id: 'maria',
      displayName: 'Maria Chen',
      email: 'maria@example.com',
    ),
    ChatUser(
      id: 'nadir',
      displayName: 'Nadir Bell',
      email: 'nadir@example.com',
    ),
  ];

  static const threads = [
    ChatThread(
      id: 'studio',
      title: 'Design Studio',
      subtitle: 'Done. Messages can come from the realtime table stream.',
      avatarLabel: 'DS',
      accentColor: Color(0xFF127A74),
      lastActive: 'Now',
      unreadCount: 3,
      isOnline: true,
      activityLabel: 'Typing...',
      peerUserId: 'samira',
      isTyping: true,
      typingUserName: 'Samira',
    ),
    ChatThread(
      id: 'product',
      title: 'Product Team',
      subtitle: 'The release notes are ready.',
      avatarLabel: 'PT',
      accentColor: Color(0xFF3B6AE8),
      lastActive: '12m',
      unreadCount: 0,
      isOnline: true,
      activityLabel: 'Online',
      peerUserId: 'alex',
    ),
    ChatThread(
      id: 'maria',
      title: 'Maria Chen',
      subtitle: 'Can you review the handoff?',
      avatarLabel: 'MC',
      accentColor: Color(0xFFE7654A),
      lastActive: '1h',
      unreadCount: 1,
      isOnline: false,
      activityLabel: 'Active since 1h ago',
      peerUserId: 'maria',
    ),
    ChatThread(
      id: 'ops',
      title: 'Ops Channel',
      subtitle: 'Backend deploy finished.',
      avatarLabel: 'OC',
      accentColor: Color(0xFF8861D4),
      lastActive: '4h',
      unreadCount: 0,
      isOnline: false,
      activityLabel: 'Active since 4h ago',
      peerUserId: 'nadir',
    ),
  ];

  static Map<String, UserPresence> get presenceByUser {
    final now = DateTime.now();

    return {
      'samira': UserPresence(
        userId: 'samira',
        displayName: 'Samira',
        isOnline: true,
        lastSeenAt: now,
      ),
      'alex': UserPresence(
        userId: 'alex',
        displayName: 'Alex',
        isOnline: true,
        lastSeenAt: now.subtract(const Duration(minutes: 2)),
      ),
      'maria': UserPresence(
        userId: 'maria',
        displayName: 'Maria',
        isOnline: false,
        lastSeenAt: now.subtract(const Duration(hours: 1)),
      ),
      'nadir': UserPresence(
        userId: 'nadir',
        displayName: 'Nadir',
        isOnline: false,
        lastSeenAt: now.subtract(const Duration(hours: 4)),
      ),
    };
  }

  static TypingState typingForConversation(String conversationId) {
    if (conversationId == 'studio') {
      return const TypingState(
        conversationId: 'studio',
        userId: 'samira',
        displayName: 'Samira',
        isTyping: true,
      );
    }

    return TypingState.idle(conversationId);
  }

  static List<ChatMessage> messagesFor(String threadId) {
    final now = DateTime.now();
    final messages = <ChatMessage>[
      ChatMessage(
        id: 'm1',
        threadId: 'studio',
        senderId: 'samira',
        senderName: 'Samira',
        body: 'The new chat layout is in a good place.',
        createdAt: now.subtract(const Duration(minutes: 18)),
        isMine: false,
        isDelivered: false,
        isRead: false,
      ),
      ChatMessage(
        id: 'm2',
        threadId: 'studio',
        senderId: localUserId,
        senderName: 'You',
        body: 'Nice. I want the backend boundary ready for Supabase too.',
        createdAt: now.subtract(const Duration(minutes: 15)),
        isMine: true,
        isDelivered: true,
        isRead: true,
      ),
      ChatMessage(
        id: 'm3',
        threadId: 'studio',
        senderId: localUserId,
        senderName: 'You',
        body: 'I will send the final copy next.',
        createdAt: now.subtract(const Duration(minutes: 12)),
        isMine: true,
        isDelivered: true,
        isRead: false,
      ),
      ChatMessage(
        id: 'm4',
        threadId: 'studio',
        senderId: 'samira',
        senderName: 'Samira',
        body: 'Done. Messages can come from the realtime table stream.',
        createdAt: now.subtract(const Duration(minutes: 8)),
        isMine: false,
        isDelivered: false,
        isRead: false,
      ),
      ChatMessage(
        id: 'm5',
        threadId: 'product',
        senderId: 'alex',
        senderName: 'Alex',
        body: 'The release notes are ready for the build review.',
        createdAt: now.subtract(const Duration(minutes: 35)),
        isMine: false,
        isDelivered: false,
        isRead: false,
      ),
      ChatMessage(
        id: 'm6',
        threadId: 'maria',
        senderId: 'maria',
        senderName: 'Maria',
        body: 'Can you review the handoff before the client call?',
        createdAt: now.subtract(const Duration(hours: 1)),
        isMine: false,
        isDelivered: false,
        isRead: false,
      ),
      ChatMessage(
        id: 'm7',
        threadId: 'ops',
        senderId: 'nadir',
        senderName: 'Nadir',
        body: 'Backend deploy finished. Monitoring looks clean.',
        createdAt: now.subtract(const Duration(hours: 4)),
        isMine: false,
        isDelivered: false,
        isRead: false,
      ),
    ];

    return messages.where((message) => message.threadId == threadId).toList();
  }
}
