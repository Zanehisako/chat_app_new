import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_saver/file_saver.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'chat_models.dart';
import 'e2ee_crypto_service.dart';
import 'e2ee_draft_protector.dart';
import 'outbox_message_sender.dart';
import 'supabase_config.dart';

class ChatRepository implements OutboxMessageSender, OutboxScopeProvider {
  ChatRepository({this.client, E2eeCryptoService? crypto})
    : _crypto = crypto ?? E2eeCryptoService.instance;

  static const mediaBucket = 'chat-media';
  static const giphyApiKey = String.fromEnvironment(
    'GIPHY_API_KEY',
    defaultValue: 'MDd2YDtyctTXW6Z8fkRPJOwUcPZQJlvE',
  );
  static const maxMediaBytes = 15 * 1024 * 1024;
  static const _mediaCacheControl = '31536000';
  static const _allowedMediaTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'image/heic',
    'image/heif',
  };
  static const _allowedVoiceTypes = {
    'audio/wav',
    'audio/x-wav',
    'audio/aac',
    'audio/mpeg',
    'audio/mp3',
    'audio/mp4',
    'audio/webm',
    'audio/ogg',
  };

  final SupabaseClient? client;
  final E2eeCryptoService _crypto;
  final ImagePicker _imagePicker = ImagePicker();
  final Uuid _uuid = const Uuid();
  RealtimeChannel? _presenceChannel;
  bool _presenceSubscribed = false;
  final Map<String, RealtimeChannel> _typingChannels = {};
  final Map<String, StreamController<TypingState>> _typingControllers = {};
  final Set<String> _typingSubscribeStartedConversations = {};
  final Set<String> _typingSubscribedConversations = {};
  final Map<String, Future<void>> _typingSubscribeFutures = {};
  final Map<String, bool> _typingValues = {};
  final Map<String, E2eeDeviceIdentity> _deviceIdentities =
      <String, E2eeDeviceIdentity>{};
  Future<E2eeReadyState>? _e2eeLifecycle;
  String? _e2eeLifecycleUserId;

  bool get isConnected => client != null;

  @override
  bool get isOutboxReady => client?.auth.currentUser != null;

  @override
  String? get outboxUserId => client?.auth.currentUser?.id;

  @override
  String? get outboxBackendOrigin {
    if (client == null) {
      return null;
    }
    final uri = Uri.tryParse(SupabaseConfig.url);
    return uri?.hasScheme == true && uri?.host.isNotEmpty == true
        ? uri!.origin.toLowerCase()
        : null;
  }

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

  /// Establishes this device's account and device identity without ever
  /// uploading private material. A newly generated recovery phrase must be
  /// confirmed before registration or sending is allowed.
  Future<E2eeReadyState> e2eeReadyState() async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return const E2eeReadyState();
    }

    final inFlight = _e2eeLifecycle;
    if (inFlight != null && _e2eeLifecycleUserId == user.id) {
      return inFlight;
    }

    final future = _loadE2eeReadyState(supabase, user.id);
    _e2eeLifecycle = future;
    _e2eeLifecycleUserId = user.id;
    try {
      return await future;
    } finally {
      if (identical(_e2eeLifecycle, future)) {
        _e2eeLifecycle = null;
        _e2eeLifecycleUserId = null;
      }
    }
  }

  Future<String?> recoveryPhrase() async {
    final user = _currentUser;
    if (user == null) return null;
    return _crypto.getRecoveryPhrase(user.id);
  }

  Future<void> confirmRecoveryPhrase(String phrase) async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      throw const E2eeCryptoException('Sign in before confirming recovery.');
    }
    await _crypto.confirmRecoveryPhrase(userId: user.id, phrase: phrase);
    final state = await e2eeReadyState();
    if (!state.isReadyForSending) {
      throw const E2eeCryptoException(
        'Confirm the recovery phrase before enabling encrypted messages.',
      );
    }
  }

  Future<void> restoreE2eeRecoveryPhrase(String phrase) async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      throw const E2eeCryptoException('Sign in before restoring recovery.');
    }
    await _crypto.ensureReady(client: supabase, userId: user.id);
    final restored = await _crypto.restoreFromRecoveryPhrase(
      userId: user.id,
      phrase: phrase,
    );
    await _registerE2eeState(supabase, restored);
  }

  Future<E2eeDraftProtector> e2eeDraftProtector() async {
    await _requireE2eeReady();
    return CryptoServiceDraftProtector(crypto: _crypto);
  }

  Future<List<ConversationSafetyIdentity>> conversationSafetyIdentities(
    String conversationId,
  ) async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return const <ConversationSafetyIdentity>[];
    }
    final rows = _mapRows(
      await supabase.rpc(
        'get_conversation_e2ee_key_material',
        params: <String, dynamic>{'p_conversation_id': conversationId},
      ),
    );
    final identities = <String, ConversationSafetyIdentity>{};
    for (final row in rows) {
      final userId = _nullableText(row['recipient_user_id']);
      final signingPublicKey = _nullableText(row['account_signing_public_key']);
      if (userId == null || signingPublicKey == null || userId == user.id) {
        continue;
      }
      final trust = await _crypto.trustStateForAccount(
        userId: userId,
        signingPublicKey: signingPublicKey,
      );
      identities[userId] = ConversationSafetyIdentity(
        userId: userId,
        signingPublicKey: signingPublicKey,
        fingerprint: trust.fingerprint,
        isVerified: trust.isVerified,
        hasChanged: trust.hasChanged,
      );
    }
    final values = identities.values.toList()
      ..sort((left, right) => left.userId.compareTo(right.userId));
    return List<ConversationSafetyIdentity>.unmodifiable(values);
  }

  Future<void> markSafetyIdentityVerified(ConversationSafetyIdentity identity) {
    return _crypto.markAccountIdentityVerified(
      userId: identity.userId,
      signingPublicKey: identity.signingPublicKey,
    );
  }

  Future<E2eeReadyState> _loadE2eeReadyState(
    SupabaseClient supabase,
    String userId,
  ) async {
    final state = await _crypto.ensureReady(client: supabase, userId: userId);
    if (state.isReadyForSending) {
      return _registerE2eeState(supabase, state);
    }
    return state;
  }

  Future<E2eeReadyState> _registerE2eeState(
    SupabaseClient supabase,
    E2eeReadyState state,
  ) async {
    final account = state.account;
    final device = state.device;
    if (account == null || device == null || !state.isReadyForSending) {
      throw const E2eeCryptoException(
        'Confirm or restore the recovery phrase before registering this device.',
      );
    }
    await supabase.rpc(
      'register_e2ee_account',
      params: <String, dynamic>{
        'p_recovery_public_key': account.recoveryPublicKey,
        'p_signing_public_key': account.signingPublicKey,
        'p_protocol_version': account.protocolVersion,
      },
    );
    try {
      await _registerE2eeDevice(supabase, device);
      return state;
    } on E2eeCryptoException catch (error) {
      if (!_isRevokedDeviceRegistrationError(error)) rethrow;
      final replacement = await _crypto.replaceLocalDevice(
        userId: account.userId,
      );
      final replacementDevice = replacement.device;
      if (replacementDevice == null) {
        throw const E2eeCryptoException(
          'Could not create a replacement encrypted device.',
        );
      }
      await _registerE2eeDevice(supabase, replacementDevice);
      return replacement;
    }
  }

  Future<void> _registerE2eeDevice(
    SupabaseClient supabase,
    E2eeDevice device,
  ) async {
    try {
      final response = await supabase.functions.invoke(
        'e2ee-register-device',
        body: <String, dynamic>{
          'device_id': device.id,
          'encryption_public_key': device.encryptionPublicKey,
          'signing_public_key': device.signingPublicKey,
          'certificate': device.certificate,
          'label': device.label,
          'protocol_version': device.protocolVersion,
        },
      );
      final data = response.data;
      if (data is! Map) {
        throw const E2eeCryptoException(
          'Encrypted device registration returned an invalid response.',
        );
      }
      final payload = Map<String, dynamic>.from(data);
      final error = _nullableText(payload['error']);
      if (error != null) throw E2eeCryptoException(error);
      if (_nullableText(payload['device_id']) != device.id) {
        throw const E2eeCryptoException(
          'Encrypted device registration did not confirm this device.',
        );
      }
    } on E2eeCryptoException {
      rethrow;
    } on FunctionException catch (error) {
      final details = error.details;
      final message = details is Map
          ? _nullableText(details['error'])
          : _nullableText(details);
      throw E2eeCryptoException(
        message ?? 'Could not register this encrypted device.',
        error,
      );
    } catch (error) {
      throw E2eeCryptoException(
        'Could not register this encrypted device.',
        error,
      );
    }
  }

  bool _isRevokedDeviceRegistrationError(E2eeCryptoException error) {
    final message = error.message.toLowerCase();
    return message.contains('revoked e2ee device') ||
        message.contains('cannot be reactivated');
  }

  Future<E2eeReadyState> _requireE2eeReady() async {
    final state = await e2eeReadyState();
    if (state.isReadyForSending) return state;
    if (state.requiresRecoveryPhraseRestore) {
      throw const E2eeCryptoException(
        'Restore this account’s recovery phrase before opening encrypted messages.',
      );
    }
    throw const E2eeCryptoException(
      'Confirm the 24-word recovery phrase before sending encrypted messages.',
    );
  }

  Future<CurrentUserProfile> currentProfile() async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return CurrentUserProfile.local(displayName: localSenderName);
    }

    var row = await supabase
        .from('profiles')
        .select('id, display_name, email, phone, updated_at')
        .eq('id', user.id)
        .maybeSingle();

    if (row == null) {
      await upsertCurrentProfile();
      row = await supabase
          .from('profiles')
          .select('id, display_name, email, phone, updated_at')
          .eq('id', user.id)
          .maybeSingle();
    }

    return CurrentUserProfile.fromSupabase(
      row ?? const <String, dynamic>{},
      fallbackId: user.id,
      fallbackDisplayName: localSenderName,
      fallbackEmail: user.email,
      fallbackPhone: user.phone,
    );
  }

  Future<CurrentUserProfile> updateCurrentProfile({
    required String displayName,
    String? email,
    String? phone,
  }) async {
    final trimmedName = displayName.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('Display name is required.');
    }

    final normalizedEmail = _nullableText(email);
    final normalizedPhone = _nullableText(phone);
    final now = DateTime.now().toUtc();
    final supabase = client;
    final user = supabase?.auth.currentUser;

    if (supabase == null || user == null) {
      return CurrentUserProfile.local(
        displayName: trimmedName,
        email: normalizedEmail,
        phone: normalizedPhone,
        updatedAt: now.toLocal(),
      );
    }

    final metadata = Map<String, dynamic>.from(
      user.userMetadata ?? const <String, dynamic>{},
    );
    await supabase.auth.updateUser(
      UserAttributes(
        data: {
          ...metadata,
          'display_name': trimmedName,
          'full_name': trimmedName,
          'name': trimmedName,
        },
      ),
    );

    final row = await supabase
        .from('profiles')
        .upsert({
          'id': user.id,
          'display_name': trimmedName,
          'email': normalizedEmail,
          'phone': normalizedPhone,
          'updated_at': now.toIso8601String(),
        }, onConflict: 'id')
        .select('id, display_name, email, phone, updated_at')
        .single();

    return CurrentUserProfile.fromSupabase(
      row,
      fallbackId: user.id,
      fallbackDisplayName: trimmedName,
      fallbackEmail: normalizedEmail,
      fallbackPhone: normalizedPhone,
    );
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

    final controller = StreamController<List<ChatThread>>();
    StreamSubscription<List<Map<String, dynamic>>>? conversationsSubscription;
    StreamSubscription<List<Map<String, dynamic>>>? membershipSubscription;
    RealtimeChannel? summaryUpdatesChannel;
    var requestId = 0;
    Timer? refreshTimer;

    Future<void> refreshVisibleThreads() async {
      final currentRequest = ++requestId;
      try {
        final threads = await fetchThreads();
        if (!controller.isClosed && currentRequest == requestId) {
          controller.add(threads);
        }
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      }
    }

    void scheduleRefresh() {
      refreshTimer?.cancel();
      refreshTimer = Timer(const Duration(milliseconds: 40), () {
        refreshTimer = null;
        unawaited(refreshVisibleThreads());
      });
    }

    void acknowledgePendingReceipt(PostgresChangePayload payload) {
      if (payload.eventType != PostgresChangeEvent.insert ||
          payload.newRecord['user_id']?.toString() != user.id) {
        return;
      }
      final conversationId =
          payload.newRecord['conversation_id']?.toString() ?? '';
      if (conversationId.isEmpty) {
        return;
      }

      unawaited(
        markConversationDelivered(conversationId).catchError((_) {
          // A later app-resume acknowledgement will retry transient failures.
        }),
      );
    }

    controller.onListen = () {
      conversationsSubscription = supabase
          .from('conversations')
          .stream(primaryKey: ['id'])
          .order('last_message_at')
          .listen((_) => scheduleRefresh(), onError: controller.addError);
      membershipSubscription = supabase
          .from('conversation_members')
          .stream(primaryKey: ['conversation_id', 'user_id'])
          .eq('user_id', user.id)
          .listen((_) => scheduleRefresh(), onError: controller.addError);
      final channel = supabase
          .channel('thread-summary-updates-${user.id}-${_uuid.v4()}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'messages',
            callback: (_) => scheduleRefresh(),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'message_receipts',
            callback: (payload) {
              acknowledgePendingReceipt(payload);
              scheduleRefresh();
            },
          );
      summaryUpdatesChannel = channel;
      channel.subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.channelError &&
            !controller.isClosed) {
          controller.addError(
            error ?? StateError('Conversation summary watch failed.'),
          );
        }
      });
      scheduleRefresh();
    };
    controller.onCancel = () async {
      refreshTimer?.cancel();
      await conversationsSubscription?.cancel();
      await membershipSubscription?.cancel();
      final channel = summaryUpdatesChannel;
      if (channel != null) {
        await supabase.removeChannel(channel);
      }
    };
    return controller.stream;
  }

  Future<List<ChatThread>> fetchThreads() async {
    final supabase = client;
    if (supabase == null) {
      return ChatSeed.threads;
    }
    final user = supabase.auth.currentUser;
    if (user == null) {
      return const [];
    }

    final rowsFuture = supabase.from('conversations').select();
    final summariesFuture = _conversationSummaries(supabase);
    final rows = await rowsFuture;
    final summaries = await summariesFuture;
    return _threadsFromConversationRows(
      List<Map<String, dynamic>>.from(rows),
      summaries: summaries,
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

  Future<void> markPendingMessagesDelivered() async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return;
    }

    await supabase
        .from('message_receipts')
        .update({'delivered_at': DateTime.now().toUtc().toIso8601String()})
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

  Future<ChatUser?> profileForUser(String userId) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return null;
    }

    final supabase = client;
    if (supabase == null) {
      for (final user in ChatSeed.users) {
        if (user.id == normalizedUserId) {
          return user;
        }
      }
      return null;
    }

    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) {
      return null;
    }

    final profiles = await _profilesById({normalizedUserId});
    return profiles[normalizedUserId];
  }

  Future<ChatThread> startDirectConversation(ChatUser peer) async {
    final supabase = client;
    if (supabase == null) {
      return _threadFromPeer(conversationId: 'direct-${peer.id}', peer: peer);
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
      return _threadFromDirectConversation(supabase, existing, peer);
    }

    try {
      final created = await supabase
          .from('conversations')
          .insert({'user_one_id': userOneId, 'user_two_id': userTwoId})
          .select()
          .single();

      return _threadFromDirectConversation(supabase, created, peer);
    } on PostgrestException {
      final raced = await supabase
          .from('conversations')
          .select()
          .eq('user_one_id', userOneId)
          .eq('user_two_id', userTwoId)
          .single();

      return _threadFromDirectConversation(supabase, raced, peer);
    }
  }

  Future<ChatThread> createGroupConversation({
    required String name,
    required List<ChatUser> members,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || normalizedName.length > 80) {
      throw ArgumentError('Group names must be between 1 and 80 characters.');
    }
    final distinctMembers = {for (final member in members) member.id: member};
    if (distinctMembers.length < 2 || distinctMembers.length > 49) {
      throw ArgumentError('Choose between 2 and 49 other members.');
    }

    final supabase = client;
    if (supabase == null) {
      return _threadFromGroup(
        row: {'id': 'group-${_uuid.v4()}', 'title': normalizedName},
        memberCount: distinctMembers.length + 1,
        isAdmin: true,
      );
    }
    if (supabase.auth.currentUser == null) {
      throw const AuthException('Sign in before creating a group.');
    }

    await upsertCurrentProfile();
    final result = await supabase.rpc(
      'create_group_conversation',
      params: {
        'group_name': normalizedName,
        'member_ids': distinctMembers.keys.toList(),
      },
    );
    final resultRow = switch (result) {
      Map<dynamic, dynamic> row => Map<String, dynamic>.from(row),
      List<dynamic> rows when rows.isNotEmpty && rows.first is Map =>
        Map<String, dynamic>.from(rows.first as Map),
      _ => throw StateError('Group creation returned no conversation.'),
    };
    return _threadFromGroup(
      row: resultRow,
      memberCount: distinctMembers.length + 1,
      isAdmin: true,
    );
  }

  Future<List<ChatGroupMember>> groupMembers(String conversationId) async {
    final supabase = client;
    if (supabase == null) {
      return [
        ChatGroupMember(
          user: ChatUser(id: localUserId, displayName: localSenderName),
          isAdmin: true,
          isCurrentUser: true,
          joinedAt: DateTime.now(),
        ),
        ...ChatSeed.users
            .take(3)
            .map(
              (user) => ChatGroupMember(
                user: user,
                isAdmin: false,
                isCurrentUser: false,
                joinedAt: DateTime.now(),
              ),
            ),
      ];
    }

    final rows = List<Map<String, dynamic>>.from(
      await supabase
          .from('conversation_members')
          .select('conversation_id, user_id, role, joined_at')
          .eq('conversation_id', conversationId)
          .order('joined_at'),
    );
    final profiles = await _profilesById(
      rows.map((row) => row['user_id']?.toString() ?? '').toSet(),
    );
    return rows.map((row) {
      final userId = row['user_id']?.toString() ?? '';
      return ChatGroupMember(
        user:
            profiles[userId] ??
            ChatUser(id: userId, displayName: 'Unknown user'),
        isAdmin: row['role'] == 'admin',
        isCurrentUser: userId == localUserId,
        joinedAt: _readTimestamp(row['joined_at']) ?? DateTime.now(),
      );
    }).toList();
  }

  Future<void> renameGroup(String conversationId, String name) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || normalizedName.length > 80) {
      throw ArgumentError('Group names must be between 1 and 80 characters.');
    }
    await client?.rpc(
      'rename_group_conversation',
      params: {
        'target_conversation_id': conversationId,
        'new_name': normalizedName,
      },
    );
  }

  Future<void> addGroupMember(String conversationId, ChatUser user) async {
    await client?.rpc(
      'add_group_member',
      params: {
        'target_conversation_id': conversationId,
        'new_member_id': user.id,
      },
    );
  }

  Future<void> removeGroupMember(String conversationId, String userId) async {
    await client?.rpc(
      'remove_group_member',
      params: {
        'target_conversation_id': conversationId,
        'removed_member_id': userId,
      },
    );
  }

  Future<void> leaveGroup(String conversationId) async {
    await client?.rpc(
      'leave_group_conversation',
      params: {'target_conversation_id': conversationId},
    );
  }

  Future<PickedChatMedia?> pickMediaAttachment(ChatMediaSource source) async {
    if (source == ChatMediaSource.giphy) {
      throw UnsupportedError('Use searchGiphyGifs before selecting a GIF.');
    }
    if (source == ChatMediaSource.camera) {
      throw UnsupportedError('Use captureMediaAttachment for camera photos.');
    }

    if (_isDesktopPlatform) {
      final file = await _openDesktopMediaFile();
      if (file == null) {
        return null;
      }

      late final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (error) {
        throw MediaAttachmentException(
          'Could not read that file.',
          details:
              'Desktop file read failed for "${file.name}" on '
              '$defaultTargetPlatform: $error',
        );
      }

      return pickedMediaFromBytes(
        bytes: bytes,
        originalName: file.name,
        mimeType: file.mimeType,
      );
    }

    final image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (image == null) {
      return null;
    }

    return pickedMediaFromBytes(
      bytes: await image.readAsBytes(),
      originalName: image.name,
      mimeType: image.mimeType,
    );
  }

  Future<file_selector.XFile?> _openDesktopMediaFile() async {
    try {
      return await file_selector.openFile(
        acceptedTypeGroups: const [
          file_selector.XTypeGroup(
            label: 'Images and GIFs',
            extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'heif'],
            mimeTypes: [
              'image/jpeg',
              'image/png',
              'image/webp',
              'image/gif',
              'image/heic',
              'image/heif',
            ],
            uniformTypeIdentifiers: ['public.image'],
          ),
        ],
      );
    } catch (error) {
      throw MediaAttachmentException(
        'Could not open the desktop photo picker.',
        details: 'Desktop file picker failed on $defaultTargetPlatform: $error',
      );
    }
  }

  Future<PickedChatMedia> pickedMediaFromBytes({
    required Uint8List bytes,
    required String originalName,
    String? mimeType,
  }) async {
    final sizeBytes = bytes.length;
    if (sizeBytes > maxMediaBytes) {
      throw MediaAttachmentException('Choose an image or GIF under 15 MB.');
    }

    final normalizedMimeType = _normalizedMimeType(
      mimeType ?? lookupMimeType(originalName, headerBytes: bytes),
    );
    if (!_allowedMediaTypes.contains(normalizedMimeType)) {
      throw MediaAttachmentException('Choose a JPEG, PNG, WebP, GIF, or HEIC.');
    }

    final dimensions = await _readImageDimensions(bytes);
    return PickedChatMedia(
      bytes: bytes,
      originalName: _safeOriginalName(originalName, normalizedMimeType),
      mimeType: normalizedMimeType,
      sizeBytes: sizeBytes,
      width: dimensions?.width,
      height: dimensions?.height,
    );
  }

  Future<PickedChatMedia> pickedVoiceMessageFromBytes({
    required Uint8List bytes,
    required Duration duration,
    required List<double> waveform,
    String originalName = 'voice-message.wav',
    String mimeType = 'audio/wav',
  }) async {
    final sizeBytes = bytes.length;
    if (sizeBytes <= 0) {
      throw const MediaAttachmentException('Record a voice message first.');
    }
    if (sizeBytes > maxMediaBytes) {
      throw const MediaAttachmentException('Record voice under 15 MB.');
    }

    final normalizedMimeType = _normalizedMimeType(mimeType);
    if (!_allowedVoiceTypes.contains(normalizedMimeType)) {
      throw const MediaAttachmentException(
        'Record WAV, AAC, MP3, MP4, WebM, or OGG audio.',
      );
    }

    return PickedChatMedia(
      bytes: bytes,
      originalName: _safeOriginalName(originalName, normalizedMimeType),
      mimeType: normalizedMimeType,
      sizeBytes: sizeBytes,
      duration: duration,
      waveform: waveform
          .map((level) => level.clamp(0.0, 1.0).toDouble())
          .toList(growable: false),
    );
  }

  Future<List<GiphyGif>> searchGiphyGifs(String query) async {
    if (giphyApiKey.isEmpty) {
      throw const MediaAttachmentException('Missing GIPHY API key.');
    }

    final trimmedQuery = query.trim();
    final endpoint = trimmedQuery.isEmpty ? 'trending' : 'search';
    final uri = Uri.https('api.giphy.com', '/v1/gifs/$endpoint', {
      'api_key': giphyApiKey,
      'limit': '24',
      'rating': 'g',
      if (trimmedQuery.isNotEmpty) 'q': trimmedQuery,
    });

    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw MediaAttachmentException(
        'Could not load GIFs.',
        details:
            'GIPHY $endpoint failed with HTTP ${response.statusCode}: '
            '${_compactLogValue(response.body)}',
      );
    }

    final payload = json.decode(response.body) as Map<String, dynamic>;
    final data = payload['data'];
    if (data is! List) {
      return const [];
    }

    return data
        .whereType<Map<String, dynamic>>()
        .map(_giphyGifFromJson)
        .whereType<GiphyGif>()
        .toList();
  }

  Future<PickedChatMedia> downloadGiphyGif(GiphyGif gif) async {
    final response = await http.get(Uri.parse(gif.originalUrl));
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw MediaAttachmentException(
        'Could not download that GIF.',
        details:
            'GIPHY download failed with HTTP ${response.statusCode}: '
            '${_compactLogValue(response.body)}',
      );
    }

    final bytes = response.bodyBytes;
    if (bytes.length > maxMediaBytes) {
      throw const MediaAttachmentException('Choose a GIF under 15 MB.');
    }

    return PickedChatMedia(
      bytes: bytes,
      originalName: 'giphy-${gif.id}.gif',
      mimeType: 'image/gif',
      sizeBytes: bytes.length,
      width: gif.width,
      height: gif.height,
    );
  }

  UploadedChatMedia prepareLocalMediaAttachment({
    required String conversationId,
    required PickedChatMedia pickedMedia,
  }) {
    final messageId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    return UploadedChatMedia(
      messageId: messageId,
      media: ChatMedia(
        bucket: mediaBucket,
        path:
            '$conversationId/$localUserId/$messageId${_extensionFor(pickedMedia)}',
        mimeType: pickedMedia.mimeType,
        sizeBytes: pickedMedia.sizeBytes,
        width: pickedMedia.width,
        height: pickedMedia.height,
        duration: pickedMedia.duration,
        waveform: pickedMedia.waveform,
        originalName: pickedMedia.originalName,
        localBytes: pickedMedia.bytes,
      ),
    );
  }

  @override
  Future<UploadedChatMedia> uploadMediaAttachment({
    required String conversationId,
    required PickedChatMedia pickedMedia,
    required void Function(double progress) onProgress,
    String? messageId,
    bool upsert = false,
  }) async {
    final supabase = client;
    if (supabase == null) {
      return prepareLocalMediaAttachment(
        conversationId: conversationId,
        pickedMedia: pickedMedia,
      );
    }

    final user = supabase.auth.currentUser;
    final session = supabase.auth.currentSession;
    if (user == null || session == null) {
      throw const AuthException('Sign in before sending media.');
    }

    final ready = await _requireE2eeReady();
    final device = ready.device;
    if (device == null) {
      throw const E2eeCryptoException('This device has no encrypted identity.');
    }
    final resolvedMessageId = messageId ?? _uuid.v4();
    final epoch = await _currentEpochForSend(
      conversationId: conversationId,
      ready: ready,
    );
    final encrypted = await _crypto.encryptMedia(
      userId: user.id,
      conversationId: conversationId,
      messageId: resolvedMessageId,
      epoch: epoch,
      bytes: pickedMedia.bytes,
      mediaId: _uuid.v4(),
      mimeType: pickedMedia.mimeType,
      fileName: pickedMedia.originalName,
    );
    final objectPath = '$conversationId/${user.id}/$resolvedMessageId.bin';
    final storage = supabase.storage.from(mediaBucket);
    final uploadUri = _chatMediaUploadUri(
      storageUrl: storage.url,
      objectPath: objectPath,
    );
    final uploadHeaders = {
      ...storage.headers,
      'authorization': 'Bearer ${session.accessToken}',
    };

    await _uploadBytesWithProgress(
      uri: uploadUri,
      headers: uploadHeaders,
      bytes: encrypted.toStorageBytes(),
      fileName: '$resolvedMessageId.bin',
      mimeType: 'application/octet-stream',
      onProgress: onProgress,
      upsert: upsert,
    );

    onProgress(1);

    return UploadedChatMedia(
      messageId: resolvedMessageId,
      media: ChatMedia(
        bucket: mediaBucket,
        path: objectPath,
        mimeType: pickedMedia.mimeType,
        sizeBytes: pickedMedia.sizeBytes,
        width: pickedMedia.width,
        height: pickedMedia.height,
        duration: pickedMedia.duration,
        waveform: pickedMedia.waveform,
        originalName: pickedMedia.originalName,
        isEncrypted: true,
        conversationId: conversationId,
        messageId: resolvedMessageId,
        encryptionEpoch: epoch.epochNumber,
        encryptionEpochId: epoch.serverEpochId,
        encryptionSenderDeviceId: device.id,
        encryptionMetadata: encrypted.toJson(),
      ),
    );
  }

  @visibleForTesting
  static Uri chatMediaUploadUriForTesting({
    required String storageUrl,
    required String objectPath,
  }) {
    return _chatMediaUploadUri(storageUrl: storageUrl, objectPath: objectPath);
  }

  @visibleForTesting
  static Future<void> uploadBytesWithProgressForTesting({
    required Uri uri,
    required Map<String, String> headers,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required void Function(double progress) onProgress,
    http.Client? httpClient,
    bool upsert = false,
  }) {
    return _uploadBytesWithProgress(
      uri: uri,
      headers: headers,
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
      onProgress: onProgress,
      httpClient: httpClient,
      upsert: upsert,
    );
  }

  Future<String> signedMediaUrl(ChatMedia media) async {
    final supabase = client;
    if (supabase == null) {
      throw StateError('Local media does not need a signed URL.');
    }
    if (media.isEncrypted) {
      throw StateError(
        'Encrypted media must be downloaded and decrypted in memory.',
      );
    }

    return supabase.storage
        .from(media.bucket)
        .createSignedUrl(media.path, const Duration(hours: 1).inSeconds);
  }

  Future<bool> saveMediaAttachment(ChatMedia media) async {
    final fileName = _safeDownloadName(media);
    final mimeType = _fileSaverMimeType(media.mimeType);
    final bytes = await mediaBytes(media);

    if (_isLinuxPlatform) {
      return _saveMediaWithFileSelector(
        fileName: fileName,
        media: media,
        bytes: bytes,
      );
    }

    final path = await FileSaver.instance.saveAs(
      name: _downloadBaseName(fileName),
      bytes: bytes,
      fileExtension: _downloadExtensionFor(fileName),
      mimeType: mimeType,
      customMimeType: mimeType == MimeType.custom ? media.mimeType : null,
    );
    if (path == null) {
      return false;
    }
    if (path.trim().isEmpty || path == 'Failed to save file') {
      throw const MediaAttachmentException('Could not save media.');
    }
    return true;
  }

  Future<bool> _saveMediaWithFileSelector({
    required String fileName,
    required ChatMedia media,
    required Uint8List bytes,
  }) async {
    final location = await file_selector.getSaveLocation(
      acceptedTypeGroups: _downloadTypeGroupsFor(media, fileName),
      suggestedName: fileName,
      confirmButtonText: 'Save',
    );
    if (location == null) {
      return false;
    }

    final file = file_selector.XFile.fromData(
      bytes,
      mimeType: media.mimeType,
      name: fileName,
      length: bytes.length,
    );
    await file.saveTo(location.path);
    return true;
  }

  Future<Uint8List> mediaBytes(ChatMedia media) async {
    final localBytes = media.localBytes;
    if (localBytes != null) {
      return localBytes;
    }

    final supabase = client;
    if (supabase == null) {
      throw StateError('Encrypted media is unavailable in local preview.');
    }
    final signedUrl = media.isEncrypted
        ? await supabase.storage
              .from(media.bucket)
              .createSignedUrl(media.path, const Duration(hours: 1).inSeconds)
        : await signedMediaUrl(media);
    final response = await http.get(Uri.parse(signedUrl));
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw MediaAttachmentException(
        'Could not download that media.',
        details:
            'Media download failed with HTTP ${response.statusCode}: '
            '${_compactLogValue(response.body)}',
      );
    }
    if (!media.isEncrypted) {
      return response.bodyBytes;
    }

    final conversationId = media.conversationId;
    final messageId = media.messageId;
    final epochNumber = media.encryptionEpoch;
    final senderDeviceId = media.encryptionSenderDeviceId;
    final metadata = media.encryptionMetadata;
    if (conversationId == null ||
        messageId == null ||
        epochNumber == null ||
        senderDeviceId == null ||
        metadata == null) {
      throw const E2eeCryptoException(
        'Encrypted media is missing authenticated key context.',
      );
    }
    final epoch = await _epochForRecord(
      conversationId: conversationId,
      epochId: media.encryptionEpochId,
      epochNumber: epochNumber,
    );
    if (epoch == null) {
      throw const E2eeCryptoException(
        'The key for this encrypted media is unavailable on this device.',
      );
    }
    final sender = await _deviceIdentityFor(
      conversationId: conversationId,
      deviceId: senderDeviceId,
    );
    final encrypted = E2eeEncryptedMedia.fromJson(
      Map<String, dynamic>.from(metadata),
    ).withCiphertextBytes(response.bodyBytes);
    return _crypto.decryptMedia(
      conversationId: conversationId,
      messageId: messageId,
      encryptedMedia: encrypted,
      epoch: epoch,
      senderDevice: sender,
      mimeType: media.mimeType,
      fileName: media.originalName ?? '',
    );
  }

  Future<void> deleteStagedMedia(ChatMedia media) async {
    final supabase = client;
    if (supabase == null || media.path.isEmpty) {
      return;
    }

    try {
      await supabase.storage.from(media.bucket).remove([media.path]);
    } catch (_) {
      // Staged media cleanup is best-effort; failed deletes should not break chat.
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
    var receiptsByMessageId = <String, List<MessageReceipt>>{};
    var legacyReactionRows = <Map<String, dynamic>>[];
    var encryptedReactionRows = <Map<String, dynamic>>[];
    StreamSubscription<List<Map<String, dynamic>>>? messagesSubscription;
    StreamSubscription<List<Map<String, dynamic>>>? receiptsSubscription;
    StreamSubscription<List<Map<String, dynamic>>>? legacyReactionsSubscription;
    StreamSubscription<List<Map<String, dynamic>>>?
    encryptedReactionsSubscription;
    var renderGeneration = 0;

    void emitMessages() {
      if (controller.isClosed) {
        return;
      }
      final generation = ++renderGeneration;
      final messageRows = messagesById.values
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      final receiptSnapshot = Map<String, List<MessageReceipt>>.from(
        receiptsByMessageId,
      );
      final legacySnapshot = legacyReactionRows
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      final encryptedSnapshot = encryptedReactionRows
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      unawaited(() async {
        try {
          final hydrated = await Future.wait(
            messageRows.map(
              (row) => _hydrateEncryptedMessage(
                row,
                localUserId: user.id,
                receipt: _aggregateReceipts(
                  receiptSnapshot[row['id']?.toString()],
                ),
              ),
            ),
          );
          final baseMessages = <String, ChatMessage>{
            for (final message in hydrated) message.id: message,
          };
          final reactionsByMessageId = <String, List<Map<String, dynamic>>>{};
          for (final row in legacySnapshot) {
            final messageId = row['message_id']?.toString() ?? '';
            if (baseMessages[messageId]?.isEncrypted ?? false) continue;
            reactionsByMessageId.putIfAbsent(messageId, () => []).add(row);
          }
          final decryptedReactions = await Future.wait(
            encryptedSnapshot.map(
              (row) => _decryptEncryptedReaction(
                row,
                conversationId: conversationId,
                messageId: row['message_id']?.toString() ?? '',
              ),
            ),
          );
          for (var index = 0; index < decryptedReactions.length; index += 1) {
            final reaction = decryptedReactions[index];
            if (reaction == null) continue;
            final source = encryptedSnapshot[index];
            final messageId = source['message_id']?.toString() ?? '';
            if (!(baseMessages[messageId]?.isEncrypted ?? false)) continue;
            reactionsByMessageId.putIfAbsent(messageId, () => []).add(
              <String, dynamic>{
                'emoji': reaction.emoji,
                'user_id': source['user_id'],
              },
            );
          }

          final messages = <ChatMessage>[];
          for (final message in hydrated) {
            if (!message.isEncrypted) continue;
            final row = messageRows.firstWhere(
              (candidate) => candidate['id']?.toString() == message.id,
            );
            final replyId =
                message.encryptionState == ChatMessageEncryptionState.legacy
                ? _nullableText(row['reply_to_message_id'])
                : message.replyTo?.messageId;
            final reply = replyId == null ? null : baseMessages[replyId];
            messages.add(
              message.isDeleted
                  ? message
                  : message.copyWith(
                      replyTo: reply == null
                          ? null
                          : MessageReplyPreview.fromMessage(reply),
                      reactions: summarizeMessageReactions(
                        reactionsByMessageId[message.id] ?? const [],
                        localUserId: user.id,
                      ),
                    ),
            );
          }
          messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          if (!controller.isClosed && generation == renderGeneration) {
            controller.add(messages);
          }
        } catch (error, stackTrace) {
          if (!controller.isClosed && generation == renderGeneration) {
            controller.addError(error, stackTrace);
          }
        }
      }());
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
          receiptsByMessageId = {};
          for (final row in rows) {
            if (row['user_id']?.toString() == user.id) continue;
            final receipt = MessageReceipt.fromSupabase(row);
            receiptsByMessageId
                .putIfAbsent(receipt.messageId, () => [])
                .add(receipt);
          }
          emitMessages();
        }, onError: controller.addError);

    legacyReactionsSubscription = supabase
        .from('message_reactions')
        .stream(primaryKey: ['message_id', 'user_id', 'emoji'])
        .eq('conversation_id', conversationId)
        .listen((rows) {
          legacyReactionRows = rows;
          emitMessages();
        }, onError: controller.addError);

    encryptedReactionsSubscription = supabase
        .from('encrypted_message_reactions')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .listen((rows) {
          encryptedReactionRows = rows;
          emitMessages();
        }, onError: controller.addError);

    controller.onCancel = () async {
      await messagesSubscription?.cancel();
      await receiptsSubscription?.cancel();
      await legacyReactionsSubscription?.cancel();
      await encryptedReactionsSubscription?.cancel();
    };

    return controller.stream;
  }

  Stream<ChatMessage> watchIncomingMessages() {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return const Stream.empty();
    }

    late final RealtimeChannel channel;
    final controller = StreamController<ChatMessage>();
    controller.onListen = () {
      channel = supabase
          .channel('incoming-messages-${user.id}-${_uuid.v4()}')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'messages',
            callback: (payload) {
              unawaited(() async {
                try {
                  final message = await _hydrateEncryptedMessage(
                    Map<String, dynamic>.from(payload.newRecord),
                    localUserId: user.id,
                  );
                  if (!message.isMine && !controller.isClosed) {
                    controller.add(message);
                  }
                } catch (error, stackTrace) {
                  if (!controller.isClosed) {
                    controller.addError(error, stackTrace);
                  }
                }
              }());
            },
          );
      channel.subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.channelError &&
            !controller.isClosed) {
          controller.addError(
            error ?? StateError('Incoming message watch failed.'),
          );
        }
      });
    };
    controller.onCancel = () async {
      await channel.unsubscribe();
    };
    return controller.stream;
  }

  @override
  Future<bool> messageExists(String messageId) async {
    final supabase = client;
    if (supabase == null || messageId.isEmpty) {
      return false;
    }

    final row = await supabase
        .from('messages')
        .select('id')
        .eq('id', messageId)
        .maybeSingle();
    return row != null;
  }

  @override
  Future<void> sendMessage({
    required String conversationId,
    required String body,
    String? messageId,
    String? replyToMessageId,
    bool isForwarded = false,
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
    final ready = await _requireE2eeReady();
    final device = ready.device;
    if (device == null) {
      throw const E2eeCryptoException('This device has no encrypted identity.');
    }
    final resolvedMessageId = messageId ?? _uuid.v4();
    final epoch = await _currentEpochForSend(
      conversationId: conversationId,
      ready: ready,
    );
    final payload = await _crypto.encryptMessage(
      userId: user.id,
      conversationId: conversationId,
      messageId: resolvedMessageId,
      epoch: epoch,
      plaintext: _encodeMessageContent(
        body: trimmed,
        messageType: ChatMessageType.text,
        senderName: localSenderName,
        replyToMessageId: replyToMessageId,
        isForwarded: isForwarded,
      ),
    );
    await supabase.rpc(
      'send_encrypted_message',
      params: <String, dynamic>{
        'p_conversation_id': conversationId,
        'p_sender_device_id': device.id,
        'p_epoch_id': epoch.serverEpochId,
        'p_ciphertext': payload.ciphertext,
        'p_nonce': payload.nonce,
        'p_signature': payload.signature,
        'p_message_type': ChatMessageType.text.value,
        'p_media_bucket': null,
        'p_media_path': null,
        'p_message_id': resolvedMessageId,
      },
    );
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
    final supabase = client;
    if (supabase == null) {
      return;
    }

    final user = supabase.auth.currentUser;
    if (user == null) {
      throw const AuthException('Sign in before sending media.');
    }
    if (!media.isEncrypted ||
        media.encryptionMetadata == null ||
        media.encryptionEpoch == null) {
      throw const E2eeCryptoException(
        'Attach media again so it can be encrypted before sending.',
      );
    }
    final ready = await _requireE2eeReady();
    final device = ready.device;
    if (device == null) {
      throw const E2eeCryptoException('This device has no encrypted identity.');
    }
    final epoch = await _currentEpochForSend(
      conversationId: conversationId,
      ready: ready,
    );
    if (media.encryptionEpoch != epoch.epochNumber ||
        media.encryptionEpochId != epoch.serverEpochId) {
      throw const E2eeCryptoException(
        'Conversation keys changed. Attach the media again before sending.',
      );
    }
    final messageType = _messageTypeForMedia(media);
    final payload = await _crypto.encryptMessage(
      userId: user.id,
      conversationId: conversationId,
      messageId: messageId,
      epoch: epoch,
      plaintext: _encodeMessageContent(
        body: body.trim(),
        messageType: messageType,
        media: media,
        senderName: localSenderName,
        replyToMessageId: replyToMessageId,
        isForwarded: isForwarded,
      ),
    );
    await supabase.rpc(
      'send_encrypted_message',
      params: <String, dynamic>{
        'p_conversation_id': conversationId,
        'p_sender_device_id': device.id,
        'p_epoch_id': epoch.serverEpochId,
        'p_ciphertext': payload.ciphertext,
        'p_nonce': payload.nonce,
        'p_signature': payload.signature,
        'p_message_type': messageType.value,
        'p_media_bucket': media.bucket,
        'p_media_path': media.path,
        'p_message_id': messageId,
      },
    );
  }

  Future<void> editMessage({
    required ChatMessage message,
    required String body,
  }) async {
    final supabase = client;
    if (supabase == null) {
      return;
    }
    if (!message.isEncrypted) {
      throw const E2eeCryptoException(
        'Legacy messages are read-only and cannot be edited.',
      );
    }
    if (message.isLocked || message.hasInvalidEncryption) {
      throw const E2eeCryptoException('This encrypted message is unavailable.');
    }
    final user = supabase.auth.currentUser;
    if (user == null) {
      throw const AuthException('Sign in before editing messages.');
    }
    final ready = await _requireE2eeReady();
    final device = ready.device;
    if (device == null) {
      throw const E2eeCryptoException('This device has no encrypted identity.');
    }
    final epoch = await _currentEpochForSend(
      conversationId: message.threadId,
      ready: ready,
    );
    final revision = (message.encryptionRevision ?? 0) + 1;
    final payload = await _crypto.encryptMessage(
      userId: user.id,
      conversationId: message.threadId,
      messageId: message.id,
      epoch: epoch,
      revision: revision,
      plaintext: _encodeMessageContent(
        body: body.trim(),
        messageType: message.messageType,
        media: message.media,
        senderName: message.senderName,
        replyToMessageId: message.replyTo?.messageId,
        isForwarded: message.isForwarded,
      ),
    );
    await supabase.rpc(
      'edit_encrypted_message',
      params: <String, dynamic>{
        'p_message_id': message.id,
        'p_sender_device_id': device.id,
        'p_epoch_id': epoch.serverEpochId,
        'p_revision': revision,
        'p_ciphertext': payload.ciphertext,
        'p_nonce': payload.nonce,
        'p_signature': payload.signature,
      },
    );
  }

  Future<void> deleteMessage(ChatMessage message) async {
    final supabase = client;
    if (supabase == null) {
      return;
    }
    final result = await supabase.rpc(
      'delete_message',
      params: {'target_message_id': message.id},
    );
    if (result is! List || result.isEmpty || result.first is! Map) {
      return;
    }
    final row = Map<String, dynamic>.from(result.first as Map);
    final bucket = row['media_bucket']?.toString();
    final path = row['media_path']?.toString();
    if (bucket == null || bucket.isEmpty || path == null || path.isEmpty) {
      return;
    }
    try {
      await supabase.storage.from(bucket).remove([path]);
    } catch (error) {
      debugPrint('[Message delete] Orphaned media cleanup failed: $error');
    }
  }

  Future<void> toggleMessageReaction({
    required ChatMessage message,
    required String emoji,
  }) async {
    final supabase = client;
    if (supabase == null) {
      return;
    }
    if (!message.isEncrypted) {
      throw const E2eeCryptoException(
        'Legacy messages are read-only and cannot receive new reactions.',
      );
    }
    if (message.isLocked || message.hasInvalidEncryption) {
      throw const E2eeCryptoException('This encrypted message is unavailable.');
    }
    final user = supabase.auth.currentUser;
    if (user == null) {
      throw const AuthException('Sign in before reacting to messages.');
    }
    final ready = await _requireE2eeReady();
    final device = ready.device;
    if (device == null) {
      throw const E2eeCryptoException('This device has no encrypted identity.');
    }
    final epoch = await _currentEpochForSend(
      conversationId: message.threadId,
      ready: ready,
    );
    final existing = await _existingEncryptedReaction(
      conversationId: message.threadId,
      messageId: message.id,
      userId: user.id,
      emoji: emoji,
    );
    if (existing != null) {
      await supabase.rpc(
        'set_encrypted_reaction',
        params: <String, dynamic>{
          'p_message_id': message.id,
          'p_sender_device_id': device.id,
          'p_epoch_id': epoch.serverEpochId,
          'p_reaction_tag': existing.reactionTag,
          'p_is_active': false,
        },
      );
      return;
    }
    final encrypted = await _crypto.encryptReaction(
      userId: user.id,
      conversationId: message.threadId,
      messageId: message.id,
      epoch: epoch,
      emoji: emoji,
    );
    await supabase.rpc(
      'set_encrypted_reaction',
      params: <String, dynamic>{
        'p_message_id': message.id,
        'p_sender_device_id': device.id,
        'p_epoch_id': epoch.serverEpochId,
        'p_reaction_tag': encrypted.reactionTag,
        'p_is_active': true,
        'p_ciphertext': encrypted.ciphertext,
        'p_nonce': encrypted.nonce,
        'p_signature': encrypted.signature,
      },
    );
  }

  Future<PickedChatMedia> mediaForForward(ChatMedia media) async {
    final bytes = await mediaBytes(media);
    return PickedChatMedia(
      bytes: bytes,
      originalName: media.originalName ?? 'forwarded-media',
      mimeType: media.mimeType,
      sizeBytes: bytes.length,
      width: media.width,
      height: media.height,
      duration: media.duration,
      waveform: media.waveform,
    );
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

  Future<E2eeEpoch> _currentEpochForSend({
    required String conversationId,
    required E2eeReadyState ready,
  }) async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    final device = ready.device;
    if (supabase == null || user == null || device == null) {
      throw const E2eeCryptoException(
        'Encrypted messaging is unavailable until this device is ready.',
      );
    }
    final state = await supabase
        .from('conversation_crypto_state')
        .select(
          'conversation_id, membership_version, active_epoch_number, '
          'active_epoch_id, rekey_required',
        )
        .eq('conversation_id', conversationId)
        .maybeSingle();
    if (state == null) {
      throw const E2eeCryptoException(
        'Encrypted conversation state is missing.',
      );
    }
    final membershipVersion = _intValue(state['membership_version']) ?? 0;
    final epochNumber = _intValue(state['active_epoch_number']);
    final epochId = _nullableText(state['active_epoch_id']);
    final rekeyRequired = state['rekey_required'] == true;

    if (!rekeyRequired && epochNumber != null && epochId != null) {
      final cached = await _crypto.cachedEpoch(
        userId: user.id,
        conversationId: conversationId,
        epochNumber: epochNumber,
      );
      if (cached != null && cached.serverEpochId == epochId) {
        return cached;
      }
      final opened = await _openEpochFromServer(
        conversationId: conversationId,
        epochId: epochId,
        epochNumber: epochNumber,
        ready: ready,
      );
      if (opened != null) return opened;
      throw const E2eeCryptoException(
        'The current conversation key is unavailable on this device.',
      );
    }

    return _publishCurrentEpoch(
      conversationId: conversationId,
      membershipVersion: membershipVersion,
      nextEpochNumber: (epochNumber ?? 0) + 1,
      ready: ready,
    );
  }

  Future<E2eeEpoch> _publishCurrentEpoch({
    required String conversationId,
    required int membershipVersion,
    required int nextEpochNumber,
    required E2eeReadyState ready,
  }) async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    final device = ready.device;
    if (supabase == null || user == null || device == null) {
      throw const E2eeCryptoException(
        'Encrypted messaging is unavailable until this device is ready.',
      );
    }
    final materialResult = await supabase.rpc(
      'get_conversation_e2ee_key_material',
      params: <String, dynamic>{'p_conversation_id': conversationId},
    );
    final material = _mapRows(materialResult);
    final activeMembers = _mapRows(
      await supabase
          .from('conversation_members')
          .select('user_id')
          .eq('conversation_id', conversationId)
          .isFilter('left_at', null),
    ).map((row) => _nullableText(row['user_id'])).whereType<String>().toSet();
    final membersWithAccounts = material
        .where((row) => row['recipient_kind']?.toString() == 'recovery')
        .map((row) => _nullableText(row['recipient_user_id']))
        .whereType<String>()
        .toSet();
    final membersWithDevices = material
        .where((row) => row['recipient_kind']?.toString() == 'device')
        .map((row) => _nullableText(row['recipient_user_id']))
        .whereType<String>()
        .toSet();
    if (activeMembers.isEmpty ||
        activeMembers.difference(membersWithAccounts).isNotEmpty) {
      throw const E2eeCryptoException(
        'Waiting for every conversation member to finish encryption setup.',
      );
    }
    if (activeMembers.difference(membersWithDevices).isNotEmpty) {
      throw const E2eeCryptoException(
        'Waiting for every conversation member to register an encryption device.',
      );
    }
    final recipients = <E2eeEpochRecipient>[];
    for (final row in material) {
      final recipient = E2eeEpochRecipient.fromBackend(row);
      if (recipient.userId.isEmpty || recipient.encryptionPublicKey.isEmpty) {
        throw const E2eeCryptoException(
          'A conversation member has incomplete E2EE key material.',
        );
      }
      final accountSigningKey =
          row['account_signing_public_key']?.toString() ?? '';
      if (accountSigningKey.isEmpty) {
        throw const E2eeCryptoException(
          'A conversation member has an invalid E2EE identity.',
        );
      }
      await _observeRemoteAccount(
        userId: recipient.userId,
        signingPublicKey: accountSigningKey,
      );
      if (recipient.isDevice) {
        final identity = E2eeDeviceIdentity.fromBackend(row);
        await _ensureDeviceIdentity(identity, conversationId: conversationId);
      }
      recipients.add(recipient);
    }
    final epoch = await _crypto.createEpoch(
      userId: user.id,
      conversationId: conversationId,
      epochNumber: nextEpochNumber,
      membershipVersion: membershipVersion,
      serverEpochId: _uuid.v4(),
    );
    final envelopes = await Future.wait(
      recipients.map(
        (recipient) =>
            _crypto.sealEpochForRecipient(epoch: epoch, recipient: recipient),
      ),
    );
    final result = await supabase.rpc(
      'publish_conversation_epoch',
      params: <String, dynamic>{
        'p_conversation_id': conversationId,
        'p_epoch_id': epoch.serverEpochId,
        'p_epoch_number': epoch.epochNumber,
        'p_membership_version': epoch.membershipVersion,
        'p_creator_device_id': device.id,
        'p_commitment': epoch.commitment,
        'p_signature': epoch.signature,
        'p_envelopes': envelopes.map((envelope) => envelope.toJson()).toList(),
      },
    );
    final returned = _mapRows(result);
    if (returned.isEmpty) {
      throw const E2eeCryptoException(
        'The conversation key was not published.',
      );
    }
    final returnedId = _nullableText(returned.first['epoch_id']);
    if (returnedId == null || returnedId != epoch.serverEpochId) {
      throw const E2eeCryptoException(
        'The published conversation key did not match this device.',
      );
    }
    await _crypto.rememberEpoch(userId: user.id, epoch: epoch);
    return epoch;
  }

  Future<E2eeEpoch?> _epochForRecord({
    required String conversationId,
    required String? epochId,
    required int epochNumber,
  }) async {
    if (conversationId.isEmpty || epochNumber < 1) return null;
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) return null;
    final cached = await _crypto.cachedEpoch(
      userId: user.id,
      conversationId: conversationId,
      epochNumber: epochNumber,
    );
    if (cached != null &&
        (epochId == null || cached.serverEpochId == epochId)) {
      return cached;
    }
    final ready = await e2eeReadyState();
    if (!ready.isReadyForSending) return null;
    return _openEpochFromServer(
      conversationId: conversationId,
      epochId: epochId,
      epochNumber: epochNumber,
      ready: ready,
    );
  }

  Future<E2eeEpoch?> _openEpochFromServer({
    required String conversationId,
    required String? epochId,
    required int epochNumber,
    required E2eeReadyState ready,
  }) async {
    final supabase = client;
    final user = supabase?.auth.currentUser;
    final device = ready.device;
    if (supabase == null || user == null || device == null) return null;

    Future<E2eeEpoch?> openFrom(Object? result, bool useRecoveryKey) async {
      final matching = _mapRows(result).where((row) {
        return row['conversation_id']?.toString() == conversationId &&
            _intValue(row['epoch_number']) == epochNumber &&
            (epochId == null || row['epoch_id']?.toString() == epochId);
      }).toList();
      if (matching.isEmpty) return null;
      var envelope = E2eeKeyEnvelope.fromBackend(matching.last);
      var creator = envelope.creator;
      if (creator.encryptionPublicKey.isEmpty) {
        creator = await _deviceIdentityFor(
          conversationId: conversationId,
          deviceId: creator.deviceId,
        );
        envelope = envelope.copyWith(creator: creator);
      } else {
        await _ensureDeviceIdentity(creator, conversationId: conversationId);
      }
      return _crypto.openEpochEnvelope(
        userId: user.id,
        envelope: envelope,
        useRecoveryKey: useRecoveryKey,
      );
    }

    try {
      final deviceResult = await supabase.rpc(
        'get_e2ee_device_envelopes',
        params: <String, dynamic>{'p_device_id': device.id},
      );
      final deviceEpoch = await openFrom(deviceResult, false);
      if (deviceEpoch != null) return deviceEpoch;
    } on PostgrestException catch (error) {
      if (!error.message.toLowerCase().contains('device')) rethrow;
      // A revoked/replaced local device can still recover this epoch through
      // the account recovery envelope below.
    }

    try {
      final recoveryResult = await supabase.rpc('get_e2ee_recovery_envelopes');
      return openFrom(recoveryResult, true);
    } on PostgrestException {
      return null;
    }
  }

  Future<void> _observeRemoteAccount({
    required String userId,
    required String signingPublicKey,
  }) async {
    if (userId.isEmpty || signingPublicKey.isEmpty) {
      throw const E2eeCryptoException('An E2EE account identity is invalid.');
    }
    if (userId == _currentUser?.id) return;
    final trust = await _crypto.observeAccountIdentity(
      userId: userId,
      signingPublicKey: signingPublicKey,
    );
    if (trust.isSendBlocked) {
      throw const E2eeCryptoException(
        'A verified safety number changed. Verify the contact before sending.',
      );
    }
  }

  Future<void> _ensureDeviceIdentity(
    E2eeDeviceIdentity identity, {
    String? conversationId,
  }) async {
    if (identity.deviceId.isEmpty ||
        identity.userId.isEmpty ||
        identity.signingPublicKey.isEmpty ||
        identity.certificate.isEmpty ||
        identity.accountSigningPublicKey.isEmpty) {
      throw const E2eeCryptoException('An E2EE device identity is invalid.');
    }
    if (identity.encryptionPublicKey.isEmpty &&
        conversationId != null &&
        conversationId.isNotEmpty) {
      identity = await _deviceIdentityFor(
        conversationId: conversationId,
        deviceId: identity.deviceId,
      );
    }
    await _observeRemoteAccount(
      userId: identity.userId,
      signingPublicKey: identity.accountSigningPublicKey,
    );
    await _crypto.verifyDeviceIdentity(identity);
    _deviceIdentities[identity.deviceId] = identity;
  }

  Future<E2eeDeviceIdentity> _deviceIdentityFor({
    required String conversationId,
    required String deviceId,
  }) async {
    final cached = _deviceIdentities[deviceId];
    if (cached != null) return cached;
    final supabase = client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null || deviceId.isEmpty) {
      throw const E2eeCryptoException('The sender E2EE device is unavailable.');
    }
    final ready = await e2eeReadyState();
    final localDevice = ready.device;
    final localAccount = ready.account;
    if (localDevice != null &&
        localAccount != null &&
        localDevice.id == deviceId) {
      final identity = E2eeDeviceIdentity(
        deviceId: localDevice.id,
        userId: user.id,
        encryptionPublicKey: localDevice.encryptionPublicKey,
        signingPublicKey: localDevice.signingPublicKey,
        certificate: localDevice.certificate,
        accountSigningPublicKey: localAccount.signingPublicKey,
      );
      await _ensureDeviceIdentity(identity, conversationId: conversationId);
      return identity;
    }
    final result = await supabase.rpc(
      'get_conversation_e2ee_device_identities',
      params: <String, dynamic>{
        'p_conversation_id': conversationId,
        'p_device_ids': <String>[deviceId],
      },
    );
    final rows = _mapRows(result);
    if (rows.isEmpty) {
      throw const E2eeCryptoException('The sender E2EE device is unavailable.');
    }
    final identity = E2eeDeviceIdentity.fromBackend(rows.first);
    await _ensureDeviceIdentity(identity, conversationId: conversationId);
    return identity;
  }

  String _encodeMessageContent({
    required String body,
    required ChatMessageType messageType,
    required String senderName,
    String? replyToMessageId,
    ChatMedia? media,
    bool isForwarded = false,
  }) {
    if (messageType == ChatMessageType.call) {
      throw const E2eeCryptoException(
        'Call media encryption is not part of encrypted messaging v1.',
      );
    }
    if (messageType == ChatMessageType.text && media != null) {
      throw const E2eeCryptoException('Text messages cannot include media.');
    }
    if (messageType != ChatMessageType.text && media == null) {
      throw const E2eeCryptoException('Encrypted media metadata is missing.');
    }
    return jsonEncode(<String, dynamic>{
      'version': E2eeCryptoService.protocolVersion,
      'message_type': messageType.value,
      'body': body,
      'sender_name': senderName,
      'reply_to_message_id': replyToMessageId,
      'is_forwarded': isForwarded,
      if (media != null) 'media': _encodeMediaContent(media),
    });
  }

  Map<String, dynamic> _encodeMediaContent(ChatMedia media) {
    final metadata = media.encryptionMetadata;
    final epochNumber = media.encryptionEpoch;
    final epochId = media.encryptionEpochId;
    if (!media.isEncrypted ||
        metadata == null ||
        epochNumber == null ||
        epochId == null ||
        media.originalName == null ||
        media.originalName!.isEmpty) {
      throw const E2eeCryptoException(
        'Encrypted media is missing authenticated metadata.',
      );
    }
    return <String, dynamic>{
      'mime_type': media.mimeType,
      'bucket': media.bucket,
      'path': media.path,
      'size_bytes': media.sizeBytes,
      'width': media.width,
      'height': media.height,
      'duration_ms': media.duration?.inMilliseconds,
      'waveform': media.waveform,
      'original_name': media.originalName,
      'epoch_number': epochNumber,
      'epoch_id': epochId,
      'encryption': Map<String, dynamic>.from(metadata),
    };
  }

  ChatMessageType _messageTypeForMedia(ChatMedia media) {
    if (media.isVoice) return ChatMessageType.voice;
    if (media.isGif) return ChatMessageType.gif;
    return ChatMessageType.image;
  }

  Future<ChatMessage> _hydrateEncryptedMessage(
    Map<String, dynamic> row, {
    required String localUserId,
    MessageReceipt? receipt,
  }) async {
    final base = ChatMessage.fromSupabase(
      row,
      localUserId: localUserId,
      receipt: receipt,
    );
    if (!base.isLocked) return base;
    if (base.isDeleted) {
      return base.copyWith(
        encryptionState: ChatMessageEncryptionState.encrypted,
      );
    }
    final epochNumber = base.encryptionEpoch;
    final senderDeviceId = _nullableText(row['e2ee_sender_device_id']);
    if (epochNumber == null || senderDeviceId == null) {
      return base.copyWith(
        encryptionState: ChatMessageEncryptionState.invalid,
        encryptionError: 'Encrypted message metadata is invalid.',
      );
    }
    try {
      final epoch = await _epochForRecord(
        conversationId: base.threadId,
        epochId: base.encryptionEpochId,
        epochNumber: epochNumber,
      );
      if (epoch == null) {
        return base.copyWith(
          encryptionState: ChatMessageEncryptionState.locked,
          encryptionError:
              'The conversation key is unavailable on this device.',
        );
      }
      final sender = await _deviceIdentityFor(
        conversationId: base.threadId,
        deviceId: senderDeviceId,
      );
      final plaintext = await _crypto.decryptMessage(
        conversationId: base.threadId,
        messageId: base.id,
        envelope: E2eeEncryptedPayload.fromBackend(row),
        epoch: epoch,
        senderDevice: sender,
      );
      final content = _decodeMessageContent(plaintext);
      final typeValue = content['message_type']?.toString();
      if (typeValue != base.messageType.value) {
        throw const FormatException('Encrypted message type mismatch.');
      }
      final media = _decodeEncryptedMedia(
        row: row,
        content: content,
        message: base,
        senderDeviceId: senderDeviceId,
      );
      return base.copyWith(
        senderName: content['sender_name']!.toString(),
        body: content['body']?.toString() ?? '',
        media: media,
        replyTo: _replyPreviewFromEncryptedContent(
          content,
          messageType: base.messageType,
        ),
        isForwarded: content['is_forwarded'] == true,
        encryptionState: ChatMessageEncryptionState.encrypted,
        encryptionError: null,
      );
    } on E2eeCryptoException catch (error) {
      return base.copyWith(
        encryptionState: ChatMessageEncryptionState.invalid,
        encryptionError: error.message,
      );
    } catch (_) {
      return base.copyWith(
        encryptionState: ChatMessageEncryptionState.invalid,
        encryptionError: 'Encrypted message content is invalid.',
      );
    }
  }

  Map<String, dynamic> _decodeMessageContent(String plaintext) {
    final decoded = jsonDecode(plaintext);
    if (decoded is! Map) {
      throw const FormatException(
        'Encrypted message payload is not an object.',
      );
    }
    final content = Map<String, dynamic>.from(decoded);
    if (_intValue(content['version']) != E2eeCryptoService.protocolVersion ||
        _nullableText(content['message_type']) == null ||
        content['body'] is! String ||
        content['sender_name'] is! String ||
        (content['reply_to_message_id'] != null &&
            content['reply_to_message_id'] is! String) ||
        content['is_forwarded'] is! bool) {
      throw const FormatException('Encrypted message payload is invalid.');
    }
    return content;
  }

  MessageReplyPreview? _replyPreviewFromEncryptedContent(
    Map<String, dynamic> content, {
    required ChatMessageType messageType,
  }) {
    final messageId = _nullableText(content['reply_to_message_id']);
    if (messageId == null) return null;
    return MessageReplyPreview(
      messageId: messageId,
      senderName: '',
      preview: '',
      messageType: messageType,
    );
  }

  ChatMedia? _decodeEncryptedMedia({
    required Map<String, dynamic> row,
    required Map<String, dynamic> content,
    required ChatMessage message,
    required String senderDeviceId,
  }) {
    if (message.messageType == ChatMessageType.text) {
      if (content.containsKey('media') ||
          _nullableText(row['media_bucket']) != null ||
          _nullableText(row['media_path']) != null) {
        throw const FormatException('Text message media mismatch.');
      }
      return null;
    }
    final encoded = content['media'];
    if (encoded is! Map) {
      throw const FormatException('Encrypted media descriptor is missing.');
    }
    final media = Map<String, dynamic>.from(encoded);
    final encryption = media['encryption'];
    final mimeType = _nullableText(media['mime_type']);
    final originalName = _nullableText(media['original_name']);
    final authenticatedBucket = _nullableText(media['bucket']);
    final authenticatedPath = _nullableText(media['path']);
    final bucket = _nullableText(row['media_bucket']);
    final path = _nullableText(row['media_path']);
    final epochNumber = _intValue(media['epoch_number']);
    final epochId = _nullableText(media['epoch_id']);
    if (encryption is! Map ||
        mimeType == null ||
        originalName == null ||
        bucket != mediaBucket ||
        authenticatedBucket != bucket ||
        authenticatedPath != path ||
        path == null ||
        epochNumber == null ||
        epochNumber < 1 ||
        epochId == null) {
      throw const FormatException('Encrypted media descriptor is invalid.');
    }
    final normalizedMimeType = mimeType.toLowerCase();
    final validMimeType = switch (message.messageType) {
      ChatMessageType.image =>
        normalizedMimeType.startsWith('image/') &&
            normalizedMimeType != 'image/gif',
      ChatMessageType.gif => normalizedMimeType == 'image/gif',
      ChatMessageType.voice => normalizedMimeType.startsWith('audio/'),
      _ => false,
    };
    if (!validMimeType) {
      throw const FormatException('Encrypted media type is invalid.');
    }
    final encryptedMedia = E2eeEncryptedMedia.fromJson(
      Map<String, dynamic>.from(encryption),
    );
    if (encryptedMedia.mediaId.isEmpty ||
        encryptedMedia.nonce.isEmpty ||
        encryptedMedia.signature.isEmpty) {
      throw const FormatException('Encrypted media authentication is invalid.');
    }
    final size = _intValue(media['size_bytes']);
    if (size == null || size < 0 || size > maxMediaBytes) {
      throw const FormatException('Encrypted media size is invalid.');
    }
    final durationMs = _intValue(media['duration_ms']);
    if (durationMs != null && (durationMs < 0 || durationMs > 3600000)) {
      throw const FormatException('Encrypted media duration is invalid.');
    }
    return ChatMedia(
      bucket: bucket ?? mediaBucket,
      path: path,
      mimeType: mimeType,
      sizeBytes: size,
      width: _intValue(media['width']),
      height: _intValue(media['height']),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      waveform: _waveformFromPayload(media['waveform']),
      originalName: originalName,
      isEncrypted: true,
      conversationId: message.threadId,
      messageId: message.id,
      encryptionEpoch: epochNumber,
      encryptionEpochId: epochId,
      encryptionSenderDeviceId: senderDeviceId,
      encryptionMetadata: encryptedMedia.toJson(),
    );
  }

  Future<E2eeEncryptedReaction?> _existingEncryptedReaction({
    required String conversationId,
    required String messageId,
    required String userId,
    required String emoji,
  }) async {
    final supabase = client;
    if (supabase == null) return null;
    final rows = _mapRows(
      await supabase
          .from('encrypted_message_reactions')
          .select()
          .eq('message_id', messageId)
          .eq('user_id', userId),
    );
    for (final row in rows) {
      final decoded = await _decryptEncryptedReaction(
        row,
        conversationId: conversationId,
        messageId: messageId,
      );
      if (decoded == null) {
        throw const E2eeCryptoException(
          'An existing encrypted reaction is unavailable on this device.',
        );
      }
      if (decoded.emoji == emoji) return decoded.envelope;
    }
    return null;
  }

  Future<_DecryptedReaction?> _decryptEncryptedReaction(
    Map<String, dynamic> row, {
    required String conversationId,
    required String messageId,
  }) async {
    final epochId = _nullableText(row['epoch_id']);
    final senderDeviceId = _nullableText(row['sender_device_id']);
    if (epochId == null || senderDeviceId == null) return null;
    final epochRow = await _epochRowForId(epochId, conversationId);
    if (epochRow == null) return null;
    final epoch = await _epochForRecord(
      conversationId: conversationId,
      epochId: epochId,
      epochNumber: _intValue(epochRow['epoch_number']) ?? 0,
    );
    if (epoch == null) return null;
    try {
      final envelope = E2eeEncryptedReaction.fromBackend(row);
      final sender = await _deviceIdentityFor(
        conversationId: conversationId,
        deviceId: senderDeviceId,
      );
      final emoji = await _crypto.decryptReaction(
        conversationId: conversationId,
        messageId: messageId,
        encryptedReaction: envelope,
        epoch: epoch,
        senderDevice: sender,
      );
      return _DecryptedReaction(emoji: emoji, envelope: envelope);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _epochRowForId(
    String epochId,
    String conversationId,
  ) async {
    final supabase = client;
    if (supabase == null) return null;
    final row = await supabase
        .from('conversation_key_epochs')
        .select('id, conversation_id, epoch_number')
        .eq('id', epochId)
        .eq('conversation_id', conversationId)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  Future<Map<String, _ConversationSummary>> _conversationSummaries(
    SupabaseClient supabase,
  ) async {
    final result = await supabase.rpc('get_conversation_summaries');
    if (result is! List) {
      throw StateError('Conversation summaries returned an invalid response.');
    }

    final summaries = <String, _ConversationSummary>{};
    for (final row in result) {
      if (row is! Map) {
        continue;
      }
      final summary = _ConversationSummary.fromSupabase(
        Map<String, dynamic>.from(row),
      );
      if (summary.conversationId.isNotEmpty && summary.isEncrypted) {
        summaries[summary.conversationId] = await _hydrateEncryptedSummary(
          summary,
          localUserId: supabase.auth.currentUser?.id ?? '',
        );
      }
    }
    return summaries;
  }

  Future<_ConversationSummary> _hydrateEncryptedSummary(
    _ConversationSummary summary, {
    required String localUserId,
  }) async {
    if (!summary.isEncrypted || summary.latestMessageDeletedAt != null) {
      return summary;
    }
    final message = await _hydrateEncryptedMessage(
      summary.toMessageRow(),
      localUserId: localUserId,
    );
    return summary.copyWith(
      latestMessageSenderName: message.isEncrypted ? message.senderName : null,
      latestMessageBody: message.isEncrypted ? message.body : null,
      encryptedPreviewAvailable: message.isEncrypted,
    );
  }

  Future<ChatThread> _threadFromDirectConversation(
    SupabaseClient supabase,
    Map<String, dynamic> row,
    ChatUser peer,
  ) async {
    final summaries = await _conversationSummaries(supabase);
    return _threadFromConversation(
      row,
      peer,
      summary: summaries[row['id']?.toString()],
    );
  }

  Future<List<ChatThread>> _threadsFromConversationRows(
    List<Map<String, dynamic>> rows, {
    required Map<String, _ConversationSummary> summaries,
  }) async {
    rows.sort((a, b) {
      final aSummary = summaries[a['id']?.toString()];
      final bSummary = summaries[b['id']?.toString()];
      final aTime =
          aSummary?.latestMessageAt ??
          _readTimestamp(a['created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bTime =
          bSummary?.latestMessageAt ??
          _readTimestamp(b['created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });

    final peerIds = rows
        .where((row) => row['conversation_type'] != 'group')
        .map(_peerUserIdFor)
        .whereType<String>()
        .toSet();
    final profiles = await _profilesById(peerIds);
    final groupIds = rows
        .where((row) => row['conversation_type'] == 'group')
        .map((row) => row['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    final groupMemberships = groupIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await client!
                .from('conversation_members')
                .select('conversation_id, user_id, role')
                .inFilter('conversation_id', groupIds),
          );

    final membershipsByConversationId = <String, List<Map<String, dynamic>>>{};
    for (final membership in groupMemberships) {
      final conversationId = membership['conversation_id']?.toString() ?? '';
      if (conversationId.isNotEmpty) {
        membershipsByConversationId
            .putIfAbsent(conversationId, () => [])
            .add(membership);
      }
    }

    return rows.map((row) {
      final conversationId = row['id']?.toString() ?? '';
      final summary = summaries[conversationId];
      if (row['conversation_type'] == 'group') {
        final memberships =
            membershipsByConversationId[conversationId] ??
            const <Map<String, dynamic>>[];
        return _threadFromGroup(
          row: row,
          memberCount: memberships.length,
          isAdmin: memberships.any(
            (membership) =>
                membership['user_id']?.toString() == localUserId &&
                membership['role'] == 'admin',
          ),
          summary: summary,
        );
      }
      final peerId = _peerUserIdFor(row) ?? '';
      final peer =
          profiles[peerId] ?? ChatUser(id: peerId, displayName: 'Unknown user');
      return _threadFromConversation(row, peer, summary: summary);
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

  ChatThread _threadFromConversation(
    Map<String, dynamic> row,
    ChatUser peer, {
    _ConversationSummary? summary,
  }) {
    final lastMessageAt = _readTimestamp(row['last_message_at']);

    return _threadFromPeer(
      conversationId: row['id']?.toString() ?? '',
      peer: peer,
      lastMessageAt: lastMessageAt,
      summary: summary,
    );
  }

  ChatThread _threadFromGroup({
    required Map<String, dynamic> row,
    required int memberCount,
    required bool isAdmin,
    _ConversationSummary? summary,
  }) {
    final fallbackLastMessageAt = _readTimestamp(row['last_message_at']);
    final lastMessageAt = summary == null
        ? fallbackLastMessageAt
        : summary.latestMessageAt;
    final title = row['title']?.toString().trim();
    final displayTitle = title == null || title.isEmpty ? 'Group' : title;
    return ChatThread(
      id: row['id']?.toString() ?? '',
      title: displayTitle,
      subtitle:
          summary?.preview(isGroup: true, localUserId: localUserId) ??
          'No messages yet',
      avatarLabel: _avatarLabelFor(displayTitle),
      accentColor: _accentColorFor(row['id']?.toString() ?? displayTitle),
      lastActive: lastMessageAt == null
          ? 'New'
          : relativeTimeLabel(lastMessageAt),
      unreadCount: summary?.unreadCount ?? 0,
      isOnline: false,
      activityLabel: '$memberCount ${memberCount == 1 ? 'member' : 'members'}',
      conversationType: ChatConversationType.group,
      memberCount: memberCount,
      isAdmin: isAdmin,
      latestMessageAt: lastMessageAt,
      status: summary?.threadStatus ?? ChatThreadStatus.none,
    );
  }

  ChatThread _threadFromPeer({
    required String conversationId,
    required ChatUser peer,
    DateTime? lastMessageAt,
    _ConversationSummary? summary,
  }) {
    final latestMessageAt = summary == null
        ? lastMessageAt
        : summary.latestMessageAt;
    return ChatThread(
      id: conversationId,
      title: peer.displayName,
      subtitle:
          summary?.preview(isGroup: false, localUserId: localUserId) ??
          'No messages yet',
      avatarLabel: peer.avatarLabel,
      accentColor: _accentColorFor(peer.id),
      lastActive: latestMessageAt == null
          ? 'New'
          : relativeTimeLabel(latestMessageAt),
      unreadCount: summary?.unreadCount ?? 0,
      isOnline: false,
      activityLabel: activityLabelFor(
        isOnline: false,
        lastSeenAt: peer.lastSeenAt,
      ),
      peerUserId: peer.id,
      peerLastSeenAt: peer.lastSeenAt,
      latestMessageAt: latestMessageAt,
      status: summary?.threadStatus ?? ChatThreadStatus.none,
    );
  }
}

class ConversationSafetyIdentity {
  const ConversationSafetyIdentity({
    required this.userId,
    required this.signingPublicKey,
    required this.fingerprint,
    required this.isVerified,
    required this.hasChanged,
  });

  final String userId;
  final String signingPublicKey;
  final String fingerprint;
  final bool isVerified;
  final bool hasChanged;
}

class _DecryptedReaction {
  const _DecryptedReaction({required this.emoji, required this.envelope});

  final String emoji;
  final E2eeEncryptedReaction envelope;
}

class _ConversationSummary {
  const _ConversationSummary({
    required this.conversationId,
    required this.latestMessageId,
    required this.latestMessageSenderId,
    required this.latestMessageSenderName,
    required this.latestMessageBody,
    required this.latestMessageType,
    required this.latestMessageReplyToMessageId,
    required this.latestMessageCallEvent,
    required this.latestMessageDeletedAt,
    required this.latestMessageAt,
    required this.latestMessageEncryptionVersion,
    required this.latestMessageEpochId,
    required this.latestMessageEpochNumber,
    required this.latestMessageRevision,
    required this.latestMessageCiphertext,
    required this.latestMessageNonce,
    required this.latestMessageSignature,
    required this.latestMessageSenderDeviceId,
    required this.encryptedPreviewAvailable,
    required this.unreadCount,
    required this.status,
    required this.latestOutgoingStatus,
  });

  factory _ConversationSummary.fromSupabase(Map<String, dynamic> row) {
    return _ConversationSummary(
      conversationId: row['conversation_id']?.toString() ?? '',
      latestMessageId: _summaryText(row['latest_message_id']),
      latestMessageSenderId: _summaryText(row['latest_message_sender_id']),
      latestMessageSenderName: _summaryText(row['latest_message_sender_name']),
      latestMessageBody: _summaryText(row['latest_message_body']),
      latestMessageType: _summaryText(row['latest_message_type']),
      latestMessageReplyToMessageId: _summaryText(
        row['latest_message_reply_to_message_id'],
      ),
      latestMessageCallEvent: _summaryText(row['latest_message_call_event']),
      latestMessageDeletedAt: _readTimestamp(row['latest_message_deleted_at']),
      latestMessageAt: _readTimestamp(row['latest_message_at']),
      latestMessageEncryptionVersion: _summaryInt(
        row['latest_message_encryption_version'],
      ),
      latestMessageEpochId: _summaryText(row['latest_message_epoch_id']),
      latestMessageEpochNumber: _intValue(row['latest_message_epoch_number']),
      latestMessageRevision: _intValue(row['latest_message_revision']),
      latestMessageCiphertext: _summaryText(row['latest_message_ciphertext']),
      latestMessageNonce: _summaryText(row['latest_message_nonce']),
      latestMessageSignature: _summaryText(row['latest_message_signature']),
      latestMessageSenderDeviceId: _summaryText(
        row['latest_message_sender_device_id'],
      ),
      encryptedPreviewAvailable:
          _summaryInt(row['latest_message_encryption_version']) == 0,
      unreadCount: _summaryInt(row['unread_count']),
      status: _threadStatusFromValue(row['status']),
      latestOutgoingStatus: _threadStatusFromValue(
        row['latest_outgoing_status'],
      ),
    );
  }

  final String conversationId;
  final String? latestMessageId;
  final String? latestMessageSenderId;
  final String? latestMessageSenderName;
  final String? latestMessageBody;
  final String? latestMessageType;
  final String? latestMessageReplyToMessageId;
  final String? latestMessageCallEvent;
  final DateTime? latestMessageDeletedAt;
  final DateTime? latestMessageAt;
  final int latestMessageEncryptionVersion;
  final String? latestMessageEpochId;
  final int? latestMessageEpochNumber;
  final int? latestMessageRevision;
  final String? latestMessageCiphertext;
  final String? latestMessageNonce;
  final String? latestMessageSignature;
  final String? latestMessageSenderDeviceId;
  final bool encryptedPreviewAvailable;
  final int unreadCount;
  final ChatThreadStatus status;
  final ChatThreadStatus latestOutgoingStatus;

  bool get hasLatestMessage => latestMessageId != null;
  bool get isEncrypted => latestMessageEncryptionVersion > 0;

  _ConversationSummary copyWith({
    String? latestMessageSenderName,
    String? latestMessageBody,
    bool? encryptedPreviewAvailable,
  }) {
    return _ConversationSummary(
      conversationId: conversationId,
      latestMessageId: latestMessageId,
      latestMessageSenderId: latestMessageSenderId,
      latestMessageSenderName:
          latestMessageSenderName ?? this.latestMessageSenderName,
      latestMessageBody: latestMessageBody ?? this.latestMessageBody,
      latestMessageType: latestMessageType,
      latestMessageReplyToMessageId: latestMessageReplyToMessageId,
      latestMessageCallEvent: latestMessageCallEvent,
      latestMessageDeletedAt: latestMessageDeletedAt,
      latestMessageAt: latestMessageAt,
      latestMessageEncryptionVersion: latestMessageEncryptionVersion,
      latestMessageEpochId: latestMessageEpochId,
      latestMessageEpochNumber: latestMessageEpochNumber,
      latestMessageRevision: latestMessageRevision,
      latestMessageCiphertext: latestMessageCiphertext,
      latestMessageNonce: latestMessageNonce,
      latestMessageSignature: latestMessageSignature,
      latestMessageSenderDeviceId: latestMessageSenderDeviceId,
      encryptedPreviewAvailable:
          encryptedPreviewAvailable ?? this.encryptedPreviewAvailable,
      unreadCount: unreadCount,
      status: status,
      latestOutgoingStatus: latestOutgoingStatus,
    );
  }

  Map<String, dynamic> toMessageRow() {
    return <String, dynamic>{
      'id': latestMessageId,
      'conversation_id': conversationId,
      'sender_id': latestMessageSenderId,
      'sender_name': latestMessageSenderName,
      'body': latestMessageBody ?? '',
      'message_type': latestMessageType,
      'reply_to_message_id': latestMessageReplyToMessageId,
      'call_event': latestMessageCallEvent,
      'deleted_at': latestMessageDeletedAt?.toUtc().toIso8601String(),
      'created_at': latestMessageAt?.toUtc().toIso8601String(),
      'encryption_version': latestMessageEncryptionVersion,
      'e2ee_epoch_id': latestMessageEpochId,
      'e2ee_epoch_number': latestMessageEpochNumber,
      'e2ee_revision': latestMessageRevision,
      'e2ee_ciphertext': latestMessageCiphertext,
      'e2ee_nonce': latestMessageNonce,
      'e2ee_signature': latestMessageSignature,
      'e2ee_sender_device_id': latestMessageSenderDeviceId,
    };
  }

  ChatThreadStatus get threadStatus {
    if (unreadCount > 0) {
      return ChatThreadStatus.unread;
    }
    return status == ChatThreadStatus.none ? latestOutgoingStatus : status;
  }

  String? preview({required bool isGroup, required String localUserId}) {
    if (!hasLatestMessage) {
      return null;
    }

    final messagePreview = latestMessageDeletedAt != null
        ? 'Message deleted'
        : isEncrypted && !encryptedPreviewAvailable
        ? 'Encrypted message'
        : _previewForMessage(
            latestMessageBody,
            latestMessageType,
            callEvent: latestMessageCallEvent,
          );
    if (latestMessageSenderId == localUserId) {
      return 'You: $messagePreview';
    }
    if (isGroup) {
      return '${latestMessageSenderName ?? 'Someone'}: $messagePreview';
    }
    return messagePreview;
  }
}

bool _matchesUser(ChatUser user, String query) {
  return user.id.toLowerCase().contains(query) ||
      user.displayName.toLowerCase().contains(query) ||
      (user.email?.toLowerCase().contains(query) ?? false);
}

String _previewForMessage(
  String? body,
  String? messageType, {
  String? callEvent,
}) {
  final text = body?.trim();
  if (text != null && text.isNotEmpty) {
    return text;
  }

  return switch (ChatMessageType.fromValue(messageType)) {
    ChatMessageType.image => 'Photo',
    ChatMessageType.gif => 'GIF',
    ChatMessageType.voice => 'Voice message',
    ChatMessageType.call => switch (callEvent) {
      'started' => 'Call started',
      'ended' => 'Call ended',
      'failed' || 'rejected' => 'Call failed',
      _ => 'Call event',
    },
    ChatMessageType.text => 'Message',
  };
}

ChatThreadStatus _threadStatusFromValue(Object? value) {
  return switch (value?.toString().trim().toLowerCase()) {
    'unread' => ChatThreadStatus.unread,
    'sent' => ChatThreadStatus.sent,
    'delivered' => ChatThreadStatus.delivered,
    'read' => ChatThreadStatus.read,
    _ => ChatThreadStatus.none,
  };
}

int _summaryInt(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String? _summaryText(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

MessageReceipt? _aggregateReceipts(List<MessageReceipt>? receipts) {
  if (receipts == null || receipts.isEmpty) return null;
  final allDelivered = receipts.every((receipt) => receipt.isDelivered);
  final allRead = receipts.every((receipt) => receipt.isRead);
  return MessageReceipt(
    messageId: receipts.first.messageId,
    userId: 'all-recipients',
    deliveredAt: allDelivered ? DateTime.now() : null,
    readAt: allRead ? DateTime.now() : null,
  );
}

String _avatarLabelFor(String name) {
  final parts = name
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
  return 'G';
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

String? _nullableText(Object? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.toString().trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

int? _intValue(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

List<Map<String, dynamic>> _mapRows(Object? value) {
  if (value is! Iterable) return const <Map<String, dynamic>>[];
  return value
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList(growable: false);
}

List<double> _waveformFromPayload(Object? value) {
  if (value is! Iterable) return const <double>[];
  final waveform = <double>[];
  for (final level in value) {
    final parsed = level is num
        ? level.toDouble()
        : double.tryParse(level?.toString() ?? '');
    if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 1) {
      throw const FormatException('Encrypted media waveform is invalid.');
    }
    waveform.add(parsed);
  }
  return List<double>.unmodifiable(waveform);
}

bool get _isDesktopPlatform {
  if (kIsWeb) {
    return false;
  }

  return switch (defaultTargetPlatform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };
}

bool get _isLinuxPlatform {
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
}

class MediaAttachmentException implements Exception {
  const MediaAttachmentException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => details == null ? message : '$message\n$details';
}

class ChatMediaUploadException implements Exception {
  const ChatMediaUploadException({
    required this.statusCode,
    required this.requestUri,
    required this.responseBody,
    this.reasonPhrase,
  });

  final int statusCode;
  final Uri requestUri;
  final String responseBody;
  final String? reasonPhrase;

  String get message {
    final reason = reasonPhrase == null || reasonPhrase!.trim().isEmpty
        ? ''
        : ' ${reasonPhrase!.trim()}';
    return 'Media upload failed (HTTP $statusCode$reason).';
  }

  String get details {
    final buffer = StringBuffer()
      ..writeln(message)
      ..writeln('Request: ${requestUri.replace(query: '')}');
    final body = _compactLogValue(responseBody);
    if (body.isNotEmpty) {
      buffer.writeln('Response: $body');
    }
    final hint = _uploadFailureHint(statusCode, responseBody);
    if (hint != null) {
      buffer.writeln('Hint: $hint');
    }
    return buffer.toString().trimRight();
  }

  @override
  String toString() => details;
}

String _compactLogValue(String value, {int maxLength = 1200}) {
  final compact = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (compact.length <= maxLength) {
    return compact;
  }
  return '${compact.substring(0, maxLength)}...';
}

String? _uploadFailureHint(int statusCode, String body) {
  final normalizedBody = body.toLowerCase();
  if (normalizedBody.contains('authorization')) {
    return 'The upload request is missing the Supabase bearer session header. '
        'Sign in again and retry; if it persists, inspect uploadHeaders.';
  }
  if (statusCode == 401 || statusCode == 403) {
    return 'Check the signed-in session, storage.objects RLS policies, '
        'conversation participant IDs, and media path.';
  }
  if (statusCode == 404 || normalizedBody.contains('bucket')) {
    return 'Check that the private chat-media bucket exists in Supabase.';
  }
  if (statusCode == 413 || normalizedBody.contains('size')) {
    return 'The file may exceed the chat-media 15 MB limit.';
  }
  if (normalizedBody.contains('invalid_mime_type') &&
      normalizedBody.contains('audio/')) {
    return 'The remote chat-media bucket does not allow audio yet. '
        'Apply supabase/migrations/20260706130000_chat_voice_messages.sql.';
  }
  if (statusCode == 400 || statusCode == 415) {
    return 'Check MIME type, filename extension, and allowed bucket MIME types.';
  }
  return null;
}

class _MediaDimensions {
  const _MediaDimensions({required this.width, required this.height});

  final int width;
  final int height;
}

Future<_MediaDimensions?> _readImageDimensions(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return _MediaDimensions(width: descriptor.width, height: descriptor.height);
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<void> _uploadBytesWithProgress({
  required Uri uri,
  required Map<String, String> headers,
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  required void Function(double progress) onProgress,
  http.Client? httpClient,
  bool upsert = false,
}) async {
  onProgress(0);

  final request = http.MultipartRequest('POST', uri)
    ..headers.addAll(headers)
    ..headers['x-upsert'] = upsert ? 'true' : 'false'
    ..fields['cacheControl'] = ChatRepository._mediaCacheControl
    ..files.add(
      http.MultipartFile(
        '',
        _progressByteStream(bytes, onProgress),
        bytes.length,
        filename: fileName,
        contentType: MediaType.parse(mimeType),
      ),
    );

  final client = httpClient ?? http.Client();
  try {
    final response = await client.send(request);
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw ChatMediaUploadException(
        statusCode: response.statusCode,
        reasonPhrase: response.reasonPhrase,
        requestUri: uri,
        responseBody: body,
      );
    }
    if (body.isNotEmpty) {
      json.decode(body);
    }
    onProgress(1);
  } finally {
    if (httpClient == null) {
      client.close();
    }
  }
}

Uri _chatMediaUploadUri({
  required String storageUrl,
  required String objectPath,
}) {
  final encodedPath = Uri(
    pathSegments: [ChatRepository.mediaBucket, ...objectPath.split('/')],
  ).path.replaceFirst(RegExp(r'^/'), '');
  return Uri.parse('$storageUrl/object/$encodedPath');
}

Stream<List<int>> _progressByteStream(
  Uint8List bytes,
  void Function(double progress) onProgress,
) async* {
  const chunkSize = 64 * 1024;
  if (bytes.isEmpty) {
    onProgress(0);
    return;
  }

  for (var offset = 0; offset < bytes.length; offset += chunkSize) {
    final end = offset + chunkSize > bytes.length
        ? bytes.length
        : offset + chunkSize;
    yield Uint8List.sublistView(bytes, offset, end);

    final fileProgress = end / bytes.length;
    final cappedProgress = fileProgress * 0.97;
    onProgress(cappedProgress > 0.97 ? 0.97 : cappedProgress);
    await Future<void>.delayed(Duration.zero);
  }
}

String _normalizedMimeType(String? mimeType) {
  final normalized = mimeType?.split(';').first.trim().toLowerCase();
  if (normalized == 'image/jpg') {
    return 'image/jpeg';
  }
  if (normalized == null || normalized.isEmpty) {
    return 'application/octet-stream';
  }
  return normalized;
}

String _safeOriginalName(String name, String mimeType) {
  final trimmed = name.trim();
  final fallback = 'attachment${_extensionForMime(mimeType)}';
  if (trimmed.isEmpty || trimmed.toLowerCase() == 'image_picker') {
    return fallback;
  }
  return trimmed.replaceAll(RegExp(r'[/\\]'), '_');
}

String _safeDownloadName(ChatMedia media) {
  final name = _safeOriginalName(media.originalName ?? '', media.mimeType);
  if (RegExp(r'\.[a-z0-9]{1,8}$', caseSensitive: false).hasMatch(name)) {
    return name;
  }
  return '$name${_extensionForMime(media.mimeType)}';
}

String _downloadBaseName(String fileName) {
  final extension = _downloadExtensionFor(fileName);
  if (extension.isEmpty) {
    return fileName;
  }
  return fileName.substring(0, fileName.length - extension.length - 1);
}

String _downloadExtensionFor(String fileName) {
  final dotIndex = fileName.lastIndexOf('.');
  if (dotIndex < 0 || dotIndex == fileName.length - 1) {
    return '';
  }
  return fileName.substring(dotIndex + 1).toLowerCase();
}

List<file_selector.XTypeGroup> _downloadTypeGroupsFor(
  ChatMedia media,
  String fileName,
) {
  final extension = _downloadExtensionFor(fileName);
  if (extension.isEmpty) {
    return const [];
  }

  final mimeType = media.mimeType.trim();
  return [
    file_selector.XTypeGroup(
      label: _downloadTypeLabel(media),
      extensions: [extension],
      mimeTypes: mimeType.isEmpty ? const [] : [mimeType],
    ),
  ];
}

String _downloadTypeLabel(ChatMedia media) {
  final mimeType = media.mimeType.toLowerCase();
  if (mimeType == 'image/gif') {
    return 'GIF';
  }
  if (mimeType.startsWith('image/')) {
    return 'Images';
  }
  if (mimeType.startsWith('audio/')) {
    return 'Audio';
  }
  return 'Media';
}

MimeType _fileSaverMimeType(String mimeType) {
  return switch (_normalizedMimeType(mimeType)) {
    'image/jpeg' => MimeType.jpeg,
    'image/png' => MimeType.png,
    'image/webp' => MimeType.webp,
    'image/gif' => MimeType.gif,
    'image/heic' => MimeType.heic,
    'image/heif' => MimeType.heif,
    'audio/aac' => MimeType.aac,
    'audio/mpeg' || 'audio/mp3' => MimeType.mp3,
    'audio/mp4' => MimeType.mp4Audio,
    'application/octet-stream' => MimeType.other,
    _ => MimeType.custom,
  };
}

String _extensionFor(PickedChatMedia media) {
  final name = media.originalName.toLowerCase();
  final lastDot = name.lastIndexOf('.');
  if (lastDot >= 0 && lastDot < name.length - 1) {
    final extension = name.substring(lastDot);
    if (extension.length <= 6) {
      return extension;
    }
  }
  return _extensionForMime(media.mimeType);
}

String _extensionForMime(String mimeType) {
  return switch (mimeType.toLowerCase()) {
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    'image/webp' => '.webp',
    'image/gif' => '.gif',
    'image/heic' => '.heic',
    'image/heif' => '.heif',
    'audio/wav' || 'audio/x-wav' => '.wav',
    'audio/aac' => '.aac',
    'audio/mpeg' || 'audio/mp3' => '.mp3',
    'audio/mp4' => '.m4a',
    'audio/webm' => '.webm',
    'audio/ogg' => '.ogg',
    _ => '.img',
  };
}

GiphyGif? _giphyGifFromJson(Map<String, dynamic> row) {
  final id = row['id']?.toString();
  final images = row['images'];
  if (id == null || images is! Map<String, dynamic>) {
    return null;
  }

  final original = images['original'];
  if (original is! Map<String, dynamic>) {
    return null;
  }

  final preview =
      images['fixed_width'] ??
      images['downsized_medium'] ??
      images['downsized'] ??
      original;
  if (preview is! Map<String, dynamic>) {
    return null;
  }

  final originalUrl = original['url']?.toString();
  final previewUrl = preview['url']?.toString();
  if (originalUrl == null ||
      originalUrl.isEmpty ||
      previewUrl == null ||
      previewUrl.isEmpty) {
    return null;
  }

  return GiphyGif(
    id: id,
    title: row['title']?.toString() ?? 'GIF',
    previewUrl: previewUrl,
    originalUrl: originalUrl,
    width: _readGiphyInt(original['width']),
    height: _readGiphyInt(original['height']),
    sizeBytes: _readGiphyInt(original['size']),
  );
}

int? _readGiphyInt(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '');
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
