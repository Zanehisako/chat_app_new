import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:camera/camera.dart' as camera;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:realtime_calls/realtime_calls.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_signaling.dart';
import 'chat_models.dart';
import 'connectivity_service.dart';
import 'chat_repository.dart';
import 'notification_service.dart';
import 'offline_outbox_service.dart';
import 'outbox_database.dart';
import 'profile_page.dart';
import 'voice_recording_file.dart';

class ChatHomePage extends StatefulWidget {
  const ChatHomePage({
    super.key,
    required this.repository,
    this.onSignOut,
    @visibleForTesting this.outboxDatabase,
  });

  final ChatRepository repository;
  final Future<void> Function()? onSignOut;
  final OutboxDatabase? outboxDatabase;

  @override
  State<ChatHomePage> createState() => _ChatHomePageState();
}

enum _AttachmentUploadState { uploading, uploaded, failed }

const _voiceSampleRate = 16000;
const _voiceChannelCount = 1;

class _StagedMediaAttachment {
  const _StagedMediaAttachment({
    required this.conversationId,
    required this.pickedMedia,
    required this.status,
    required this.progress,
    this.uploadedMedia,
    this.errorMessage,
    this.errorDetails,
  });

  final String conversationId;
  final PickedChatMedia pickedMedia;
  final _AttachmentUploadState status;
  final double progress;
  final UploadedChatMedia? uploadedMedia;
  final String? errorMessage;
  final String? errorDetails;

  bool get isUploading => status == _AttachmentUploadState.uploading;
  bool get canSend => uploadedMedia != null && !isUploading;

  _StagedMediaAttachment copyWith({
    _AttachmentUploadState? status,
    double? progress,
    UploadedChatMedia? uploadedMedia,
    String? errorMessage,
    String? errorDetails,
  }) {
    return _StagedMediaAttachment(
      conversationId: conversationId,
      pickedMedia: pickedMedia,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      uploadedMedia: uploadedMedia ?? this.uploadedMedia,
      errorMessage: errorMessage,
      errorDetails: errorDetails,
    );
  }
}

