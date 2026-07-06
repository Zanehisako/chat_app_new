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

class ChatRepository {
  ChatRepository({this.client});

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

  final SupabaseClient? client;
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

  Future<List<ChatThread>> fetchThreads() async {
    final supabase = client;
    if (supabase == null) {
      return ChatSeed.threads;
    }
    final user = supabase.auth.currentUser;
    if (user == null) {
      return const [];
    }

    final rows = await supabase.from('conversations').select();
    return _threadsFromConversationRows(
      List<Map<String, dynamic>>.from(
        rows,
      ).where((row) => _belongsToUser(row, user.id)).toList(),
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
        originalName: pickedMedia.originalName,
        localBytes: pickedMedia.bytes,
      ),
    );
  }

  Future<UploadedChatMedia> uploadMediaAttachment({
    required String conversationId,
    required PickedChatMedia pickedMedia,
    required void Function(double progress) onProgress,
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

    final messageId = _uuid.v4();
    final objectPath =
        '$conversationId/${user.id}/$messageId${_extensionFor(pickedMedia)}';
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
      bytes: pickedMedia.bytes,
      fileName: pickedMedia.originalName,
      mimeType: pickedMedia.mimeType,
      onProgress: onProgress,
    );

    onProgress(1);

    return UploadedChatMedia(
      messageId: messageId,
      media: ChatMedia(
        bucket: mediaBucket,
        path: objectPath,
        mimeType: pickedMedia.mimeType,
        sizeBytes: pickedMedia.sizeBytes,
        width: pickedMedia.width,
        height: pickedMedia.height,
        originalName: pickedMedia.originalName,
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
  }) {
    return _uploadBytesWithProgress(
      uri: uri,
      headers: headers,
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
      onProgress: onProgress,
      httpClient: httpClient,
    );
  }

  Future<String> signedMediaUrl(ChatMedia media) async {
    final supabase = client;
    if (supabase == null) {
      throw StateError('Local media does not need a signed URL.');
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

    final signedUrl = await signedMediaUrl(media);
    final response = await http.get(Uri.parse(signedUrl));
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw MediaAttachmentException(
        'Could not download that media.',
        details:
            'Media download failed with HTTP ${response.statusCode}: '
            '${_compactLogValue(response.body)}',
      );
    }
    return response.bodyBytes;
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

  Future<void> sendMediaMessage({
    required String conversationId,
    required String messageId,
    required String body,
    required ChatMedia media,
  }) async {
    final supabase = client;
    if (supabase == null) {
      return;
    }

    final user = supabase.auth.currentUser;
    if (user == null) {
      throw const AuthException('Sign in before sending media.');
    }

    await supabase.from('messages').insert({
      'id': messageId,
      'conversation_id': conversationId,
      'sender_id': user.id,
      'sender_name': localSenderName,
      'body': body.trim(),
      'message_type': media.isGif
          ? ChatMessageType.gif.value
          : ChatMessageType.image.value,
      'media_bucket': media.bucket,
      'media_path': media.path,
      'media_mime_type': media.mimeType,
      'media_size_bytes': media.sizeBytes,
      'media_width': media.width,
      'media_height': media.height,
      'media_original_name': media.originalName,
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

String? _nullableText(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
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
}) async {
  onProgress(0);

  final request = http.MultipartRequest('POST', uri)
    ..headers.addAll(headers)
    ..headers['x-upsert'] = 'false'
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
