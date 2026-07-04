import 'package:flutter/material.dart';

enum DeliveryState { sending, sent, seen }

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
  });

  final String id;
  final String title;
  final String subtitle;
  final String avatarLabel;
  final Color accentColor;
  final String lastActive;
  final int unreadCount;
  final bool isOnline;
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
    required this.deliveryState,
  });

  final String id;
  final String threadId;
  final String senderId;
  final String senderName;
  final String body;
  final DateTime createdAt;
  final bool isMine;
  final DeliveryState deliveryState;

  factory ChatMessage.fromSupabase(
    Map<String, dynamic> row, {
    required String localUserId,
  }) {
    final senderId = row['sender_id']?.toString() ?? '';

    return ChatMessage(
      id: row['id']?.toString() ?? '',
      threadId: row['thread_id']?.toString() ?? '',
      senderId: senderId,
      senderName: row['sender_name']?.toString() ?? 'Unknown',
      body: row['body']?.toString() ?? '',
      createdAt: _readTimestamp(row['created_at']),
      isMine: senderId == localUserId,
      deliveryState: DeliveryState.seen,
    );
  }
}

DateTime _readTimestamp(Object? value) {
  return DateTime.tryParse(value?.toString() ?? '')?.toLocal() ??
      DateTime.now();
}

class ChatSeed {
  ChatSeed._();

  static const localUserId = 'local-preview-user';

  static const threads = [
    ChatThread(
      id: 'studio',
      title: 'Design Studio',
      subtitle: 'Samira is typing...',
      avatarLabel: 'DS',
      accentColor: Color(0xFF127A74),
      lastActive: 'Now',
      unreadCount: 3,
      isOnline: true,
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
    ),
  ];

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
        deliveryState: DeliveryState.seen,
      ),
      ChatMessage(
        id: 'm2',
        threadId: 'studio',
        senderId: localUserId,
        senderName: 'You',
        body: 'Nice. I want the backend boundary ready for Supabase too.',
        createdAt: now.subtract(const Duration(minutes: 15)),
        isMine: true,
        deliveryState: DeliveryState.seen,
      ),
      ChatMessage(
        id: 'm3',
        threadId: 'studio',
        senderId: 'samira',
        senderName: 'Samira',
        body: 'Done. Messages can come from the realtime table stream.',
        createdAt: now.subtract(const Duration(minutes: 8)),
        isMine: false,
        deliveryState: DeliveryState.seen,
      ),
      ChatMessage(
        id: 'm4',
        threadId: 'product',
        senderId: 'alex',
        senderName: 'Alex',
        body: 'The release notes are ready for the build review.',
        createdAt: now.subtract(const Duration(minutes: 35)),
        isMine: false,
        deliveryState: DeliveryState.seen,
      ),
      ChatMessage(
        id: 'm5',
        threadId: 'maria',
        senderId: 'maria',
        senderName: 'Maria',
        body: 'Can you review the handoff before the client call?',
        createdAt: now.subtract(const Duration(hours: 1)),
        isMine: false,
        deliveryState: DeliveryState.seen,
      ),
      ChatMessage(
        id: 'm6',
        threadId: 'ops',
        senderId: 'nadir',
        senderName: 'Nadir',
        body: 'Backend deploy finished. Monitoring looks clean.',
        createdAt: now.subtract(const Duration(hours: 4)),
        isMine: false,
        deliveryState: DeliveryState.seen,
      ),
    ];

    return messages.where((message) => message.threadId == threadId).toList();
  }
}