class _ChatHomePageState extends State<ChatHomePage>
    with WidgetsBindingObserver {
  late Stream<List<ChatThread>> _threadsStream;
  ChatThread? _selectedThread;
  final _messageController = TextEditingController();
  final _searchController = TextEditingController();
  final AudioRecorder _voiceRecorder = AudioRecorder();
  final List<ChatThread> _startedThreads = [];
  final List<ChatThread> _refreshedThreads = [];
  final List<ChatMessage> _localMessages = [];
  List<ChatThread> _availableThreads = const [];
  final List<int> _voiceBytes = [];
  final List<double> _voiceLevels = [];
  final Map<String, ChatUser> _profileOverridesByUser = {};
  final Map<String, UserPresence> _presenceByUser = {};
  final Map<String, TypingState> _typingByConversation = {};
  final Map<String, StreamSubscription<TypingState>> _typingSubscriptions = {};
  final Set<String> _profileRefreshesInFlight = {};
  final Set<String> _knownIncomingMessageIds = {};
  final Queue<String> _knownIncomingMessageOrder = Queue<String>();
  OfflineOutboxService? _outboxService;
  ConnectivityService? _connectivityService;
  OutboxDatabase? _outboxDatabase;
  late final bool _ownsOutboxDatabase;
  Future<OfflineOutboxService?>? _outboxSetup;
  Future<void>? _outboxTransition;
  int _outboxGeneration = 0;
  StreamSubscription<List<OutboxMessage>>? _outboxSubscription;
  StreamSubscription<ChatMessage>? _incomingMessageSubscription;
  StreamSubscription<NotificationRoute>? _notificationRouteSubscription;
  StreamSubscription<Map<String, UserPresence>>? _presenceSubscription;
  StreamSubscription<CallInvite>? _incomingCallSubscription;
  StreamSubscription<CallSnapshot?>? _callSnapshotSubscription;
  StreamSubscription<Uint8List>? _voiceDataSubscription;
  StreamSubscription<Amplitude>? _voiceAmplitudeSubscription;
  Completer<void>? _voiceStreamDone;
  CallClient? _callClient;
  CallInvite? _incomingCallInvite;
  CallSnapshot? _callSnapshot;
  Timer? _typingStopTimer;
  Timer? _voiceRecordingTimer;
  Timer? _clearEndedCallTimer;
  Object? _activeUploadToken;
  _StagedMediaAttachment? _stagedAttachment;
  List<ChatMessage> _outboxMessages = [];
  DateTime? _voiceRecordingStartedAt;
  String? _voiceRecordingFilePath;
  String? _activeTypingConversationId;
  String? _activeConversationId;
  ChatMessage? _replyingTo;
  ChatMessage? _editingMessage;
  String? _pendingNotificationConversationId;
  String _query = '';
  bool _isSending = false;
  bool _isRecordingVoice = false;
  bool _isVoiceRecordingFileBacked = false;
  bool _isCompactConversationOpen = false;
  bool _isTearingDown = false;
  static const _maxKnownIncomingMessageIds = 256;
  Duration _voiceRecordingElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _outboxDatabase = widget.outboxDatabase;
    _ownsOutboxDatabase = widget.outboxDatabase == null;
    WidgetsBinding.instance.addObserver(this);
    _threadsStream = widget.repository.watchThreads();
    _subscribePresence();
    _configureCalls();
    unawaited(_ensureOfflineOutbox());
    _configureNotifications();
  }

  @override
  void didUpdateWidget(covariant ChatHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      unawaited(_cancelVoiceRecording());
      unawaited(_removeStagedAttachment());
      unawaited(oldWidget.repository.disposeRealtime());
      _presenceSubscription?.cancel();
      unawaited(_disposeCallClient());
      _cancelTypingSubscriptions();
      _presenceByUser.clear();
      _typingByConversation.clear();
      _threadsStream = widget.repository.watchThreads();
      _outboxMessages = [];
      _selectedThread = null;
      _startedThreads.clear();
      _refreshedThreads.clear();
      _profileOverridesByUser.clear();
      _profileRefreshesInFlight.clear();
      _knownIncomingMessageIds.clear();
      _knownIncomingMessageOrder.clear();
      _activeConversationId = null;
      _subscribePresence();
      _configureCalls();
      _scheduleOutboxReconfiguration();
      _disposeNotifications();
      _configureNotifications();
    }
  }

  @override
  void dispose() {
    _isTearingDown = true;
    WidgetsBinding.instance.removeObserver(this);
    _activeUploadToken = null;
    final stagedMedia = _stagedAttachment?.uploadedMedia?.media;
    if (stagedMedia != null) {
      unawaited(widget.repository.deleteStagedMedia(stagedMedia));
    }
    unawaited(_disposeVoiceRecorder());
    _typingStopTimer?.cancel();
    _voiceRecordingTimer?.cancel();
    _clearEndedCallTimer?.cancel();
    _presenceSubscription?.cancel();
    _outboxGeneration += 1;
    final outboxDatabase = _outboxDatabase;
    _outboxDatabase = null;
    final outboxShutdown = _disposeOfflineOutbox();
    if (outboxDatabase != null && _ownsOutboxDatabase) {
      unawaited(outboxShutdown.whenComplete(outboxDatabase.close));
    }
    _disposeNotifications();
    unawaited(_disposeCallClient());
    _cancelTypingSubscriptions();
    unawaited(widget.repository.disposeRealtime());
    _messageController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_flushOutbox(ignoreBackoff: true));
      unawaited(
        NotificationService.instance.refreshRegistration(
          client: widget.repository.client,
        ),
      );
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(widget.repository.updateLastSeen());
    }
  }

  void _subscribePresence() {
    _presenceSubscription = widget.repository.watchPresenceForThreads().listen((
      presence,
    ) {
      if (!mounted) {
        return;
      }

      setState(() {
        _presenceByUser
          ..clear()
          ..addAll(presence);
      });
    });
  }

  void _configureCalls() {
    final client = widget.repository.client;
    if (client == null || client.auth.currentUser == null) {
      return;
    }

    final callClient = CallClient(
      signaling: SupabaseCallSignaling(client: client),
    );
    _callClient = callClient;
    _incomingCallSubscription = callClient.watchIncomingInvites().listen(
      (invite) {
        if (!mounted || _callSnapshot != null) {
          return;
        }
        debugPrint(
          '[Incoming call invite] call=${invite.id} from=${invite.callerName}',
        );
        setState(() {
          _incomingCallInvite = invite;
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        _logCallFailure('Incoming call watch failed', error, stackTrace);
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not watch incoming calls.')),
        );
      },
    );
    _callSnapshotSubscription = callClient.snapshots.listen((snapshot) {
      if (!mounted) {
        return;
      }
      setState(() {
        _callSnapshot = snapshot;
        if (snapshot != null) {
          _incomingCallInvite = null;
        }
      });

      if (snapshot?.isTerminal ?? false) {
        _clearEndedCallTimer?.cancel();
        _clearEndedCallTimer = Timer(const Duration(milliseconds: 1400), () {
          if (!mounted || _callSnapshot?.callId != snapshot?.callId) {
            return;
          }
          setState(() {
            _callSnapshot = null;
          });
        });
      }
    });
  }

  Future<OfflineOutboxService?> _ensureOfflineOutbox() async {
    while (_outboxTransition != null) {
      await _outboxTransition;
    }
    final ownerId = widget.repository.outboxUserId;
    final backendOrigin = widget.repository.outboxBackendOrigin;
    if (ownerId == null || backendOrigin == null) {
      return null;
    }
    final existing = _outboxService;
    if (existing != null &&
        existing.scope.userId == ownerId &&
        existing.scope.backendOrigin == backendOrigin) {
      return existing;
    }
    final activeSetup = _outboxSetup;
    if (activeSetup != null) return activeSetup;

    final setup = _createOfflineOutbox(
      ownerId: ownerId,
      backendOrigin: backendOrigin,
    );
    _outboxSetup = setup;
    try {
      return await setup;
    } finally {
      if (identical(_outboxSetup, setup)) _outboxSetup = null;
    }
  }

  Future<OfflineOutboxService?> _createOfflineOutbox({
    required String ownerId,
    required String backendOrigin,
  }) async {
    final outbox = OfflineOutboxService(
      scope: OutboxScope(backendOrigin: backendOrigin, userId: ownerId),
      database: _outboxDatabase ??= OutboxDatabase(),
    );
    final connectivity = ConnectivityService();
    _outboxService = outbox;
    _connectivityService = connectivity;
    _outboxSubscription = outbox.stream.listen((_) {
      unawaited(_refreshOutboxMessages(outbox));
    });

    await outbox.start(widget.repository);
    if (!mounted || _isTearingDown || _outboxService != outbox) {
      await connectivity.dispose();
      await outbox.dispose();
      return null;
    }
    await _refreshOutboxMessages(outbox);
    await connectivity.start(() => _flushOutbox(ignoreBackoff: true));
    return outbox;
  }

  void _scheduleOutboxReconfiguration() {
    final generation = ++_outboxGeneration;
    final transition = _reconfigureOfflineOutbox(generation);
    _outboxTransition = transition;
    unawaited(
      transition.whenComplete(() {
        if (identical(_outboxTransition, transition)) {
          _outboxTransition = null;
        }
      }),
    );
  }

  Future<void> _reconfigureOfflineOutbox(int generation) async {
    await _disposeOfflineOutbox();
    if (!mounted || _isTearingDown || generation != _outboxGeneration) return;
    final ownerId = widget.repository.outboxUserId;
    final backendOrigin = widget.repository.outboxBackendOrigin;
    if (ownerId == null || backendOrigin == null) return;
    await _createOfflineOutbox(ownerId: ownerId, backendOrigin: backendOrigin);
  }

  Future<void> _disposeOfflineOutbox() async {
    final subscription = _outboxSubscription;
    final connectivity = _connectivityService;
    final outbox = _outboxService;
    _outboxSubscription = null;
    _connectivityService = null;
    _outboxService = null;
    await subscription?.cancel();
    await connectivity?.dispose();
    await outbox?.dispose();
  }

  Future<void> _refreshOutboxMessages(OfflineOutboxService outbox) async {
    final messages = await outbox.localMessages();
    if (!mounted || _outboxService != outbox) {
      return;
    }
    setState(() {
      _outboxMessages = messages;
    });
  }

  Future<void> _flushOutbox({bool ignoreBackoff = false}) async {
    final outbox = _outboxService;
    if (outbox == null) {
      return;
    }
    await outbox.flushNow(ignoreBackoff: ignoreBackoff);
    await _refreshOutboxMessages(outbox);
  }

  Future<void> _retryOutboxMessage(String messageId) async {
    final outbox = _outboxService;
    if (outbox == null) {
      return;
    }
    await outbox.retryNow(messageId);
    await _refreshOutboxMessages(outbox);
  }

  void _configureNotifications() {
    final notifications = NotificationService.instance;
    _notificationRouteSubscription = notifications.routes.listen(
      _handleNotificationRoute,
    );
    final pendingRoute = notifications.takePendingRoute();
    if (pendingRoute != null) {
      scheduleMicrotask(() => _handleNotificationRoute(pendingRoute));
    }

    if (widget.repository.client == null ||
        !notifications.showsAppRunningNotificationsOnly) {
      return;
    }
    _incomingMessageSubscription = widget.repository
        .watchIncomingMessages()
        .listen(
          _handleIncomingMessage,
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('[Notifications] Incoming message watch failed: $error');
          },
        );
  }

  void _disposeNotifications() {
    final incomingMessages = _incomingMessageSubscription;
    final notificationRoutes = _notificationRouteSubscription;
    _incomingMessageSubscription = null;
    _notificationRouteSubscription = null;
    unawaited(incomingMessages?.cancel());
    unawaited(notificationRoutes?.cancel());
  }

  void _handleIncomingMessage(ChatMessage message) {
    if (!_knownIncomingMessageIds.add(message.id)) {
      return;
    }
    _knownIncomingMessageOrder.addLast(message.id);
    if (_knownIncomingMessageOrder.length > _maxKnownIncomingMessageIds) {
      _knownIncomingMessageIds.remove(_knownIncomingMessageOrder.removeFirst());
    }
    unawaited(
      NotificationService.instance.showAppRunningMessage(
        title: message.senderName,
        body: _notificationPreview(message),
        conversationId: message.threadId,
        messageId: message.id,
      ),
    );
  }

  String _notificationPreview(ChatMessage message) {
    final body = message.body.trim();
    if (body.isNotEmpty) {
      return body.length <= 180 ? body : '${body.substring(0, 180)}...';
    }
    return switch (message.messageType) {
      ChatMessageType.image => 'Sent a photo',
      ChatMessageType.gif => 'Sent a GIF',
      ChatMessageType.voice => 'Sent a voice message',
      ChatMessageType.call => 'Call updated',
      ChatMessageType.text => 'Sent a message',
    };
  }

  void _handleNotificationRoute(NotificationRoute route) {
    if (!mounted) {
      return;
    }
    setState(() {
      _pendingNotificationConversationId = route.conversationId;
      _isCompactConversationOpen = true;
    });
  }

  void _scheduleNotificationRouteResolution(List<ChatThread> threads) {
    final conversationId = _pendingNotificationConversationId;
    if (conversationId == null) {
      return;
    }
    ChatThread? thread;
    for (final candidate in threads) {
      if (candidate.id == conversationId) {
        thread = candidate;
        break;
      }
    }
    if (thread == null) {
      return;
    }
    _pendingNotificationConversationId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedThread = thread;
        _isCompactConversationOpen = true;
      });
    });
  }

  Future<void> _disposeCallClient() async {
    _clearEndedCallTimer?.cancel();
    final incomingSubscription = _incomingCallSubscription;
    final snapshotSubscription = _callSnapshotSubscription;
    final callClient = _callClient;
    _incomingCallSubscription = null;
    _callSnapshotSubscription = null;
    _callClient = null;
    _incomingCallInvite = null;
    _callSnapshot = null;
    await incomingSubscription?.cancel();
    await snapshotSubscription?.cancel();
    await callClient?.dispose();
  }

  void _syncTypingSubscriptions(List<ChatThread> threads) {
    final activeConversationIds = threads.map((thread) => thread.id).toSet();

    for (final entry in _typingSubscriptions.entries.toList()) {
      if (!activeConversationIds.contains(entry.key)) {
        unawaited(entry.value.cancel());
        _typingSubscriptions.remove(entry.key);
        _typingByConversation.remove(entry.key);
      }
    }

    for (final thread in threads) {
      if (_typingSubscriptions.containsKey(thread.id)) {
        continue;
      }

      _typingSubscriptions[thread.id] = widget.repository
          .watchConversationTyping(thread.id)
          .listen((typing) {
            if (!mounted) {
              return;
            }

            setState(() {
              _typingByConversation[thread.id] = typing;
            });
          });
    }
  }

  void _cancelTypingSubscriptions() {
    for (final subscription in _typingSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _typingSubscriptions.clear();
  }

  List<ChatThread> _threadsWithActivity(List<ChatThread> threads) {
    return threads.map((thread) {
      final profiledThread = _threadWithProfileOverride(thread);
      final presence = profiledThread.peerUserId == null
          ? null
          : _presenceByUser[profiledThread.peerUserId];
      final typing = _typingByConversation[profiledThread.id];
      final isTyping = typing?.isTyping ?? profiledThread.isTyping;
      final isOnline = presence?.isOnline ?? profiledThread.isOnline;
      final lastSeenAt = presence?.lastSeenAt ?? profiledThread.peerLastSeenAt;
      final activityLabel = isTyping
          ? 'Typing...'
          : isOnline
          ? 'Online'
          : activityLabelFor(isOnline: false, lastSeenAt: lastSeenAt);

      return profiledThread.copyWith(
        isOnline: isOnline,
        peerLastSeenAt: lastSeenAt,
        activityLabel: activityLabel == 'Offline'
            ? profiledThread.activityLabel
            : activityLabel,
        isTyping: isTyping,
        typingUserName: typing?.displayName,
      );
    }).toList();
  }

  ChatThread _threadWithProfileOverride(ChatThread thread) {
    final peerUserId = thread.peerUserId;
    final profile = peerUserId == null
        ? null
        : _profileOverridesByUser[peerUserId];
    if (profile == null) {
      return thread;
    }

    return thread.copyWith(
      title: profile.displayName,
      avatarLabel: profile.avatarLabel,
      peerLastSeenAt: profile.lastSeenAt,
      activityLabel: activityLabelFor(
        isOnline: false,
        lastSeenAt: profile.lastSeenAt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ChatThread>>(
      stream: _threadsStream,
      initialData: widget.repository.isConnected
          ? const []
          : widget.repository.threads,
      builder: (context, snapshot) {
        final threads = _threadsWithActivity(
          _mergeThreads(snapshot.data ?? const []),
        );
        _availableThreads = threads;
        _scheduleNotificationRouteResolution(threads);
        _syncTypingSubscriptions(threads);
        final selectedThread = _selectedThreadFor(threads);

        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 840;
            if (isWide || _isCompactConversationOpen) {
              _scheduleConversationEntryRefresh(selectedThread);
            }

            return Stack(
              children: [
                Scaffold(
                  body: SafeArea(
                    child: isWide
                        ? _buildWideLayout(threads, selectedThread)
                        : _buildCompactLayout(threads, selectedThread),
                  ),
                ),
                if (_incomingCallInvite case final invite?)
                  _IncomingCallOverlay(
                    invite: invite,
                    onAccept: _acceptIncomingCall,
                    onReject: _rejectIncomingCall,
                  ),
                if (_callSnapshot case final snapshot?)
                  _ActiveCallOverlay(
                    snapshot: snapshot,
                    onToggleMute: () => _toggleCallMute(snapshot),
                    onToggleCamera: () => _toggleCallCamera(snapshot),
                    onSwitchCamera: _switchCallCamera,
                    onHangUp: _hangUpCall,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildWideLayout(
    List<ChatThread> threads,
    ChatThread? selectedThread,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: _ThreadList(
            threads: _filteredThreads(threads),
            selectedThread: selectedThread,
            isConnected: widget.repository.isConnected,
            searchController: _searchController,
            onSearchChanged: _setQuery,
            onThreadSelected: _selectThread,
            onNewChat: _openNewChat,
            onOpenProfile: _openProfile,
            onRefresh: _refreshConversations,
            onSignOut: _requestSignOut,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: selectedThread == null
              ? const _EmptyConversationPane()
              : _buildConversation(
                  thread: selectedThread,
                  showBackButton: false,
                ),
        ),
      ],
    );
  }

  Widget _buildCompactLayout(
    List<ChatThread> threads,
    ChatThread? selectedThread,
  ) {
    if (!_isCompactConversationOpen) {
      return _ThreadList(
        threads: _filteredThreads(threads),
        selectedThread: selectedThread,
        isConnected: widget.repository.isConnected,
        searchController: _searchController,
        onSearchChanged: _setQuery,
        onThreadSelected: _selectCompactThread,
        onNewChat: _openNewChat,
        onOpenProfile: _openProfile,
        onRefresh: _refreshConversations,
        onSignOut: _requestSignOut,
      );
    }

    return selectedThread == null
        ? const _EmptyConversationPane()
        : _buildConversation(thread: selectedThread, showBackButton: true);
  }

  Widget _buildConversation({
    required ChatThread thread,
    required bool showBackButton,
  }) {
    return _ConversationPane(
      key: ValueKey(thread.id),
      thread: thread,
      repository: widget.repository,
      localMessages: [
        ..._localMessages,
        ..._outboxMessages,
      ].where((message) => message.threadId == thread.id).toList(),
      stagedAttachment: _stagedAttachment?.conversationId == thread.id
          ? _stagedAttachment
          : null,
      messageController: _messageController,
      isSending: _isSending,
      isRecordingVoice: _isRecordingVoice,
      voiceRecordingElapsed: _voiceRecordingElapsed,
      voiceRecordingLevels: List<double>.unmodifiable(_voiceLevels),
      showBackButton: showBackButton,
      onBackToInbox: _showCompactInbox,
      onSend: () => _sendMessage(thread),
      replyingTo: _replyingTo?.threadId == thread.id ? _replyingTo : null,
      editingMessage: _editingMessage?.threadId == thread.id
          ? _editingMessage
          : null,
      onCancelComposerAction: _cancelComposerAction,
      onReply: _startReply,
      onEdit: _startEdit,
      onDelete: _deleteMessage,
      onReact: _showReactionPicker,
      onToggleReaction: (message, emoji) =>
          _toggleMessageReaction(message, emoji),
      onForward: _forwardMessage,
      onCopy: _copyMessage,
      onAttachMedia: (source) => _stageMediaAttachment(thread, source),
      onToggleVoiceRecording: () => _toggleVoiceRecording(thread),
      onRemoveAttachment: _removeStagedAttachment,
      onRetryAttachment: () => _retryStagedAttachment(thread),
      onRetryOutboxMessage: _retryOutboxMessage,
      onComposerChanged: (value) => _handleComposerChanged(thread, value),
      onStartAudioCall: () => _startCall(thread, isVideo: false),
      onStartVideoCall: () => _startCall(thread, isVideo: true),
      onOpenProfile: _openProfile,
      onSignOut: _requestSignOut,
    );
  }

  List<ChatThread> _filteredThreads(List<ChatThread> threads) {
    final normalizedQuery = _query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return threads;
    }

    return threads.where((thread) {
      return thread.title.toLowerCase().contains(normalizedQuery) ||
          thread.displaySubtitle.toLowerCase().contains(normalizedQuery);
    }).toList();
  }

  List<ChatThread> _mergeThreads(List<ChatThread> threads) {
    final merged = {for (final thread in threads) thread.id: thread};

    for (final thread in _refreshedThreads) {
      merged[thread.id] = thread;
    }

    for (final thread in _startedThreads) {
      merged.putIfAbsent(thread.id, () => thread);
    }

    return merged.values.toList();
  }

  ChatThread? _selectedThreadFor(List<ChatThread> threads) {
    final selected = _selectedThread;
    if (selected != null) {
      for (final thread in threads) {
        if (thread.id == selected.id) {
          return thread;
        }
      }
    }

    if (threads.isEmpty) {
      return selected;
    }
    return threads.first;
  }

  void _setQuery(String value) {
    setState(() {
      _query = value;
    });
  }

  void _selectThread(ChatThread thread) {
    if (_isRecordingVoice) {
      unawaited(_cancelVoiceRecording());
    }
    if (_stagedAttachment?.conversationId != null &&
        _stagedAttachment?.conversationId != thread.id) {
      unawaited(_removeStagedAttachment());
    }
    setState(() {
      _selectedThread = thread;
      _replyingTo = null;
      _editingMessage = null;
      _messageController.clear();
    });
  }

  void _selectCompactThread(ChatThread thread) {
    if (_isRecordingVoice) {
      unawaited(_cancelVoiceRecording());
    }
    if (_stagedAttachment?.conversationId != null &&
        _stagedAttachment?.conversationId != thread.id) {
      unawaited(_removeStagedAttachment());
    }
    setState(() {
      _selectedThread = thread;
      _isCompactConversationOpen = true;
      _replyingTo = null;
      _editingMessage = null;
      _messageController.clear();
    });
  }

  Future<void> _openNewChat() async {
    final user = await showDialog<ChatUser>(
      context: context,
      builder: (context) => _NewChatDialog(repository: widget.repository),
    );

    if (user == null || !mounted) {
      return;
    }

    await _startChatWith(user);
  }

  Future<void> _startChatWith(ChatUser user) async {
    try {
      final thread = await widget.repository.startDirectConversation(user);
      if (!mounted) {
        return;
      }

      setState(() {
        _startedThreads.removeWhere((item) => item.id == thread.id);
        _startedThreads.insert(0, thread);
        _selectedThread = thread;
        _isCompactConversationOpen = true;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start that conversation.')),
      );
    }
  }

  void _showCompactInbox() {
    setState(() {
      _isCompactConversationOpen = false;
      _activeConversationId = null;
    });
  }

  void _requestSignOut() {
    _signOut();
  }

  void _scheduleConversationEntryRefresh(ChatThread? thread) {
    final peerUserId = thread?.peerUserId;
    if (thread == null || peerUserId == null || peerUserId.isEmpty) {
      return;
    }

    if (_activeConversationId == thread.id) {
      return;
    }

    _activeConversationId = thread.id;
    scheduleMicrotask(() => _refreshPeerProfile(thread));
  }

  Future<void> _refreshPeerProfile(ChatThread thread) async {
    final peerUserId = thread.peerUserId;
    if (peerUserId == null ||
        peerUserId.isEmpty ||
        _profileRefreshesInFlight.contains(peerUserId)) {
      return;
    }

    _profileRefreshesInFlight.add(peerUserId);
    try {
      final profile = await widget.repository.profileForUser(peerUserId);
      if (!mounted || profile == null) {
        return;
      }

      setState(() {
        _profileOverridesByUser[peerUserId] = profile;
      });
    } catch (_) {
      // Profile refresh is opportunistic; stale labels are better than a broken chat.
    } finally {
      _profileRefreshesInFlight.remove(peerUserId);
    }
  }

  Future<void> _refreshConversations() async {
    try {
      final threads = await widget.repository.fetchThreads();
      if (!mounted) {
        return;
      }

      setState(() {
        _refreshedThreads
          ..clear()
          ..addAll(threads);
        _threadsStream = widget.repository.watchThreads();
      });

      final selectedThread = _selectedThread;
      if (selectedThread != null) {
        await _refreshPeerProfile(selectedThread);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not refresh conversations.')),
      );
    }
  }

  Future<void> _openProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ProfilePage(repository: widget.repository),
      ),
    );
  }

  Future<void> _signOut() async {
    final signOut = widget.onSignOut;
    if (signOut == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active session to sign out.')),
      );
      return;
    }

    try {
      await widget.repository.updateLastSeen();
      await signOut();
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not sign out. Please try again.')),
      );
    }
  }

  Future<void> _startCall(ChatThread thread, {required bool isVideo}) async {
    final callClient = _callClient;
    final peerUserId = thread.peerUserId;
    if (callClient == null ||
        !widget.repository.isConnected ||
        peerUserId == null ||
        peerUserId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Calls require a signed-in direct chat.')),
      );
      return;
    }

    try {
      await callClient.startCall(
        conversationId: thread.id,
        peerUserId: peerUserId,
        peerName: thread.title,
        callerName: widget.repository.localSenderName,
        isVideo: isVideo,
      );
    } on CallException catch (error, stackTrace) {
      _logCallFailure('Call start failed', error, stackTrace);
      _showCallError('Could not start the call.');
    } catch (error, stackTrace) {
      _logCallFailure('Call start failed', error, stackTrace);
      _showCallError('Could not start the call.');
    }
  }

  Future<void> _acceptIncomingCall() async {
    final invite = _incomingCallInvite;
    final callClient = _callClient;
    if (invite == null || callClient == null) {
      return;
    }

    setState(() {
      _incomingCallInvite = null;
    });

    try {
      await callClient.acceptInvite(
        invite: invite,
        peerName: invite.callerName,
      );
    } on CallException catch (error, stackTrace) {
      _logCallFailure('Call answer failed', error, stackTrace);
      _showCallError('Could not answer the call.');
    } catch (error, stackTrace) {
      _logCallFailure('Call answer failed', error, stackTrace);
      _showCallError('Could not answer the call.');
    }
  }

  Future<void> _rejectIncomingCall() async {
    final invite = _incomingCallInvite;
    final callClient = _callClient;
    if (invite == null || callClient == null) {
      return;
    }

    setState(() {
      _incomingCallInvite = null;
    });
    try {
      await callClient.rejectInvite(invite);
    } catch (error, stackTrace) {
      _logCallFailure('Call reject failed', error, stackTrace);
    }
  }

  void _toggleCallMute(CallSnapshot snapshot) {
    unawaited(_callClient?.setMuted(!snapshot.mediaState.isMuted));
  }

  void _toggleCallCamera(CallSnapshot snapshot) {
    unawaited(
      _callClient?.setCameraEnabled(!snapshot.mediaState.isCameraEnabled),
    );
  }

  void _switchCallCamera() {
    unawaited(_callClient?.switchCamera());
  }

  void _hangUpCall() {
    unawaited(_callClient?.hangUp());
  }

  void _showCallError(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _logCallFailure(String label, Object error, StackTrace stackTrace) {
    debugPrint('[$label] $error\n$stackTrace');
  }

  void _handleComposerChanged(ChatThread thread, String value) {
    if (!widget.repository.isConnected) {
      return;
    }

    _typingStopTimer?.cancel();

    if (value.trim().isEmpty) {
      unawaited(_stopTyping());
      return;
    }

    if (_activeTypingConversationId != thread.id) {
      if (_activeTypingConversationId != null) {
        unawaited(_stopTyping());
      }
      _activeTypingConversationId = thread.id;
      unawaited(
        widget.repository.setTyping(conversationId: thread.id, isTyping: true),
      );
    }

    _typingStopTimer = Timer(const Duration(milliseconds: 2500), () {
      unawaited(_stopTyping());
    });
  }

  Future<void> _stopTyping() async {
    _typingStopTimer?.cancel();
    final conversationId = _activeTypingConversationId;
    _activeTypingConversationId = null;
    if (conversationId == null) {
      return;
    }

    await widget.repository.setTyping(
      conversationId: conversationId,
      isTyping: false,
    );
  }

  Future<void> _stageMediaAttachment(
    ChatThread thread,
    ChatMediaSource source,
  ) async {
    try {
      final pickedMedia = source == ChatMediaSource.giphy
          ? await _pickGiphyMedia()
          : source == ChatMediaSource.camera
          ? await _captureCameraMedia()
          : await widget.repository.pickMediaAttachment(source);
      if (pickedMedia == null || !mounted) {
        return;
      }

      await _stagePickedMediaAttachment(thread, pickedMedia);
    } on MediaAttachmentException catch (error, stackTrace) {
      _logAttachmentFailure('Media selection failed', error, stackTrace);
      _showAttachmentError(error.message);
    } catch (error, stackTrace) {
      _logAttachmentFailure('Media selection failed', error, stackTrace);
      _showAttachmentError(
        'Could not add that image or GIF: ${_shortError(error)}',
      );
    }
  }

  Future<PickedChatMedia?> _pickGiphyMedia() async {
    final gif = await showDialog<GiphyGif>(
      context: context,
      builder: (context) => _GiphyPickerDialog(repository: widget.repository),
    );
    if (gif == null) {
      return null;
    }

    return widget.repository.downloadGiphyGif(gif);
  }

  Future<PickedChatMedia?> _captureCameraMedia() async {
    final captured = await showDialog<camera.XFile>(
      context: context,
      builder: (context) => const _CameraCaptureDialog(),
    );
    if (captured == null) {
      return null;
    }

    return widget.repository.pickedMediaFromBytes(
      bytes: await captured.readAsBytes(),
      originalName: captured.name,
      mimeType: captured.mimeType ?? 'image/jpeg',
    );
  }

  Future<void> _toggleVoiceRecording(ChatThread thread) async {
    if (_isRecordingVoice) {
      await _stopVoiceRecording(thread);
      return;
    }

    await _startVoiceRecording(thread);
  }

  Future<void> _startVoiceRecording(ChatThread thread) async {
    if (_isSending) {
      return;
    }

    try {
      final hasPermission = await _voiceRecorder.hasPermission();
      if (!hasPermission) {
        _showAttachmentError('Microphone permission is required.');
        return;
      }

      await _removeStagedAttachment();
      await _voiceDataSubscription?.cancel();
      await _voiceAmplitudeSubscription?.cancel();

      _voiceBytes.clear();
      _voiceLevels
        ..clear()
        ..addAll(List<double>.filled(24, 0.08));
      _voiceStreamDone = Completer<void>();
      _voiceRecordingStartedAt = DateTime.now();
      _voiceRecordingElapsed = Duration.zero;

      final useFileRecording = _shouldUseFileVoiceRecording;
      _isVoiceRecordingFileBacked = useFileRecording;
      if (useFileRecording) {
        final path = await createVoiceRecordingPath('m4a');
        _voiceRecordingFilePath = path;
        await _voiceRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            sampleRate: 44100,
            numChannels: 1,
            bitRate: 64000,
            echoCancel: true,
            noiseSuppress: true,
          ),
          path: path,
        );
      } else {
        final stream = await _voiceRecorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: _voiceSampleRate,
            numChannels: _voiceChannelCount,
            bitRate: 64000,
            echoCancel: true,
            noiseSuppress: true,
          ),
        );

        _voiceDataSubscription = stream.listen(
          _voiceBytes.addAll,
          onError: (Object error, StackTrace stackTrace) {
            _logAttachmentFailure('Voice recording failed', error, stackTrace);
            if (mounted) {
              _showAttachmentError('Voice recording stopped.');
            }
            unawaited(_cancelVoiceRecording());
          },
          onDone: () {
            final done = _voiceStreamDone;
            if (done != null && !done.isCompleted) {
              done.complete();
            }
          },
        );
      }

      _voiceAmplitudeSubscription = _voiceRecorder
          .onAmplitudeChanged(const Duration(milliseconds: 120))
          .listen((amplitude) {
            if (!mounted || !_isRecordingVoice) {
              return;
            }
            setState(() {
              _voiceLevels.add(_voiceLevelFromDb(amplitude.current));
              if (_voiceLevels.length > 48) {
                _voiceLevels.removeRange(0, _voiceLevels.length - 48);
              }
            });
          });

      _voiceRecordingTimer?.cancel();
      _voiceRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final startedAt = _voiceRecordingStartedAt;
        if (!mounted || startedAt == null) {
          return;
        }
        setState(() {
          _voiceRecordingElapsed = DateTime.now().difference(startedAt);
        });
      });

      if (!mounted) {
        await _cancelVoiceRecording();
        return;
      }

      setState(() {
        _isRecordingVoice = true;
      });
    } catch (error, stackTrace) {
      _logAttachmentFailure('Voice recording failed', error, stackTrace);
      if (mounted) {
        _showAttachmentError('Could not start voice recording.');
      }
      await _cancelVoiceRecording();
    }
  }

  Future<void> _stopVoiceRecording(ChatThread thread) async {
    if (!_isRecordingVoice) {
      return;
    }

    final startedAt = _voiceRecordingStartedAt;
    final elapsed = startedAt == null
        ? _voiceRecordingElapsed
        : DateTime.now().difference(startedAt);

    setState(() {
      _isRecordingVoice = false;
      _voiceRecordingElapsed = elapsed;
    });

    _voiceRecordingTimer?.cancel();
    _voiceRecordingTimer = null;
    await _voiceAmplitudeSubscription?.cancel();
    _voiceAmplitudeSubscription = null;

    try {
      final stoppedPath = await _voiceRecorder.stop();
      final isFileBacked = _isVoiceRecordingFileBacked;
      Uint8List bytes;
      String originalName;
      String mimeType;

      if (isFileBacked) {
        final path = stoppedPath ?? _voiceRecordingFilePath;
        if (path == null || path.isEmpty) {
          throw const MediaAttachmentException(
            'Could not save that voice message.',
          );
        }
        bytes = await readVoiceRecordingFile(path);
        originalName =
            'voice-${DateTime.now().millisecondsSinceEpoch.toString()}.m4a';
        mimeType = 'audio/mp4';
        await deleteVoiceRecordingFile(path);
      } else {
        await _voiceStreamDone?.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () {},
        );
        await _voiceDataSubscription?.cancel();
        _voiceDataSubscription = null;
        bytes = _wavBytesFromPcm16(
          pcmBytes: Uint8List.fromList(_voiceBytes),
          sampleRate: _voiceSampleRate,
          numChannels: _voiceChannelCount,
        );
        originalName =
            'voice-${DateTime.now().millisecondsSinceEpoch.toString()}.wav';
        mimeType = 'audio/wav';
      }

      final waveform = _compactVoiceLevels(_voiceLevels);
      _voiceBytes.clear();
      _voiceLevels.clear();
      _voiceRecordingStartedAt = null;
      _voiceRecordingFilePath = null;
      _voiceStreamDone = null;
      _isVoiceRecordingFileBacked = false;

      final pickedMedia = await widget.repository.pickedVoiceMessageFromBytes(
        bytes: bytes,
        duration: elapsed,
        waveform: waveform,
        originalName: originalName,
        mimeType: mimeType,
      );

      if (!mounted) {
        return;
      }
      await _stagePickedMediaAttachment(thread, pickedMedia);
    } on MediaAttachmentException catch (error, stackTrace) {
      _logAttachmentFailure('Voice recording failed', error, stackTrace);
      if (mounted) {
        _showAttachmentError(error.message);
      }
      await _cancelVoiceRecording();
    } catch (error, stackTrace) {
      _logAttachmentFailure('Voice recording failed', error, stackTrace);
      if (mounted) {
        _showAttachmentError('Could not save that voice message.');
      }
      await _cancelVoiceRecording();
    }
  }

  Future<void> _cancelVoiceRecording() async {
    _voiceRecordingTimer?.cancel();
    _voiceRecordingTimer = null;
    await _voiceAmplitudeSubscription?.cancel();
    _voiceAmplitudeSubscription = null;

    try {
      if (await _voiceRecorder.isRecording()) {
        await _voiceRecorder.stop();
      }
    } catch (_) {
      // Recording cancellation is best-effort during disposal and route changes.
    }

    await _voiceDataSubscription?.cancel();
    _voiceDataSubscription = null;
    final done = _voiceStreamDone;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
    _voiceStreamDone = null;
    _voiceBytes.clear();
    _voiceLevels.clear();
    _voiceRecordingStartedAt = null;
    await deleteVoiceRecordingFile(_voiceRecordingFilePath);
    _voiceRecordingFilePath = null;
    _isVoiceRecordingFileBacked = false;

    if (mounted && !_isTearingDown) {
      setState(() {
        _isRecordingVoice = false;
        _voiceRecordingElapsed = Duration.zero;
      });
    }
  }

  Future<void> _disposeVoiceRecorder() async {
    await _cancelVoiceRecording();
    await _voiceRecorder.dispose();
  }

  Future<void> _stagePickedMediaAttachment(
    ChatThread thread,
    PickedChatMedia pickedMedia,
  ) async {
    await _removeStagedAttachment();

    final attachment = _StagedMediaAttachment(
      conversationId: thread.id,
      pickedMedia: pickedMedia,
      status: _AttachmentUploadState.uploading,
      progress: widget.repository.isConnected ? 0 : 1,
    );

    setState(() {
      _stagedAttachment = attachment;
    });

    if (!widget.repository.isConnected) {
      final uploaded = widget.repository.prepareLocalMediaAttachment(
        conversationId: thread.id,
        pickedMedia: pickedMedia,
      );
      setState(() {
        _stagedAttachment = attachment.copyWith(
          status: _AttachmentUploadState.uploaded,
          progress: 1,
          uploadedMedia: uploaded,
        );
      });
      return;
    }

    await _uploadStagedAttachment(attachment);
  }

  Future<void> _retryStagedAttachment(ChatThread thread) async {
    final staged = _stagedAttachment;
    if (staged == null || staged.conversationId != thread.id) {
      return;
    }

    final nextStaged = _StagedMediaAttachment(
      conversationId: staged.conversationId,
      pickedMedia: staged.pickedMedia,
      status: _AttachmentUploadState.uploading,
      progress: 0,
    );

    setState(() {
      _stagedAttachment = nextStaged;
    });

    await _uploadStagedAttachment(nextStaged);
  }

  Future<void> _uploadStagedAttachment(
    _StagedMediaAttachment attachment,
  ) async {
    final uploadToken = Object();
    _activeUploadToken = uploadToken;

    try {
      final uploaded = await widget.repository.uploadMediaAttachment(
        conversationId: attachment.conversationId,
        pickedMedia: attachment.pickedMedia,
        onProgress: (progress) {
          if (!mounted ||
              _activeUploadToken != uploadToken ||
              _stagedAttachment?.pickedMedia != attachment.pickedMedia) {
            return;
          }

          setState(() {
            _stagedAttachment = _stagedAttachment?.copyWith(
              status: _AttachmentUploadState.uploading,
              progress: progress,
            );
          });
        },
      );

      if (!mounted ||
          _activeUploadToken != uploadToken ||
          _stagedAttachment?.pickedMedia != attachment.pickedMedia) {
        await widget.repository.deleteStagedMedia(uploaded.media);
        return;
      }

      setState(() {
        _stagedAttachment = _stagedAttachment?.copyWith(
          status: _AttachmentUploadState.uploaded,
          progress: 1,
          uploadedMedia: uploaded,
        );
      });
    } catch (error, stackTrace) {
      if (!mounted || _activeUploadToken != uploadToken) {
        return;
      }

      final message = _uploadErrorMessage(error);
      final details = _attachmentErrorDetails(error, stackTrace);
      _logAttachmentFailure('Media upload failed', error, stackTrace);

      setState(() {
        _stagedAttachment = _stagedAttachment?.copyWith(
          status: _AttachmentUploadState.failed,
          progress: 0,
          errorMessage: message,
          errorDetails: details,
        );
      });
    } finally {
      if (_activeUploadToken == uploadToken) {
        _activeUploadToken = null;
      }
    }
  }

  Future<void> _removeStagedAttachment() async {
    _activeUploadToken = null;
    final uploadedMedia = _stagedAttachment?.uploadedMedia?.media;
    if (mounted) {
      setState(() {
        _stagedAttachment = null;
      });
    } else {
      _stagedAttachment = null;
    }

    if (uploadedMedia != null) {
      await widget.repository.deleteStagedMedia(uploadedMedia);
    }
  }

  void _showAttachmentError(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _uploadErrorMessage(Object error) {
    if (error is ChatMediaUploadException) {
      return error.message;
    }
    if (error is StorageException) {
      final status = error.statusCode == null ? '' : ' (${error.statusCode})';
      return 'Upload failed$status: ${error.message}';
    }
    if (error is AuthException) {
      return error.message;
    }
    if (error is MediaAttachmentException) {
      return error.message;
    }
    return 'Upload failed: ${_shortError(error)}';
  }

  String _attachmentErrorDetails(Object error, StackTrace stackTrace) {
    final buffer = StringBuffer();
    if (error is ChatMediaUploadException) {
      buffer.writeln(error.details);
    } else if (error is MediaAttachmentException && error.details != null) {
      buffer.writeln(error.details);
    } else if (error is StorageException) {
      buffer
        ..writeln('StorageException: ${error.message}')
        ..writeln('Status: ${error.statusCode ?? 'unknown'}');
    } else if (error is AuthException) {
      buffer.writeln('AuthException: ${error.message}');
    } else {
      buffer.writeln('${error.runtimeType}: $error');
    }
    buffer.writeln('Stack: ${_firstStackFrame(stackTrace)}');
    return buffer.toString().trimRight();
  }

  void _logAttachmentFailure(
    String label,
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint('[$label] ${_attachmentErrorDetails(error, stackTrace)}');
  }

  Future<void> _sendMessage(ChatThread selectedThread) async {
    final text = _messageController.text.trim();
    final editing = _editingMessage?.threadId == selectedThread.id
        ? _editingMessage
        : null;
    if (editing != null) {
      await _submitMessageEdit(editing, text);
      return;
    }
    final replyTo = _replyingTo?.threadId == selectedThread.id
        ? _replyingTo
        : null;
    final stagedAttachment =
        _stagedAttachment?.conversationId == selectedThread.id
        ? _stagedAttachment
        : null;
    final uploadedMedia = stagedAttachment?.uploadedMedia;
    final hasSupabaseClient = widget.repository.client != null;
    final hasQueuedAttachment = stagedAttachment != null;

    if (_isSending ||
        stagedAttachment?.isUploading == true ||
        (!hasSupabaseClient &&
            stagedAttachment?.status == _AttachmentUploadState.failed) ||
        (text.isEmpty && uploadedMedia == null && !hasQueuedAttachment)) {
      return;
    }

    if (hasSupabaseClient) {
      await _queueAndFlushMessage(
        selectedThread: selectedThread,
        text: text,
        stagedAttachment: stagedAttachment,
        replyTo: replyTo,
      );
      return;
    }

    _messageController.clear();
    FocusScope.of(context).unfocus();

    if (!widget.repository.isConnected) {
      setState(() {
        _localMessages.add(
          ChatMessage(
            id:
                uploadedMedia?.messageId ??
                'local-${DateTime.now().microsecondsSinceEpoch}',
            threadId: selectedThread.id,
            senderId: ChatSeed.localUserId,
            senderName: 'You',
            body: text,
            createdAt: DateTime.now(),
            isMine: true,
            isDelivered: false,
            isRead: false,
            messageType: uploadedMedia?.media.isVoice == true
                ? ChatMessageType.voice
                : uploadedMedia?.media.isGif == true
                ? ChatMessageType.gif
                : uploadedMedia == null
                ? ChatMessageType.text
                : ChatMessageType.image,
            media: uploadedMedia?.media,
            replyTo: replyTo == null
                ? null
                : MessageReplyPreview.fromMessage(replyTo),
          ),
        );
        _stagedAttachment = null;
        _replyingTo = null;
      });
      return;
    }

    setState(() {
      _isSending = true;
    });

    try {
      await _stopTyping();
      if (uploadedMedia == null) {
        await widget.repository.sendMessage(
          conversationId: selectedThread.id,
          body: text,
          replyToMessageId: replyTo?.id,
        );
      } else {
        await widget.repository.sendMediaMessage(
          conversationId: selectedThread.id,
          messageId: uploadedMedia.messageId,
          body: text,
          media: uploadedMedia.media,
          replyToMessageId: replyTo?.id,
        );
      }
      if (mounted && uploadedMedia != null) {
        setState(() {
          _stagedAttachment = null;
          _replyingTo = null;
        });
      }
    } catch (_) {
      if (mounted) {
        _messageController.text = text;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message not sent. Check Supabase auth and RLS.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  Future<void> _queueAndFlushMessage({
    required ChatThread selectedThread,
    required String text,
    required _StagedMediaAttachment? stagedAttachment,
    ChatMessage? replyTo,
  }) async {
    final activeOutbox = await _ensureOfflineOutbox();
    if (activeOutbox == null) {
      throw StateError('The signed-in account is not ready to queue messages.');
    }

    setState(() {
      _isSending = true;
    });

    try {
      await activeOutbox.initialize();
      await _stopTyping();
      await activeOutbox.enqueue(
        conversationId: selectedThread.id,
        senderId: widget.repository.localUserId,
        senderName: widget.repository.localSenderName,
        body: text,
        pickedMedia: stagedAttachment?.uploadedMedia == null
            ? stagedAttachment?.pickedMedia
            : null,
        uploadedMedia: stagedAttachment?.uploadedMedia,
        replyTo: replyTo == null
            ? null
            : MessageReplyPreview.fromMessage(replyTo),
      );
      if (mounted) {
        setState(() {
          _messageController.clear();
          _stagedAttachment = null;
          _replyingTo = null;
        });
        FocusScope.of(context).unfocus();
      }
      await _refreshOutboxMessages(activeOutbox);
      await _flushOutbox();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _messageController.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Message not queued: ${_shortError(error)}')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  void _startReply(ChatMessage message) {
    setState(() {
      _replyingTo = message;
      _editingMessage = null;
    });
  }

  void _startEdit(ChatMessage message) {
    setState(() {
      _editingMessage = message;
      _replyingTo = null;
      _messageController
        ..text = message.body
        ..selection = TextSelection.collapsed(offset: message.body.length);
    });
  }

  void _cancelComposerAction() {
    setState(() {
      final wasEditing = _editingMessage != null;
      _replyingTo = null;
      _editingMessage = null;
      if (wasEditing) {
        _messageController.clear();
      }
    });
  }

  Future<void> _submitMessageEdit(ChatMessage message, String body) async {
    if (message.messageType == ChatMessageType.text && body.isEmpty) {
      _showMessageActionError('Text messages cannot be empty.');
      return;
    }
    try {
      if (widget.repository.isConnected) {
        await widget.repository.editMessage(messageId: message.id, body: body);
      } else {
        _replaceLocalMessage(
          message.copyWith(body: body, editedAt: DateTime.now()),
        );
      }
      if (!mounted) return;
      setState(() {
        _editingMessage = null;
        _messageController.clear();
      });
    } catch (error) {
      _showMessageActionError('Message not edited: ${_shortError(error)}');
    }
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('This message will be deleted for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (widget.repository.isConnected) {
        await widget.repository.deleteMessage(message);
      } else {
        _replaceLocalMessage(
          message.copyWith(
            body: '',
            messageType: ChatMessageType.text,
            deletedAt: DateTime.now(),
            reactions: const [],
            clearMedia: true,
            clearReply: true,
          ),
        );
      }
      if (_editingMessage?.id == message.id || _replyingTo?.id == message.id) {
        _cancelComposerAction();
      }
    } catch (error) {
      _showMessageActionError('Message not deleted: ${_shortError(error)}');
    }
  }

  Future<void> _toggleMessageReaction(ChatMessage message, String emoji) async {
    try {
      if (widget.repository.isConnected) {
        await widget.repository.toggleMessageReaction(
          messageId: message.id,
          emoji: emoji,
        );
        return;
      }
      final reactions = [...message.reactions];
      final index = reactions.indexWhere((reaction) => reaction.emoji == emoji);
      if (index == -1) {
        reactions.add(
          MessageReactionSummary(emoji: emoji, count: 1, reactedByMe: true),
        );
      } else {
        final reaction = reactions[index];
        if (reaction.reactedByMe && reaction.count == 1) {
          reactions.removeAt(index);
        } else {
          reactions[index] = MessageReactionSummary(
            emoji: emoji,
            count: reaction.count + (reaction.reactedByMe ? -1 : 1),
            reactedByMe: !reaction.reactedByMe,
          );
        }
      }
      _replaceLocalMessage(message.copyWith(reactions: reactions));
    } catch (error) {
      _showMessageActionError('Reaction not updated: ${_shortError(error)}');
    }
  }

  Future<void> _showReactionPicker(ChatMessage message) async {
    const quick = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: math.min(430, MediaQuery.sizeOf(context).height * 0.72),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  children: quick
                      .map(
                        (emoji) => ActionChip(
                          label: Text(
                            emoji,
                            style: const TextStyle(fontSize: 22),
                          ),
                          onPressed: () => Navigator.pop(context, emoji),
                        ),
                      )
                      .toList(),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: EmojiPicker(
                  onEmojiSelected: (_, emoji) =>
                      Navigator.pop(context, emoji.emoji),
                  config: const Config(height: 330),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      await _toggleMessageReaction(message, selected);
    }
  }

  Future<void> _copyMessage(ChatMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.body));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message copied.')));
  }

  Future<void> _forwardMessage(ChatMessage message) async {
    final destination = await showDialog<ChatThread>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Forward to'),
        children: _availableThreads
            .map(
              (thread) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, thread),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _Avatar(thread: thread, size: 40),
                  title: Text(thread.title),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (destination == null) return;

    try {
      if (!widget.repository.isConnected) {
        setState(() {
          _localMessages.add(
            ChatMessage(
              id: 'local-forward-${DateTime.now().microsecondsSinceEpoch}',
              threadId: destination.id,
              senderId: ChatSeed.localUserId,
              senderName: 'You',
              body: message.body,
              createdAt: DateTime.now(),
              isMine: true,
              isDelivered: false,
              isRead: false,
              messageType: message.messageType,
              media: message.media,
              isForwarded: true,
            ),
          );
        });
      } else {
        final outbox = await _ensureOfflineOutbox();
        if (outbox == null) {
          throw StateError('The signed-in account is not ready.');
        }
        final pickedMedia = message.media == null
            ? null
            : await widget.repository.mediaForForward(message.media!);
        await outbox.enqueue(
          conversationId: destination.id,
          senderId: widget.repository.localUserId,
          senderName: widget.repository.localSenderName,
          body: message.body,
          pickedMedia: pickedMedia,
          isForwarded: true,
        );
        await _refreshOutboxMessages(outbox);
        await _flushOutbox();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Forwarded to ${destination.title}.')),
      );
    } catch (error) {
      _showMessageActionError('Message not forwarded: ${_shortError(error)}');
    }
  }

  void _replaceLocalMessage(ChatMessage message) {
    setState(() {
      _localMessages.removeWhere((item) => item.id == message.id);
      _localMessages.add(message);
    });
  }

  void _showMessageActionError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog({required this.repository});

  final ChatRepository repository;

  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<ChatUser> _users = const [];
  String _query = '';
  String? _error;
  bool _isLoading = false;
  int _requestId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.edit_square),
          SizedBox(width: 10),
          Text('New message'),
        ],
      ),
      content: SizedBox(
        width: 440,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const Key('new-chat-search'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _scheduleSearch,
              decoration: const InputDecoration(
                hintText: 'Search people',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(child: _buildResults(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }

    if (_query.trim().isEmpty) {
      return Center(
        child: Text(
          'Search by name.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    if (_users.isEmpty) {
      return Center(
        child: Text(
          widget.repository.isConnected
              ? 'No users found. Make sure profiles exist in Supabase.'
              : 'No users found.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: _users.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final user = _users[index];
        return ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: _UserAvatar(user: user),
          title: Text(user.displayName),
          subtitle: user.email == null ? null : Text(user.email!),
          onTap: () => Navigator.of(context).pop(user),
        );
      },
    );
  }

  void _scheduleSearch(String value) {
    _debounce?.cancel();

    setState(() {
      _query = value;
      _error = null;
      _users = const [];
      _isLoading = value.trim().isNotEmpty;
    });

    if (value.trim().isEmpty) {
      return;
    }

    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => _searchUsers(value),
    );
  }

  Future<void> _searchUsers(String query) async {
    final requestId = ++_requestId;

    try {
      final users = await widget.repository.searchUsers(query);
      if (!mounted || requestId != _requestId) {
        return;
      }

      setState(() {
        _users = users;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) {
        return;
      }

      setState(() {
        _error = 'Could not search users.';
        _isLoading = false;
      });
    }
  }
}

class _GiphyPickerDialog extends StatefulWidget {
  const _GiphyPickerDialog({required this.repository});

  final ChatRepository repository;

  @override
  State<_GiphyPickerDialog> createState() => _GiphyPickerDialogState();
}

class _GiphyPickerDialogState extends State<_GiphyPickerDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<GiphyGif> _gifs = const [];
  String? _error;
  bool _isLoading = true;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadGifs(''));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.gif_box_outlined),
          SizedBox(width: 10),
          Text('GIF'),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 520,
        child: Column(
          children: [
            TextField(
              key: const Key('giphy-search'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _scheduleSearch,
              decoration: const InputDecoration(
                hintText: 'Search GIPHY',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildResults(theme)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Powered by GIPHY',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }

    if (_gifs.isEmpty) {
      return Center(
        child: Text(
          'No GIFs found.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: _gifs.length,
      itemBuilder: (context, index) {
        final gif = _gifs[index];
        return InkWell(
          key: Key('giphy-result-${gif.id}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.of(context).pop(gif),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: gif.previewUrl,
              cacheKey: 'giphy-preview:${gif.id}',
              fit: BoxFit.cover,
              placeholder: (context, url) =>
                  ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
              errorWidget: (context, url, error) => ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
        );
      },
    );
  }

  void _scheduleSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _loadGifs(value),
    );
  }

  Future<void> _loadGifs(String query) async {
    final requestId = ++_requestId;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final gifs = await widget.repository.searchGiphyGifs(query);
      if (!mounted || requestId != _requestId) {
        return;
      }

      setState(() {
        _gifs = gifs;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) {
        return;
      }

      setState(() {
        _error = 'Could not load GIFs.';
        _isLoading = false;
      });
    }
  }
}

class _CameraCaptureDialog extends StatefulWidget {
  const _CameraCaptureDialog();

  @override
  State<_CameraCaptureDialog> createState() => _CameraCaptureDialogState();
}

class _CameraCaptureDialogState extends State<_CameraCaptureDialog> {
  List<camera.CameraDescription> _cameras = const [];
  camera.CameraController? _controller;
  String? _error;
  bool _isLoading = true;
  bool _isCapturing = false;
  int _cameraIndex = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCameras());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.photo_camera_outlined),
          SizedBox(width: 10),
          Text('Camera'),
        ],
      ),
      content: SizedBox(width: 620, height: 500, child: _buildContent(theme)),
      actions: [
        TextButton(
          onPressed: _isCapturing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_cameras.length > 1)
          TextButton.icon(
            onPressed: _isCapturing ? null : _switchCamera,
            icon: const Icon(Icons.cameraswitch_outlined),
            label: const Text('Switch'),
          ),
        FilledButton.icon(
          key: const Key('camera-capture'),
          onPressed: _controller?.value.isInitialized == true && !_isCapturing
              ? _capture
              : null,
          icon: _isCapturing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.camera_alt_outlined),
          label: const Text('Capture'),
        ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Center(
        child: Text(
          'No camera preview available.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: camera.CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  Future<void> _loadCameras() async {
    try {
      final cameras = await camera.availableCameras();
      if (!mounted) {
        return;
      }
      if (cameras.isEmpty) {
        setState(() {
          _error = 'No camera found.';
          _isLoading = false;
        });
        return;
      }

      _cameras = cameras;
      await _initializeCamera(0);
    } on camera.CameraException catch (error) {
      _setCameraError(error.description ?? error.code);
    } catch (_) {
      _setCameraError('Could not open the camera.');
    }
  }

  Future<void> _initializeCamera(int index) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final oldController = _controller;
    _controller = null;
    await oldController?.dispose();

    final controller = camera.CameraController(
      _cameras[index],
      camera.ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _cameraIndex = index;
        _controller = controller;
        _isLoading = false;
      });
    } on camera.CameraException catch (error) {
      await controller.dispose();
      _setCameraError(error.description ?? error.code);
    } catch (_) {
      await controller.dispose();
      _setCameraError('Could not open the camera.');
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) {
      return;
    }
    final nextIndex = (_cameraIndex + 1) % _cameras.length;
    await _initializeCamera(nextIndex);
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }

    setState(() {
      _isCapturing = true;
    });

    try {
      final image = await controller.takePicture();
      if (mounted) {
        Navigator.of(context).pop(image);
      }
    } on camera.CameraException catch (error) {
      _setCameraError(error.description ?? error.code);
    } catch (_) {
      _setCameraError('Could not capture a photo.');
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
    }
  }

  void _setCameraError(String message) {
    if (!mounted) {
      return;
    }

    setState(() {
      _error = message;
      _isLoading = false;
      _isCapturing = false;
    });
  }
}

