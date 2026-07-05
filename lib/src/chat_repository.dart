import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_models.dart';

class ChatRepository {
  ChatRepository({this.client});

  final SupabaseClient? client;
  RealtimeChannel? _presenceChannel;
  bool _presenceSubscribed = false;
  final Map<String, RealtimeChannel> _typingChannels = {};
  final Map<String, StreamController<TypingState>> _typingControllers = {};
  final Set<String> _typingSubscribeStartedConversations = {};
  final Set<String> _typingSubscribedConversations = {};
  final Map<String, Future<void>> _typingSubscribeFutures = {};
  final Map<String, bool> _typingValues = {};

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

  Future<void> updateLastSeen() async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    await supabase
        .from('profiles')
        .update({'last_seen_at': now, 'updated_at': now})
        .eq('id', user.id);
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

  Stream<Map<String, UserPresence>> watchPresenceForThreads() {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return Stream.value(ChatSeed.presenceByUser);
    }

    final controller = StreamController<Map<String, UserPresence>>();
    final channel = _presenceChannel ??= supabase.channel(
      'online-users',
      opts: RealtimeChannelConfig(key: user.id),
    );

    void emitPresence() {
      if (!controller.isClosed) {
        controller.add(_presenceByUserFrom(channel));
      }
    }

    channel
        .onPresenceSync((_) => emitPresence())
        .onPresenceJoin((_) => emitPresence())
        .onPresenceLeave((_) => emitPresence());

