import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_models.dart';

class ChatRepository {
  const ChatRepository({this.client});

  final SupabaseClient? client;

  bool get isConnected => client != null;

  List<ChatThread> get threads => ChatSeed.threads;

  User? get _currentUser => client?.auth.currentUser;

  String get localUserId => _currentUser?.id ?? ChatSeed.localUserId;

  String get localSenderName {
    final user = _currentUser;
    final metadata = user?.userMetadata;
    final metadataName =
        metadata?['display_name'] ??
        metadata?['full_name'] ??
        metadata?['name'];
    final displayName = metadataName?.toString().trim();

    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }

    final emailName = user?.email?.split('@').first.trim();
    if (emailName != null && emailName.isNotEmpty) {
      return emailName;
    }

    final phone = user?.phone?.trim();
    if (phone != null && phone.isNotEmpty) {
      return phone;
    }

    return 'You';
  }

  Future<void> upsertCurrentProfile() async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return;
    }

    await supabase.from('profiles').upsert({
      'id': user.id,
      'display_name': localSenderName,
      'email': user.email,
      'phone': user.phone,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'id');
  }

  Stream<List<ChatThread>> watchThreads() {
    final supabase = client;
    if (supabase == null) {
      return Stream.value(ChatSeed.threads);
    }
    final user = supabase.auth.currentUser;
    if (user == null) {
      return Stream.value(const []);
    }

    return supabase
        .from('conversations')
        .stream(primaryKey: ['id'])
        .order('last_message_at')
        .asyncMap(
          (rows) => _threadsFromConversationRows(
            rows.where((row) => _belongsToUser(row, user.id)).toList(),
          ),
        );
  }

  Future<List<ChatUser>> searchUsers(String query) async {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return const [];
    }

    final supabase = client;
    if (supabase == null) {
      return ChatSeed.users
          .where((user) => _matchesUser(user, normalizedQuery))
          .toList();
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      return const [];
    }

    final rows = await supabase
        .from('profiles')
        .select('id, display_name, email')
        .neq('id', currentUser.id)
        .order('display_name')
        .limit(50);

    return rows
        .map(ChatUser.fromSupabase)
        .where((user) => _matchesUser(user, normalizedQuery))
        .take(12)
        .toList();
  }

  Future<ChatThread> startDirectConversation(ChatUser peer) async {
    final supabase = client;
    if (supabase == null) {
      return _threadFromPeer(
        conversationId: 'direct-${peer.id}',
        peer: peer,
        hasMessages: false,
      );
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      throw const AuthException('Sign in before starting a chat.');
    }

    await upsertCurrentProfile();

    final participantIds = [currentUser.id, peer.id]..sort();
    final userOneId = participantIds.first;
    final userTwoId = participantIds.last;

    final existing = await supabase
        .from('conversations')
        .select()
        .eq('user_one_id', userOneId)
        .eq('user_two_id', userTwoId)
        .maybeSingle();

    if (existing != null) {
      return _threadFromConversation(existing, peer);
    }

    try {
      final created = await supabase
          .from('conversations')
          .insert({'user_one_id': userOneId, 'user_two_id': userTwoId})
          .select()
          .single();

      return _threadFromConversation(created, peer);
    } on PostgrestException {
      final raced = await supabase
          .from('conversations')
          .select()
          .eq('user_one_id', userOneId)
          .eq('user_two_id', userTwoId)
          .single();

      return _threadFromConversation(raced, peer);
    }
  }

  Stream<List<ChatMessage>> watchMessages(String conversationId) {
    final supabase = client;
    if (supabase == null) {
      return Stream.value(ChatSeed.messagesFor(conversationId));
    }
    if (supabase.auth.currentUser == null) {
      return Stream.value(const []);
    }

    return supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at')
        .map(
          (rows) => rows
              .map(
                (row) =>
                    ChatMessage.fromSupabase(row, localUserId: localUserId),
              )
              .toList(),
        );
  }

  Future<void> sendMessage({
    required String conversationId,
    required String body,
  }) async {
    final trimmed = body.trim();
    final supabase = client;
    if (trimmed.isEmpty || supabase == null) {
      return;
    }

    final user = supabase.auth.currentUser;
    if (user == null) {
      throw const AuthException('Sign in before sending messages.');
    }

    await supabase.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': user.id,
      'sender_name': localSenderName,
      'body': trimmed,
    });
  }

  Future<List<ChatThread>> _threadsFromConversationRows(
    List<Map<String, dynamic>> rows,
  ) async {
    rows.sort((a, b) {
      final aTime =
          _readTimestamp(a['last_message_at']) ??
          _readTimestamp(a['created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bTime =
          _readTimestamp(b['last_message_at']) ??
          _readTimestamp(b['created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });

    final peerIds = rows.map(_peerUserIdFor).whereType<String>().toSet();
    final profiles = await _profilesById(peerIds);

    return rows.map((row) {
      final peerId = _peerUserIdFor(row) ?? '';
      final peer =
          profiles[peerId] ?? ChatUser(id: peerId, displayName: 'Unknown user');
      return _threadFromConversation(row, peer);
    }).toList();
  }

  Future<Map<String, ChatUser>> _profilesById(Set<String> ids) async {
    final supabase = client;
    if (supabase == null || ids.isEmpty) {
      return const {};
    }

    final rows = await supabase
        .from('profiles')
        .select('id, display_name, email')
        .inFilter('id', ids.toList());

    return {
      for (final row in rows)
        ChatUser.fromSupabase(row).id: ChatUser.fromSupabase(row),
    };
  }

  bool _belongsToUser(Map<String, dynamic> row, String userId) {
    return row['user_one_id']?.toString() == userId ||
        row['user_two_id']?.toString() == userId;
  }

  String? _peerUserIdFor(Map<String, dynamic> row) {
    final userId = localUserId;
    final userOneId = row['user_one_id']?.toString();
    final userTwoId = row['user_two_id']?.toString();

    if (userOneId == userId) {
      return userTwoId;
    }
    if (userTwoId == userId) {
      return userOneId;
    }
    return null;
  }

  ChatThread _threadFromConversation(Map<String, dynamic> row, ChatUser peer) {
    final lastMessageAt = _readTimestamp(row['last_message_at']);

    return _threadFromPeer(
      conversationId: row['id']?.toString() ?? '',
      peer: peer,
      hasMessages: lastMessageAt != null,
      lastMessageAt: lastMessageAt,
    );
  }

  ChatThread _threadFromPeer({
    required String conversationId,
    required ChatUser peer,
    required bool hasMessages,
    DateTime? lastMessageAt,
  }) {
    return ChatThread(
      id: conversationId,
      title: peer.displayName,
      subtitle: hasMessages ? 'Latest messages are synced.' : 'No messages yet',
      avatarLabel: peer.avatarLabel,
      accentColor: _accentColorFor(peer.id),
      lastActive: lastMessageAt == null ? 'New' : _relativeTime(lastMessageAt),
      unreadCount: 0,
      isOnline: false,
      peerUserId: peer.id,
    );
  }
}

bool _matchesUser(ChatUser user, String query) {
  return user.id.toLowerCase().contains(query) ||
      user.displayName.toLowerCase().contains(query) ||
      (user.email?.toLowerCase().contains(query) ?? false);
}

DateTime? _readTimestamp(Object? value) {
  return DateTime.tryParse(value?.toString() ?? '')?.toLocal();
}

String _relativeTime(DateTime time) {
  final difference = DateTime.now().difference(time);
  if (difference.inMinutes < 1) {
    return 'Now';
  }
  if (difference.inHours < 1) {
    return '${difference.inMinutes}m';
  }
  if (difference.inDays < 1) {
    return '${difference.inHours}h';
  }
  return '${difference.inDays}d';
}

Color _accentColorFor(String seed) {
  const colors = [
    Color(0xFF127A74),
    Color(0xFF3B6AE8),
    Color(0xFFE7654A),
    Color(0xFF8861D4),
    Color(0xFFB5661B),
  ];

  final hash = seed.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return colors[hash % colors.length];
}