class _UserAvatar extends StatelessWidget {
  const _UserAvatar({required this.user});

  final ChatUser user;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        user.avatarLabel,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ThreadList extends StatelessWidget {
  const _ThreadList({
    required this.threads,
    required this.selectedThread,
    required this.isConnected,
    required this.searchController,
    required this.onSearchChanged,
    required this.onThreadSelected,
    required this.onNewChat,
    required this.onOpenProfile,
    required this.onRefresh,
    required this.onSignOut,
  });

  final List<ChatThread> threads;
  final ChatThread? selectedThread;
  final bool isConnected;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<ChatThread> onThreadSelected;
  final VoidCallback onNewChat;
  final VoidCallback onOpenProfile;
  final Future<void> Function() onRefresh;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Messages',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'New chat',
                  onPressed: onNewChat,
                  icon: const Icon(Icons.edit_square),
                ),
                IconButton(
                  tooltip: 'Profile',
                  onPressed: onOpenProfile,
                  icon: const Icon(Icons.account_circle_outlined),
                ),
                IconButton(
                  tooltip: 'Sign out',
                  onPressed: onSignOut,
                  icon: const Icon(Icons.logout),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: searchController,
              onChanged: onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search chats',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            _BackendStatusPill(isConnected: isConnected),
            const SizedBox(height: 16),
            Expanded(
              child: RefreshIndicator(
                onRefresh: onRefresh,
                child: threads.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 280, child: _EmptyThreadList()),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: threads.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final thread = threads[index];
                          return _ThreadTile(
                            thread: thread,
                            isSelected: thread.id == selectedThread?.id,
                            onTap: () => onThreadSelected(thread),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyThreadList extends StatelessWidget {
  const _EmptyThreadList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No conversations yet.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _BackendStatusPill extends StatelessWidget {
  const _BackendStatusPill({required this.isConnected});

  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isConnected
        ? const Color(0xFF127A74)
        : const Color(0xFFB5661B);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isConnected ? Icons.cloud_done : Icons.data_object,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isConnected
                  ? 'Supabase realtime connected'
                  : 'Local preview data',
              style: theme.textTheme.labelLarge?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    required this.thread,
    required this.isSelected,
    required this.onTap,
  });

  final ChatThread thread;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedColor = theme.colorScheme.primary.withValues(alpha: 0.1);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? selectedColor : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary.withValues(alpha: 0.28)
                : theme.dividerColor.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            _Avatar(thread: thread, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          thread.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        thread.lastActive,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          thread.displaySubtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: thread.isTyping
                                ? const Color(0xFF127A74)
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: thread.isTyping
                                ? FontWeight.w700
                                : null,
                          ),
                        ),
                      ),
                      if (thread.unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        _UnreadBadge(count: thread.unreadCount),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyConversationPane extends StatelessWidget {
  const _EmptyConversationPane();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Text(
        'Start a new conversation.',
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({
    super.key,
    required this.thread,
    required this.repository,
    required this.localMessages,
    required this.stagedAttachment,
    required this.messageController,
    required this.isSending,
    required this.isRecordingVoice,
    required this.voiceRecordingElapsed,
    required this.voiceRecordingLevels,
    required this.showBackButton,
    required this.onBackToInbox,
    required this.onSend,
    required this.onAttachMedia,
    required this.onToggleVoiceRecording,
    required this.onRemoveAttachment,
    required this.onRetryAttachment,
    required this.onRetryOutboxMessage,
    required this.onComposerChanged,
    required this.onStartAudioCall,
    required this.onStartVideoCall,
    required this.onOpenProfile,
    required this.onSignOut,
    required this.replyingTo,
    required this.editingMessage,
    required this.onCancelComposerAction,
    required this.onReply,
    required this.onEdit,
    required this.onDelete,
    required this.onReact,
    required this.onToggleReaction,
    required this.onForward,
    required this.onCopy,
  });

  final ChatThread thread;
  final ChatRepository repository;
  final List<ChatMessage> localMessages;
  final _StagedMediaAttachment? stagedAttachment;
  final TextEditingController messageController;
  final bool isSending;
  final bool isRecordingVoice;
  final Duration voiceRecordingElapsed;
  final List<double> voiceRecordingLevels;
  final bool showBackButton;
  final VoidCallback onBackToInbox;
  final VoidCallback onSend;
  final ValueChanged<ChatMediaSource> onAttachMedia;
  final VoidCallback onToggleVoiceRecording;
  final Future<void> Function() onRemoveAttachment;
  final VoidCallback onRetryAttachment;
  final Future<void> Function(String messageId) onRetryOutboxMessage;
  final ValueChanged<String> onComposerChanged;
  final VoidCallback onStartAudioCall;
  final VoidCallback onStartVideoCall;
  final VoidCallback onOpenProfile;
  final VoidCallback onSignOut;
  final ChatMessage? replyingTo;
  final ChatMessage? editingMessage;
  final VoidCallback onCancelComposerAction;
  final ValueChanged<ChatMessage> onReply;
  final ValueChanged<ChatMessage> onEdit;
  final Future<void> Function(ChatMessage) onDelete;
  final Future<void> Function(ChatMessage) onReact;
  final Future<void> Function(ChatMessage, String) onToggleReaction;
  final Future<void> Function(ChatMessage) onForward;
  final Future<void> Function(ChatMessage) onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.08),
              ),
            ),
          ),
          child: Row(
            children: [
              if (showBackButton)
                IconButton(
                  tooltip: 'Back to chats',
                  onPressed: onBackToInbox,
                  icon: const Icon(Icons.arrow_back),
                ),
              _Avatar(thread: thread, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      thread.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 8,
                          color: thread.isOnline || thread.isTyping
                              ? const Color(0xFF17A36B)
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            thread.activityLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: thread.isTyping
                                  ? const Color(0xFF127A74)
                                  : theme.colorScheme.onSurfaceVariant,
                              fontWeight: thread.isTyping
                                  ? FontWeight.w700
                                  : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Call',
                onPressed: onStartAudioCall,
                icon: const Icon(Icons.call_outlined),
              ),
              IconButton(
                tooltip: 'Video',
                onPressed: onStartVideoCall,
                icon: const Icon(Icons.videocam_outlined),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<ChatMessage>>(
            stream: repository.watchMessages(thread.id),
            builder: (context, snapshot) {
              final remoteMessages =
                  snapshot.data ?? ChatSeed.messagesFor(thread.id);
              final messagesById = <String, ChatMessage>{
                for (final message in remoteMessages) message.id: message,
                for (final message in localMessages) message.id: message,
              };
              final messages = messagesById.values.toList()
                ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

              if (repository.isConnected && messages.isNotEmpty) {
                unawaited(repository.markConversationRead(thread.id));
              }

              if (messages.isEmpty) {
                return const _EmptyMessageList();
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  return _MessageBubble(
                    message: messages[index],
                    repository: repository,
                    onRetry: () => onRetryOutboxMessage(messages[index].id),
                    onReply: onReply,
                    onEdit: onEdit,
                    onDelete: onDelete,
                    onReact: onReact,
                    onToggleReaction: onToggleReaction,
                    onForward: onForward,
                    onCopy: onCopy,
                  );
                },
              );
            },
          ),
        ),
        _MessageComposer(
          controller: messageController,
          isSending: isSending,
          isRecordingVoice: isRecordingVoice,
          voiceRecordingElapsed: voiceRecordingElapsed,
          voiceRecordingLevels: voiceRecordingLevels,
          stagedAttachment: stagedAttachment,
          replyingTo: replyingTo,
          editingMessage: editingMessage,
          onCancelComposerAction: onCancelComposerAction,
          onAttachMedia: onAttachMedia,
          onToggleVoiceRecording: onToggleVoiceRecording,
          onRemoveAttachment: onRemoveAttachment,
          onRetryAttachment: onRetryAttachment,
          onChanged: onComposerChanged,
          onSend: onSend,
        ),
      ],
    );
  }
}