    if (!_presenceSubscribed) {
      _presenceSubscribed = true;
      channel.subscribe((status, [_]) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          unawaited(
            channel.track({
              'user_id': user.id,
              'display_name': localSenderName,
              'online_at': DateTime.now().toUtc().toIso8601String(),
            }),
          );
          emitPresence();
        }
      });
    } else {
      scheduleMicrotask(emitPresence);
    }

    return controller.stream;
  }

  Stream<TypingState> watchConversationTyping(String conversationId) {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return Stream.value(ChatSeed.typingForConversation(conversationId));
    }

    final controller = _typingControllerFor(
      supabase: supabase,
      userId: user.id,
      conversationId: conversationId,
    );
    scheduleMicrotask(() => _emitTyping(conversationId, user.id));

    return controller.stream;
  }

  StreamController<TypingState> _typingControllerFor({
    required SupabaseClient supabase,
    required String userId,
    required String conversationId,
  }) {
    final existing = _typingControllers[conversationId];
    if (existing != null && !existing.isClosed) {
      return existing;
    }

    late final StreamController<TypingState> controller;
    final channel = _typingChannelFor(
      supabase: supabase,
      userId: userId,
      conversationId: conversationId,
    );

    void emitTyping() {
      _emitTyping(conversationId, userId);
    }

    controller = StreamController<TypingState>.broadcast();
    _typingControllers[conversationId] = controller;

    channel
        .onPresenceSync((_) => emitTyping())
        .onPresenceJoin((_) => emitTyping())
        .onPresenceLeave((_) => emitTyping());

    _subscribeTypingChannel(
      channel: channel,
      conversationId: conversationId,
      onSubscribed: emitTyping,
    );
    scheduleMicrotask(emitTyping);

    return controller;
  }

  Future<void> setTyping({
    required String conversationId,
    required bool isTyping,
  }) async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return;
    }

    if (_typingValues[conversationId] == isTyping) {
      return;
    }

    final channel = _typingChannelFor(
      supabase: supabase,
      userId: user.id,
      conversationId: conversationId,
    );
    final isSubscribed = await _subscribeTypingChannel(
      channel: channel,
      conversationId: conversationId,
    );
    if (!isSubscribed) {
      return;
    }

    try {
      await channel.track({
        'user_id': user.id,
        'display_name': localSenderName,
        'conversation_id': conversationId,
        'typing': isTyping,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      _typingValues[conversationId] = isTyping;
    } catch (_) {
      // Typing is transient; never let a realtime timing issue break chat flow.
    }
  }

  Future<void> markConversationDelivered(String conversationId) async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return;
    }

    await supabase
        .from('message_receipts')
        .update({'delivered_at': DateTime.now().toUtc().toIso8601String()})
        .eq('conversation_id', conversationId)
        .eq('user_id', user.id)
        .isFilter('delivered_at', null);
  }

  Future<void> markConversationRead(String conversationId) async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    await markConversationDelivered(conversationId);
    await supabase
        .from('message_receipts')
        .update({'read_at': now})
        .eq('conversation_id', conversationId)
        .eq('user_id', user.id)
        .isFilter('read_at', null);
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

    final rows = await _selectProfiles(
      supabase,
      (query) =>
          query.neq('id', currentUser.id).order('display_name').limit(50),
    );

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
    final user = supabase.auth.currentUser;
    if (user == null) {
      return Stream.value(const []);
    }

    final controller = StreamController<List<ChatMessage>>();
    final messagesById = <String, Map<String, dynamic>>{};
    var receiptsByMessageId = <String, MessageReceipt>{};
    StreamSubscription<List<Map<String, dynamic>>>? messagesSubscription;
    StreamSubscription<List<Map<String, dynamic>>>? receiptsSubscription;

    void emitMessages() {
      if (controller.isClosed) {
        return;
      }

      final messages =
          messagesById.values
              .map(
                (row) => ChatMessage.fromSupabase(
                  row,
                  localUserId: user.id,
                  receipt: receiptsByMessageId[row['id']?.toString()],
                ),
              )
              .toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      controller.add(messages);
    }

    messagesSubscription = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at')
        .listen((rows) {
          messagesById
            ..clear()
            ..addEntries(
              rows.map((row) => MapEntry(row['id']?.toString() ?? '', row)),
            );
          emitMessages();
        }, onError: controller.addError);

    receiptsSubscription = supabase
        .from('message_receipts')
        .stream(primaryKey: ['message_id', 'user_id'])
        .eq('conversation_id', conversationId)
        .listen((rows) {
          receiptsByMessageId = {
            for (final row in rows)
              if (row['user_id']?.toString() != user.id)
                MessageReceipt.fromSupabase(row).messageId:
                    MessageReceipt.fromSupabase(row),
          };
          emitMessages();
        }, onError: controller.addError);

    controller.onCancel = () async {
      await messagesSubscription?.cancel();
      await receiptsSubscription?.cancel();
    };

    return controller.stream;
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

  Future<void> disposeRealtime() async {
    final supabase = client;
    if (supabase == null) {
      return;
    }

    await updateLastSeen();

    final channels = [?_presenceChannel, ..._typingChannels.values];

    _presenceChannel = null;
    _presenceSubscribed = false;
    for (final controller in _typingControllers.values) {
      await controller.close();
    }
    _typingControllers.clear();
    _typingChannels.clear();
    _typingSubscribeStartedConversations.clear();
    _typingSubscribedConversations.clear();
    _typingSubscribeFutures.clear();
    _typingValues.clear();

    await Future.wait(
      channels.map((channel) async {
        try {
          await channel.untrack();
        } catch (_) {
          // Best effort cleanup; channel removal below is the important part.
        }

        try {
          await supabase.removeChannel(channel);
        } catch (_) {
          // Realtime cleanup should never block widget disposal.
        }
      }),
    );
  }

  RealtimeChannel _typingChannelFor({
    required SupabaseClient supabase,
    required String userId,
    required String conversationId,
  }) {
    return _typingChannels[conversationId] ??= supabase.channel(
      'typing:$conversationId',
      opts: RealtimeChannelConfig(key: userId),
    );
  }

  Future<bool> _subscribeTypingChannel({
    required RealtimeChannel channel,
    required String conversationId,
    VoidCallback? onSubscribed,
  }) async {
    if (_typingSubscribedConversations.contains(conversationId)) {
      onSubscribed?.call();
      return true;
    }

    final pendingSubscription = _typingSubscribeFutures[conversationId];
    if (pendingSubscription != null) {
      await pendingSubscription;
      if (_typingSubscribedConversations.contains(conversationId)) {
        onSubscribed?.call();
        return true;
      }
      return false;
    }

    if (_typingSubscribeStartedConversations.contains(conversationId)) {
      return _typingSubscribedConversations.contains(conversationId);
    }

    final completer = Completer<void>();
    final subscriptionFuture = completer.future
        .timeout(const Duration(seconds: 2), onTimeout: () {})
        .whenComplete(() {
          _typingSubscribeFutures.remove(conversationId);
        });
    _typingSubscribeFutures[conversationId] = subscriptionFuture;
    _typingSubscribeStartedConversations.add(conversationId);

    try {
      channel.subscribe((status, [_]) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          _typingSubscribedConversations.add(conversationId);
          onSubscribed?.call();
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
        if (status == RealtimeSubscribeStatus.channelError &&
            !completer.isCompleted) {
          completer.complete();
        }
      });
    } catch (_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    await subscriptionFuture;
    return _typingSubscribedConversations.contains(conversationId);
  }

  void _emitTyping(String conversationId, String localUserId) {
    final controller = _typingControllers[conversationId];
    final channel = _typingChannels[conversationId];
    if (controller == null || controller.isClosed || channel == null) {
      return;
    }

    controller.add(_typingStateFrom(channel, conversationId, localUserId));
  }

  Map<String, UserPresence> _presenceByUserFrom(RealtimeChannel channel) {
    final presence = <String, UserPresence>{};

    for (final state in channel.presenceState()) {
      for (final item in state.presences) {
        final payload = item.payload;
        final userId = payload['user_id']?.toString().trim().isNotEmpty == true
            ? payload['user_id'].toString()
            : state.key;
        if (userId.isEmpty) {
          continue;
        }

        presence[userId] = UserPresence(
          userId: userId,
          displayName: payload['display_name']?.toString(),
          isOnline: true,
          lastSeenAt: _readTimestamp(
            payload['last_seen_at'] ?? payload['online_at'],
          ),
        );
      }
    }

    return presence;
  }

  TypingState _typingStateFrom(
    RealtimeChannel channel,
    String conversationId,
    String localUserId,
  ) {
    for (final state in channel.presenceState()) {
      if (state.key == localUserId) {
        continue;
      }

      for (final item in state.presences.reversed) {
        final payload = item.payload;
        if (payload['conversation_id']?.toString() != conversationId ||
            payload['typing'] != true) {
          continue;
        }

        return TypingState(
          conversationId: conversationId,
          userId: payload['user_id']?.toString() ?? state.key,
          displayName: payload['display_name']?.toString() ?? 'Someone',
          isTyping: true,
        );
      }
    }

    return TypingState.idle(conversationId);
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

    final rows = await _selectProfiles(
      supabase,
      (query) => query.inFilter('id', ids.toList()),
    );

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
      lastActive: lastMessageAt == null
          ? 'New'
          : relativeTimeLabel(lastMessageAt),
      unreadCount: 0,
      isOnline: false,
      activityLabel: activityLabelFor(
        isOnline: false,
        lastSeenAt: peer.lastSeenAt,
      ),
      peerUserId: peer.id,
      peerLastSeenAt: peer.lastSeenAt,
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

Future<List<Map<String, dynamic>>> _selectProfiles(
  SupabaseClient supabase,
  dynamic Function(dynamic query) applyFilters,
) async {
  final rows = await applyFilters(
    supabase.from('profiles').select('id, display_name, email, last_seen_at'),
  );
  return List<Map<String, dynamic>>.from(rows);
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
