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

  factory ChatMessage.fromSupabase(
    Map<String, dynamic> row, {
    required String localUserId,
    MessageReceipt? receipt,
  }) {
    final senderId = row['sender_id']?.toString() ?? '';
    final isMine = senderId == localUserId;
    final isRead = isMine && (receipt?.isRead ?? false);
    final isDelivered = isMine && ((receipt?.isDelivered ?? false) || isRead);

    return ChatMessage(
      id: row['id']?.toString() ?? '',
      threadId:
          row['conversation_id']?.toString() ??
          row['thread_id']?.toString() ??
          '',
      senderId: senderId,
      senderName: row['sender_name']?.toString() ?? 'Unknown',
      body: row['body']?.toString() ?? '',
      createdAt: _readRequiredTimestamp(row['created_at']),
      isMine: isMine,
      isDelivered: isDelivered,
      isRead: isRead,
    );
  }
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