enum _MessageAction { reply, react, edit, delete, forward, copy }

class _IncomingCallOverlay extends StatelessWidget {
  const _IncomingCallOverlay({
    required this.invite,
    required this.onAccept,
    required this.onReject,
  });

  final CallInvite invite;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 34,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Icon(
                        invite.isVideo ? Icons.videocam : Icons.call,
                        color: theme.colorScheme.onPrimaryContainer,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      invite.callerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      invite.isVideo ? 'Incoming video call' : 'Incoming call',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 22),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: onReject,
                          icon: const Icon(Icons.call_end),
                          label: const Text('Decline'),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: onAccept,
                          icon: const Icon(Icons.call),
                          label: const Text('Answer'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveCallOverlay extends StatelessWidget {
  const _ActiveCallOverlay({
    required this.snapshot,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onHangUp,
  });

  final CallSnapshot snapshot;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onHangUp;

  @override
  Widget build(BuildContext context) {
    final isVideo = snapshot.mediaState.isVideoEnabled;
    return Positioned.fill(
      child: Material(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: isVideo
                  ? CallVideoView(
                      renderer: snapshot.remoteRenderer,
                      placeholderIcon: Icons.person,
                    )
                  : _AudioCallBackground(snapshot: snapshot),
            ),
            Positioned(
              top: 18,
              left: 18,
              right: 18,
              child: SafeArea(
                child: Column(
                  children: [
                    Text(
                      snapshot.peerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    CallStatusLabel(snapshot: snapshot),
                  ],
                ),
              ),
            ),
            if (isVideo)
              Positioned(
                top: 92,
                right: 18,
                child: SafeArea(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 132,
                      height: 176,
                      child: CallVideoView(
                        renderer: snapshot.localRenderer,
                        mirror: true,
                        placeholderIcon: Icons.videocam_off,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: CallControls(
                mediaState: snapshot.mediaState,
                showCameraControls: isVideo,
                onToggleMute: onToggleMute,
                onToggleCamera: onToggleCamera,
                onSwitchCamera: onSwitchCamera,
                onHangUp: onHangUp,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioCallBackground extends StatelessWidget {
  const _AudioCallBackground({required this.snapshot});

  final CallSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final initials = snapshot.peerName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part.characters.first)
        .take(2)
        .join()
        .toUpperCase();

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF071817), Color(0xFF111418), Color(0xFF1B2A2A)],
        ),
      ),
      child: Center(
        child: CircleAvatar(
          radius: 58,
          backgroundColor: Colors.white24,
          child: Text(
            initials.isEmpty ? '?' : initials,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyMessageList extends StatelessWidget {
  const _EmptyMessageList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Text(
        'No messages yet.',
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.repository,
    required this.onRetry,
    required this.onReply,
    required this.onEdit,
    required this.onDelete,
    required this.onReact,
    required this.onToggleReaction,
    required this.onForward,
    required this.onCopy,
  });

  final ChatMessage message;
  final ChatRepository repository;
  final Future<void> Function() onRetry;
  final ValueChanged<ChatMessage> onReply;
  final ValueChanged<ChatMessage> onEdit;
  final Future<void> Function(ChatMessage) onDelete;
  final Future<void> Function(ChatMessage) onReact;
  final Future<void> Function(ChatMessage, String) onToggleReaction;
  final Future<void> Function(ChatMessage) onForward;
  final Future<void> Function(ChatMessage) onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (message.messageType == ChatMessageType.call) {
      return _CallEventBubble(message: message);
    }

    final isMine = message.isMine;
    final media = message.media;
    final hasText = message.body.trim().isNotEmpty;
    final bubbleColor = isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isMine
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    final bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(8),
          topRight: const Radius.circular(8),
          bottomLeft: Radius.circular(isMine ? 8 : 2),
          bottomRight: Radius.circular(isMine ? 2 : 8),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          media == null ? 14 : 6,
          media == null ? 10 : 6,
          media == null ? 14 : 6,
          8,
        ),
        child: Column(
          crossAxisAlignment: isMine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (!isMine) ...[
              Text(
                message.senderName,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: textColor.withValues(alpha: 0.74),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
            ],
            if (message.isForwarded && !message.isDeleted)
              _MessageFlag(
                icon: Icons.forward,
                label: 'Forwarded',
                color: textColor.withValues(alpha: 0.72),
              ),
            if (message.replyTo case final reply?) ...[
              _ReplyPreviewCard(reply: reply, color: textColor),
              const SizedBox(height: 8),
            ],
            if (message.isDeleted)
              Text(
                'Message deleted',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: textColor.withValues(alpha: 0.72),
                  fontStyle: FontStyle.italic,
                ),
              )
            else ...[
              if (media != null) ...[
                _MessageMediaPreview(
                  message: message,
                  media: media,
                  repository: repository,
                ),
                if (hasText) const SizedBox(height: 8),
              ],
              if (hasText)
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: media == null ? 0 : 8,
                  ),
                  child: Text(
                    message.body,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: textColor,
                      height: 1.25,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 6),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: media == null ? 0 : 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.isEdited) ...[
                    Text(
                      'Edited',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: textColor.withValues(alpha: 0.72),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    _formatTime(message.createdAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: textColor.withValues(alpha: 0.72),
                    ),
                  ),
                  if (isMine) ...[
                    const SizedBox(width: 6),
                    _ReceiptIcon(
                      message: message,
                      fallbackColor: textColor.withValues(alpha: 0.72),
                      onRetry: onRetry,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: isMine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: message.isDeleted
                    ? null
                    : () => _showActions(context),
                onSecondaryTapDown: message.isDeleted
                    ? null
                    : (_) => _showActions(context),
                child: bubble,
              ),
              if (message.reactions.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: message.reactions
                      .map(
                        (reaction) => ActionChip(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: reaction.reactedByMe
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHighest,
                          label: Text('${reaction.emoji} ${reaction.count}'),
                          onPressed: () => unawaited(
                            onToggleReaction(message, reaction.emoji),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context) async {
    final sent = message.sendState == ChatMessageSendState.sent;
    final action = await showModalBottomSheet<_MessageAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            if (sent) ...[
              _MessageActionTile(
                icon: Icons.reply,
                label: 'Reply',
                action: _MessageAction.reply,
              ),
              _MessageActionTile(
                icon: Icons.add_reaction_outlined,
                label: 'React',
                action: _MessageAction.react,
              ),
              _MessageActionTile(
                icon: Icons.forward,
                label: 'Forward',
                action: _MessageAction.forward,
              ),
            ],
            if (message.body.trim().isNotEmpty)
              _MessageActionTile(
                icon: Icons.copy_outlined,
                label: 'Copy',
                action: _MessageAction.copy,
              ),
            if (message.isMine && sent) ...[
              _MessageActionTile(
                icon: Icons.edit_outlined,
                label: 'Edit',
                action: _MessageAction.edit,
              ),
              _MessageActionTile(
                icon: Icons.delete_outline,
                label: 'Delete',
                action: _MessageAction.delete,
              ),
            ],
          ],
        ),
      ),
    );
    if (action == null) return;
    switch (action) {
      case _MessageAction.reply:
        onReply(message);
        return;
      case _MessageAction.react:
        await onReact(message);
        return;
      case _MessageAction.edit:
        onEdit(message);
        return;
      case _MessageAction.delete:
        await onDelete(message);
        return;
      case _MessageAction.forward:
        await onForward(message);
        return;
      case _MessageAction.copy:
        await onCopy(message);
        return;
    }
  }
}

class _MessageActionTile extends StatelessWidget {
  const _MessageActionTile({
    required this.icon,
    required this.label,
    required this.action,
  });

  final IconData icon;
  final String label;
  final _MessageAction action;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      onTap: () => Navigator.pop(context, action),
    );
  }
}

class _MessageFlag extends StatelessWidget {
  const _MessageFlag({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _ReplyPreviewCard extends StatelessWidget {
  const _ReplyPreviewCard({required this.reply, required this.color});

  final MessageReplyPreview reply;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reply.senderName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            reply.preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _CallEventBubble extends StatelessWidget {
  const _CallEventBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = message.body.trim().isEmpty ? 'Call updated' : message.body;

    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.call_outlined,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '$text · ${_formatTime(message.createdAt)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageMediaPreview extends StatelessWidget {
  const _MessageMediaPreview({
    required this.message,
    required this.media,
    required this.repository,
  });

  final ChatMessage message;
  final ChatMedia media;
  final ChatRepository repository;

  @override
  Widget build(BuildContext context) {
    if (media.isVoice) {
      return _VoiceMessagePreview(
        message: message,
        media: media,
        repository: repository,
      );
    }

    final borderRadius = BorderRadius.circular(7);

    return InkWell(
      key: Key('media-preview-${message.id}'),
      borderRadius: borderRadius,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => _MediaViewerPage(
              message: message,
              media: media,
              repository: repository,
            ),
          ),
        );
      },
      child: Stack(
        children: [
          Hero(
            tag: _mediaHeroTag(message),
            child: ClipRRect(
              borderRadius: borderRadius,
              child: AspectRatio(
                aspectRatio: _previewAspectRatio(media),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _ChatMediaImage(
                      media: media,
                      repository: repository,
                      fit: BoxFit.cover,
                    ),
                    if (media.isGif)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.62),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            child: Text(
                              'GIF',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: _MediaDownloadButton(
              keyPrefix: 'media-download',
              message: message,
              media: media,
              repository: repository,
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceMessagePreview extends StatelessWidget {
  const _VoiceMessagePreview({
    required this.message,
    required this.media,
    required this.repository,
  });

  final ChatMessage message;
  final ChatMedia media;
  final ChatRepository repository;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foregroundColor = message.isMine
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.primary;
    final subduedColor = foregroundColor.withValues(alpha: 0.72);

    return Container(
      key: Key('voice-preview-${message.id}'),
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 330),
      padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
      decoration: BoxDecoration(
        color: foregroundColor.withValues(alpha: message.isMine ? 0.10 : 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _VoicePlaybackButton(
            repository: repository,
            media: media,
            foregroundColor: foregroundColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _VoiceWaveform(
              levels: media.waveform,
              height: 34,
              barColor: foregroundColor,
              trackColor: foregroundColor.withValues(alpha: 0.20),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatDuration(media.duration ?? Duration.zero),
            style: theme.textTheme.labelMedium?.copyWith(
              color: subduedColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          IconButton(
            key: Key('voice-download-${message.id}'),
            tooltip: 'Download voice message',
            visualDensity: VisualDensity.compact,
            onPressed: () => _downloadMediaAttachment(
              context: context,
              repository: repository,
              media: media,
            ),
            icon: Icon(Icons.download_outlined, color: subduedColor, size: 20),
          ),
        ],
      ),
    );
  }
}

class _VoiceRecordingCard extends StatelessWidget {
  const _VoiceRecordingCard({required this.elapsed, required this.levels});

  final Duration elapsed;
  final List<double> levels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;

    return Container(
      key: const Key('voice-recording-card'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record, color: color, size: 14),
          const SizedBox(width: 8),
          Text(
            _formatDuration(elapsed),
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _VoiceWaveform(
              levels: levels,
              height: 32,
              barColor: color,
              trackColor: color.withValues(alpha: 0.18),
            ),
          ),
        ],
      ),
    );
  }
}

class _VoicePlaybackButton extends StatefulWidget {
  const _VoicePlaybackButton({
    required this.repository,
    required this.media,
    required this.foregroundColor,
    this.pickedMedia,
  });

  final ChatRepository? repository;
  final ChatMedia? media;
  final PickedChatMedia? pickedMedia;
  final Color foregroundColor;

  @override
  State<_VoicePlaybackButton> createState() => _VoicePlaybackButtonState();
}

class _VoicePlaybackButtonState extends State<_VoicePlaybackButton> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  String? _loadedSourceKey;
  bool _isBusy = false;
  bool _isPlaying = false;

  @override
  void didUpdateWidget(covariant _VoicePlaybackButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sourceKey != _loadedSourceKey) {
      _loadedSourceKey = null;
      _isPlaying = false;
    }
  }

  @override
  void dispose() {
    unawaited(_playerStateSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  String get _sourceKey {
    final pickedMedia = widget.pickedMedia;
    if (pickedMedia != null) {
      return 'picked:${pickedMedia.originalName}:${pickedMedia.sizeBytes}';
    }
    final media = widget.media;
    return media == null ? 'empty' : media.cacheKey;
  }

  Future<void> _togglePlayback() async {
    if (_isBusy) {
      return;
    }

    final player = _ensurePlayer();
    if (_isPlaying) {
      await player.pause();
      return;
    }

    setState(() {
      _isBusy = true;
    });

    try {
      await _loadSourceIfNeeded(player);
      if (player.processingState == ProcessingState.completed) {
        await player.seek(Duration.zero);
      }
      await player.play();
    } catch (error, stackTrace) {
      debugPrint('[Voice playback failed] $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play voice message.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) {
      return existing;
    }

    final player = AudioPlayer();
    _player = player;
    _playerStateSubscription = player.playerStateStream.listen((state) {
      if (!mounted) {
        return;
      }
      if (state.processingState == ProcessingState.completed) {
        unawaited(player.pause());
        unawaited(player.seek(Duration.zero));
      }
      setState(() {
        _isPlaying =
            state.playing && state.processingState != ProcessingState.completed;
      });
    });
    return player;
  }

  Future<void> _loadSourceIfNeeded(AudioPlayer player) async {
    final sourceKey = _sourceKey;
    if (_loadedSourceKey == sourceKey) {
      return;
    }

    final pickedMedia = widget.pickedMedia;
    if (pickedMedia != null) {
      await player.setAudioSource(
        _BytesAudioSource(pickedMedia.bytes, pickedMedia.mimeType),
      );
      _loadedSourceKey = sourceKey;
      return;
    }

    final media = widget.media;
    if (media == null) {
      throw StateError('Missing voice media.');
    }

    final localBytes = media.localBytes;
    if (localBytes != null) {
      await player.setAudioSource(
        _BytesAudioSource(localBytes, media.mimeType),
      );
      _loadedSourceKey = sourceKey;
      return;
    }

    final repository = widget.repository;
    if (repository == null) {
      throw StateError('Missing media repository.');
    }

    final signedUrl = await repository.signedMediaUrl(media);
    await player.setUrl(signedUrl);
    _loadedSourceKey = sourceKey;
  }

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: _isPlaying ? 'Pause voice message' : 'Play voice message',
      visualDensity: VisualDensity.compact,
      onPressed: _isBusy ? null : _togglePlayback,
      style: IconButton.styleFrom(
        backgroundColor: widget.foregroundColor.withValues(alpha: 0.12),
        foregroundColor: widget.foregroundColor,
      ),
      icon: _isBusy
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: widget.foregroundColor,
              ),
            )
          : Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
    );
  }
}

// `just_audio` marks byte-backed sources experimental; this keeps local voice
// previews playable before the file exists at a remote URL.
// ignore: experimental_member_use
class _BytesAudioSource extends StreamAudioSource {
  _BytesAudioSource(this.bytes, this.contentType);

  final Uint8List bytes;
  final String contentType;

  @override
  // ignore: experimental_member_use
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final effectiveStart = start ?? 0;
    final effectiveEnd = math.min(end ?? bytes.length, bytes.length);
    final chunk = Uint8List.sublistView(bytes, effectiveStart, effectiveEnd);

    // ignore: experimental_member_use
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: chunk.length,
      offset: effectiveStart,
      contentType: contentType,
      stream: Stream.value(chunk),
    );
  }
}

class _VoiceWaveform extends StatelessWidget {
  const _VoiceWaveform({
    required this.levels,
    required this.height,
    required this.barColor,
    required this.trackColor,
  });

  final List<double> levels;
  final double height;
  final Color barColor;
  final Color trackColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _VoiceWaveformPainter(
          levels: _waveformLevels(levels),
          barColor: barColor,
          trackColor: trackColor,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _VoiceWaveformPainter extends CustomPainter {
  const _VoiceWaveformPainter({
    required this.levels,
    required this.barColor,
    required this.trackColor,
  });

  final List<double> levels;
  final Color barColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    final count = levels.length;
    final gap = size.width < 180 ? 2.0 : 3.0;
    final barWidth = math.max(2.0, (size.width - gap * (count - 1)) / count);
    final radius = Radius.circular(barWidth / 2);
    final centerY = size.height / 2;
    final trackPaint = Paint()..color = trackColor;
    final barPaint = Paint()..color = barColor;

    for (var index = 0; index < count; index += 1) {
      final left = index * (barWidth + gap);
      final level = levels[index].clamp(0.0, 1.0).toDouble();
      final barHeight = math.max(4.0, size.height * (0.22 + level * 0.78));
      final fullRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, 0, barWidth, size.height),
        radius,
      );
      final activeRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, centerY - barHeight / 2, barWidth, barHeight),
        radius,
      );

      canvas.drawRRect(fullRect, trackPaint);
      canvas.drawRRect(activeRect, barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceWaveformPainter oldDelegate) {
    return oldDelegate.levels != levels ||
        oldDelegate.barColor != barColor ||
        oldDelegate.trackColor != trackColor;
  }
}

class _MediaDownloadButton extends StatelessWidget {
  const _MediaDownloadButton({
    required this.keyPrefix,
    required this.message,
    required this.media,
    required this.repository,
  });

  final String keyPrefix;
  final ChatMessage message;
  final ChatMedia media;
  final ChatRepository repository;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      key: Key('$keyPrefix-${message.id}'),
      tooltip: 'Download media',
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.62),
        foregroundColor: Colors.white,
      ),
      onPressed: () => _downloadMediaAttachment(
        context: context,
        repository: repository,
        media: media,
      ),
      icon: const Icon(Icons.download_outlined),
    );
  }
}

class _ChatMediaImage extends StatefulWidget {
  const _ChatMediaImage({
    required this.media,
    required this.repository,
    required this.fit,
  });

  final ChatMedia media;
  final ChatRepository repository;
  final BoxFit fit;

  @override
  State<_ChatMediaImage> createState() => _ChatMediaImageState();
}

class _ChatMediaImageState extends State<_ChatMediaImage> {
  Future<String>? _signedUrl;

  @override
  void initState() {
    super.initState();
    _syncSignedUrl();
  }

  @override
  void didUpdateWidget(covariant _ChatMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.cacheKey != widget.media.cacheKey ||
        oldWidget.repository != widget.repository) {
      _syncSignedUrl();
    }
  }

  void _syncSignedUrl() {
    _signedUrl = widget.media.localBytes == null
        ? widget.repository.signedMediaUrl(widget.media)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final localBytes = widget.media.localBytes;
    if (localBytes != null) {
      return Image.memory(
        localBytes,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
      );
    }

    return FutureBuilder<String>(
      future: _signedUrl,
      builder: (context, snapshot) {
        final signedUrl = snapshot.data;
        if (signedUrl == null) {
          return ColoredBox(
            color: Colors.black.withValues(alpha: 0.06),
            child: const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        return CachedNetworkImage(
          imageUrl: signedUrl,
          cacheKey: widget.media.cacheKey,
          fit: widget.fit,
          fadeInDuration: const Duration(milliseconds: 120),
          placeholder: (context, url) => ColoredBox(
            color: Colors.black.withValues(alpha: 0.06),
            child: const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          errorWidget: (context, url, error) => ColoredBox(
            color: Colors.black.withValues(alpha: 0.08),
            child: const Center(child: Icon(Icons.broken_image_outlined)),
          ),
        );
      },
    );
  }
}

Future<void> _downloadMediaAttachment({
  required BuildContext context,
  required ChatRepository repository,
  required ChatMedia media,
}) async {
  final messenger = ScaffoldMessenger.of(context);

  try {
    final saved = await repository.saveMediaAttachment(media);
    if (!context.mounted || !saved) {
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('Media downloaded.')));
  } on MediaAttachmentException catch (error, stackTrace) {
    debugPrint('[Media download failed] ${error.toString()}\n$stackTrace');
    if (!context.mounted) {
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } catch (error, stackTrace) {
    debugPrint('[Media download failed] $error\n$stackTrace');
    if (!context.mounted) {
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not download media.')),
    );
  }
}

class _MediaViewerPage extends StatelessWidget {
  const _MediaViewerPage({
    required this.message,
    required this.media,
    required this.repository,
  });

  final ChatMessage message;
  final ChatMedia media;
  final ChatRepository repository;

  @override
  Widget build(BuildContext context) {
    final caption = message.body.trim();

    return Scaffold(
      key: Key('media-viewer-${message.id}'),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Hero(
                  tag: _mediaHeroTag(message),
                  child: SizedBox.expand(
                    child: _ChatMediaImage(
                      media: media,
                      repository: repository,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MediaDownloadButton(
                    keyPrefix: 'media-viewer-download',
                    message: message,
                    media: media,
                    repository: repository,
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (caption.isNotEmpty)
              Positioned(
                left: 18,
                right: 18,
                bottom: 18,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.58),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      caption,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReceiptIcon extends StatelessWidget {
  const _ReceiptIcon({
    required this.message,
    required this.fallbackColor,
    required this.onRetry,
  });

  final ChatMessage message;
  final Color fallbackColor;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (message.sendState == ChatMessageSendState.failed) {
      return IconButton(
        tooltip: message.sendError == null || message.sendError!.isEmpty
            ? 'Retry message'
            : 'Retry message: ${message.sendError}',
        key: const Key('message-status-failed'),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 22, height: 22),
        onPressed: () => unawaited(onRetry()),
        icon: Icon(Icons.error_outline, size: 15, color: fallbackColor),
      );
    }

    if (message.sendState == ChatMessageSendState.sending) {
      return Icon(
        Icons.sync,
        key: const Key('message-status-sending'),
        size: 15,
        color: fallbackColor,
      );
    }

    if (message.sendState == ChatMessageSendState.pending) {
      return Icon(
        Icons.schedule,
        key: const Key('message-status-pending'),
        size: 15,
        color: fallbackColor,
      );
    }

    if (message.isRead) {
      return const Icon(
        Icons.done_all,
        key: Key('message-status-read'),
        size: 15,
        color: Color(0xFF53BDEB),
      );
    }

    if (message.isDelivered) {
      return Icon(
        Icons.done_all,
        key: const Key('message-status-delivered'),
        size: 15,
        color: fallbackColor,
      );
    }

    return Icon(
      Icons.done,
      key: const Key('message-status-sent'),
      size: 15,
      color: fallbackColor,
    );
  }
}

class _MessageComposer extends StatelessWidget {
  const _MessageComposer({
    required this.controller,
    required this.isSending,
    required this.isRecordingVoice,
    required this.voiceRecordingElapsed,
    required this.voiceRecordingLevels,
    required this.stagedAttachment,
    required this.replyingTo,
    required this.editingMessage,
    required this.onCancelComposerAction,
    required this.onAttachMedia,
    required this.onToggleVoiceRecording,
    required this.onRemoveAttachment,
    required this.onRetryAttachment,
    required this.onChanged,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool isSending;
  final bool isRecordingVoice;
  final Duration voiceRecordingElapsed;
  final List<double> voiceRecordingLevels;
  final _StagedMediaAttachment? stagedAttachment;
  final ChatMessage? replyingTo;
  final ChatMessage? editingMessage;
  final VoidCallback onCancelComposerAction;
  final ValueChanged<ChatMediaSource> onAttachMedia;
  final VoidCallback onToggleVoiceRecording;
  final Future<void> Function() onRemoveAttachment;
  final VoidCallback onRetryAttachment;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingTo != null || editingMessage != null) ...[
              _ComposerActionCard(
                message: editingMessage ?? replyingTo!,
                isEditing: editingMessage != null,
                onCancel: onCancelComposerAction,
              ),
              const SizedBox(height: 10),
            ],
            if (stagedAttachment != null) ...[
              _StagedAttachmentCard(
                attachment: stagedAttachment!,
                onRemove: onRemoveAttachment,
                onRetry: onRetryAttachment,
              ),
              const SizedBox(height: 10),
            ],
            if (isRecordingVoice) ...[
              _VoiceRecordingCard(
                elapsed: voiceRecordingElapsed,
                levels: voiceRecordingLevels,
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                PopupMenuButton<ChatMediaSource>(
                  tooltip: 'Attach',
                  enabled: !isSending && !isRecordingVoice,
                  icon: const Icon(Icons.add),
                  onSelected: onAttachMedia,
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: ChatMediaSource.gallery,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.photo_library_outlined),
                        title: Text('Photo or GIF'),
                      ),
                    ),
                    PopupMenuItem(
                      value: ChatMediaSource.giphy,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.gif_box_outlined),
                        title: Text('GIF'),
                      ),
                    ),
                    PopupMenuItem(
                      value: ChatMediaSource.camera,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.photo_camera_outlined),
                        title: Text('Camera'),
                      ),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: isRecordingVoice
                      ? 'Stop voice message'
                      : 'Record voice message',
                  onPressed: isSending ? null : onToggleVoiceRecording,
                  icon: Icon(
                    isRecordingVoice ? Icons.stop : Icons.mic_none_outlined,
                  ),
                  color: isRecordingVoice ? theme.colorScheme.error : null,
                ),
                Expanded(
                  child: TextField(
                    key: const Key('message-composer'),
                    controller: controller,
                    enabled: !isRecordingVoice,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    onChanged: onChanged,
                    decoration: const InputDecoration(hintText: 'Message'),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, _, child) {
                    final uploadReady =
                        stagedAttachment == null || stagedAttachment!.canSend;
                    final failed =
                        stagedAttachment?.status ==
                        _AttachmentUploadState.failed;
                    return FilledButton(
                      onPressed:
                          isSending ||
                              isRecordingVoice ||
                              !uploadReady ||
                              failed
                          ? null
                          : onSend,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: EdgeInsets.zero,
                      ),
                      child: isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerActionCard extends StatelessWidget {
  const _ComposerActionCard({
    required this.message,
    required this.isEditing,
    required this.onCancel,
  });

  final ChatMessage message;
  final bool isEditing;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isEditing
                      ? 'Editing message'
                      : 'Replying to ${message.senderName}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  message.actionPreview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cancel',
            onPressed: onCancel,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _StagedAttachmentCard extends StatelessWidget {
  const _StagedAttachmentCard({
    required this.attachment,
    required this.onRemove,
    required this.onRetry,
  });

  final _StagedMediaAttachment attachment;
  final Future<void> Function() onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = attachment.uploadedMedia?.media;
    final pickedMedia = attachment.pickedMedia;
    final isVoice = pickedMedia.isVoice;
    final progress = attachment.progress.clamp(0.0, 1.0);
    final isFailed = attachment.status == _AttachmentUploadState.failed;
    final label = isFailed
        ? attachment.errorMessage ?? 'Upload failed.'
        : attachment.isUploading
        ? 'Uploading ${(progress * 100).round()}%'
        : 'Ready';

    return Container(
      key: const Key('staged-media-attachment'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.64,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 58,
              height: 58,
              child: isVoice
                  ? ColoredBox(
                      color: theme.colorScheme.primary.withValues(alpha: 0.10),
                      child: Center(
                        child: _VoicePlaybackButton(
                          repository: null,
                          media: media,
                          pickedMedia: pickedMedia,
                          foregroundColor: theme.colorScheme.primary,
                        ),
                      ),
                    )
                  : media == null
                  ? Image.memory(
                      pickedMedia.bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    )
                  : Image.memory(
                      media.localBytes ?? pickedMedia.bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pickedMedia.originalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  isVoice
                      ? '${_formatDuration(pickedMedia.duration ?? Duration.zero)} · ${_formatBytes(pickedMedia.sizeBytes)} · $label'
                      : '${_formatBytes(pickedMedia.sizeBytes)} · $label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: isFailed
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isVoice) ...[
                  const SizedBox(height: 7),
                  _VoiceWaveform(
                    levels: pickedMedia.waveform,
                    height: 28,
                    barColor: theme.colorScheme.primary,
                    trackColor: theme.colorScheme.primary.withValues(
                      alpha: 0.16,
                    ),
                  ),
                ],
                if (attachment.isUploading) ...[
                  const SizedBox(height: 7),
                  LinearProgressIndicator(
                    value: progress == 0 ? null : progress,
                  ),
                ],
                if (isFailed && attachment.errorDetails != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    attachment.errorDetails!,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (isFailed)
            IconButton(
              tooltip: 'Retry upload',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: 'Remove attachment',
            onPressed: onRemove,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.thread, required this.size});

  final ChatThread thread;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: thread.accentColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            thread.avatarLabel,
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.34,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (thread.isOnline || thread.isTyping)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: const Color(0xFF17A36B),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

String _formatTime(DateTime time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatDuration(Duration duration) {
  final totalSeconds = math.max(0, duration.inSeconds);
  final minutes = totalSeconds ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

double _voiceLevelFromDb(double db) {
  if (!db.isFinite) {
    return 0.08;
  }
  return ((db + 45) / 45).clamp(0.06, 1.0).toDouble();
}

List<double> _compactVoiceLevels(List<double> levels, {int target = 32}) {
  if (levels.isEmpty) {
    return _fallbackWaveformLevels(target);
  }

  if (levels.length <= target) {
    return List<double>.unmodifiable(
      levels.map((level) => level.clamp(0.0, 1.0).toDouble()),
    );
  }

  final compacted = <double>[];
  for (var index = 0; index < target; index += 1) {
    final start = (index * levels.length / target).floor();
    final end = math.max(
      start + 1,
      ((index + 1) * levels.length / target).ceil(),
    );
    final slice = levels.sublist(start, math.min(end, levels.length));
    final average = slice.reduce((sum, level) => sum + level) / slice.length;
    compacted.add(average.clamp(0.0, 1.0).toDouble());
  }
  return List<double>.unmodifiable(compacted);
}

List<double> _waveformLevels(List<double> levels) {
  if (levels.isEmpty) {
    return _fallbackWaveformLevels(32);
  }
  return _compactVoiceLevels(
    levels,
    target: math.min(40, math.max(16, levels.length)),
  );
}

List<double> _fallbackWaveformLevels(int count) {
  return List<double>.generate(count, (index) {
    final wave = math.sin((index + 1) * 1.7).abs();
    return 0.22 + wave * 0.62;
  }, growable: false);
}

bool get _shouldUseFileVoiceRecording {
  if (kIsWeb) {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    _ => false,
  };
}

Uint8List _wavBytesFromPcm16({
  required Uint8List pcmBytes,
  required int sampleRate,
  required int numChannels,
}) {
  const bitsPerSample = 16;
  const bytesPerSample = bitsPerSample ~/ 8;
  final byteRate = sampleRate * numChannels * bytesPerSample;
  final blockAlign = numChannels * bytesPerSample;
  final output = Uint8List(44 + pcmBytes.length);
  final data = ByteData.sublistView(output);

  _writeAscii(output, 0, 'RIFF');
  data.setUint32(4, 36 + pcmBytes.length, Endian.little);
  _writeAscii(output, 8, 'WAVE');
  _writeAscii(output, 12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, numChannels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, byteRate, Endian.little);
  data.setUint16(32, blockAlign, Endian.little);
  data.setUint16(34, bitsPerSample, Endian.little);
  _writeAscii(output, 36, 'data');
  data.setUint32(40, pcmBytes.length, Endian.little);
  output.setRange(44, output.length, pcmBytes);

  return output;
}

void _writeAscii(Uint8List bytes, int offset, String value) {
  for (var index = 0; index < value.length; index += 1) {
    bytes[offset + index] = value.codeUnitAt(index);
  }
}

String _shortError(Object error) {
  final message = error.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
  if (message.isEmpty) {
    return error.runtimeType.toString();
  }
  if (message.length <= 160) {
    return message;
  }
  return '${message.substring(0, 160)}...';
}

String _firstStackFrame(StackTrace stackTrace) {
  final lines = stackTrace.toString().trim().split('\n');
  if (lines.isEmpty || lines.first.trim().isEmpty) {
    return 'unavailable';
  }
  return lines.first.trim();
}

double _previewAspectRatio(ChatMedia media) {
  final aspectRatio = media.aspectRatio;
  if (aspectRatio == null) {
    return 1;
  }
  if (aspectRatio > 1.18) {
    return 4 / 3;
  }
  if (aspectRatio < 0.84) {
    return 3 / 4;
  }
  return 1;
}

String _mediaHeroTag(ChatMessage message) {
  return 'message-media-${message.id}';
}
