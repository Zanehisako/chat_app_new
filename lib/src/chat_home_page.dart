import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:camera/camera.dart' as camera;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:realtime_calls/realtime_calls.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_signaling.dart';
import 'group_call_signaling.dart';
import 'chat_models.dart';
import 'connectivity_service.dart';
import 'chat_repository.dart';
import 'e2ee_draft_protector.dart';
import 'notification_service.dart';
import 'offline_outbox_service.dart';
import 'outbox_database.dart';
import 'profile_page.dart';
import 'motion/chat_motion.dart';
import 'motion/chat_motion_routes.dart';
import 'motion/chat_motion_widgets.dart';
import 'motion/chat_message_overlay.dart';
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

enum _ThreadStatusFilter { all, unread, sent, delivered, read }

extension on _ThreadStatusFilter {
  String get label => switch (this) {
    _ThreadStatusFilter.all => 'All',
    _ThreadStatusFilter.unread => 'Unread',
    _ThreadStatusFilter.sent => 'Sent',
    _ThreadStatusFilter.delivered => 'Delivered',
    _ThreadStatusFilter.read => 'Read',
  };
}

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

class _MessageInsertionEvent {
  const _MessageInsertionEvent({
    required this.messageId,
    required this.threadId,
    required this.isMine,
  });

  final String messageId;
  final String threadId;
  final bool isMine;
}

const _callOverlayUnchanged = Object();

class _CallOverlayState {
  const _CallOverlayState({
    this.incomingCallInvite,
    this.callSnapshot,
    this.incomingGroupCallInvite,
    this.groupCallSnapshot,
  });

  final CallInvite? incomingCallInvite;
  final CallSnapshot? callSnapshot;
  final GroupCallInvite? incomingGroupCallInvite;
  final GroupCallSnapshot? groupCallSnapshot;

  bool get hasActiveOverlay =>
      incomingCallInvite != null ||
      callSnapshot != null ||
      incomingGroupCallInvite != null ||
      groupCallSnapshot != null;

  _CallOverlayState copyWith({
    Object? incomingCallInvite = _callOverlayUnchanged,
    Object? callSnapshot = _callOverlayUnchanged,
    Object? incomingGroupCallInvite = _callOverlayUnchanged,
    Object? groupCallSnapshot = _callOverlayUnchanged,
  }) {
    return _CallOverlayState(
      incomingCallInvite: identical(incomingCallInvite, _callOverlayUnchanged)
          ? this.incomingCallInvite
          : incomingCallInvite as CallInvite?,
      callSnapshot: identical(callSnapshot, _callOverlayUnchanged)
          ? this.callSnapshot
          : callSnapshot as CallSnapshot?,
      incomingGroupCallInvite:
          identical(incomingGroupCallInvite, _callOverlayUnchanged)
          ? this.incomingGroupCallInvite
          : incomingGroupCallInvite as GroupCallInvite?,
      groupCallSnapshot: identical(groupCallSnapshot, _callOverlayUnchanged)
          ? this.groupCallSnapshot
          : groupCallSnapshot as GroupCallSnapshot?,
    );
  }
}

class _VoiceRecordingVisualController extends ChangeNotifier {
  final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);
  List<double> _levels = const [];

  List<double> get levels => _levels;

  void reset() {
    _levels = List<double>.filled(24, 0.08);
    elapsed.value = Duration.zero;
    notifyListeners();
  }

  void addLevel(double level) {
    final next = [..._levels, level];
    if (next.length > 48) {
      next.removeRange(0, next.length - 48);
    }
    _levels = List<double>.unmodifiable(next);
    notifyListeners();
  }

  void updateElapsed(Duration value) {
    elapsed.value = value;
  }

  void clear() {
    _levels = const [];
    elapsed.value = Duration.zero;
    notifyListeners();
  }

  @override
  void dispose() {
    elapsed.dispose();
    super.dispose();
  }
}

class _ChatHomePageState extends State<ChatHomePage>
    with WidgetsBindingObserver {
  StreamSubscription<List<ChatThread>>? _threadsSubscription;
  List<ChatThread> _remoteThreads = const [];
  ChatThread? _selectedThread;
  final _messageController = TextEditingController();
  final _messageInsertionEvents = ValueNotifier<_MessageInsertionEvent?>(null);
  final AudioRecorder _voiceRecorder = AudioRecorder();
  final List<ChatThread> _startedThreads = [];
  final List<ChatMessage> _localMessages = [];
  final List<int> _voiceBytes = [];
  final _voiceVisualController = _VoiceRecordingVisualController();
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
  Future<bool>? _e2eeSetup;
  String? _e2eeSetupOwnerId;
  String? _e2eeReadyOwnerId;
  int _e2eeGeneration = 0;
  bool _e2eeDialogShowing = false;
  Route<dynamic>? _e2eeDialogRoute;
  NavigatorState? _e2eeDialogNavigator;
  StreamSubscription<List<OutboxMessage>>? _outboxSubscription;
  StreamSubscription<ChatMessage>? _incomingMessageSubscription;
  StreamSubscription<NotificationRoute>? _notificationRouteSubscription;
  StreamSubscription<Map<String, UserPresence>>? _presenceSubscription;
  StreamSubscription<CallInvite>? _incomingCallSubscription;
  StreamSubscription<CallSnapshot?>? _callSnapshotSubscription;
  StreamSubscription<GroupCallInvite>? _groupCallInviteSubscription;
  StreamSubscription<GroupCallSnapshot?>? _groupCallSnapshotSubscription;
  StreamSubscription<Uint8List>? _voiceDataSubscription;
  StreamSubscription<Amplitude>? _voiceAmplitudeSubscription;
  Completer<void>? _voiceStreamDone;
  CallClient? _callClient;
  final _callOverlay = ValueNotifier(const _CallOverlayState());
  GroupCallClient? _groupCallClient;
  SupabaseGroupCallGateway? _groupCallGateway;
  final Map<String, GroupCallSessionSummary> _activeGroupCalls = {};
  Timer? _groupCallRefreshTimer;
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
  bool _isSending = false;
  bool _isRecordingVoice = false;
  bool _isVoiceRecordingFileBacked = false;
  bool _isCompactConversationOpen = false;
  bool _isTearingDown = false;
  static const _maxKnownIncomingMessageIds = 256;

  CallInvite? get _incomingCallInvite => _callOverlay.value.incomingCallInvite;
  CallSnapshot? get _callSnapshot => _callOverlay.value.callSnapshot;
  GroupCallInvite? get _incomingGroupCallInvite =>
      _callOverlay.value.incomingGroupCallInvite;
  GroupCallSnapshot? get _groupCallSnapshot =>
      _callOverlay.value.groupCallSnapshot;

  void _updateCallOverlay({
    Object? incomingCallInvite = _callOverlayUnchanged,
    Object? callSnapshot = _callOverlayUnchanged,
    Object? incomingGroupCallInvite = _callOverlayUnchanged,
    Object? groupCallSnapshot = _callOverlayUnchanged,
  }) {
    if (_isTearingDown) return;
    _callOverlay.value = _callOverlay.value.copyWith(
      incomingCallInvite: incomingCallInvite,
      callSnapshot: callSnapshot,
      incomingGroupCallInvite: incomingGroupCallInvite,
      groupCallSnapshot: groupCallSnapshot,
    );
  }

  @override
  void initState() {
    super.initState();
    _outboxDatabase = widget.outboxDatabase;
    _ownsOutboxDatabase = widget.outboxDatabase == null;
    WidgetsBinding.instance.addObserver(this);
    _bindThreadsStream(
      widget.repository.watchThreads(),
      initialData: widget.repository.isConnected
          ? const []
          : widget.repository.threads,
      notify: false,
    );
    unawaited(_acknowledgePendingMessagesDelivered());
    _subscribePresence();
    _configureCalls();
    unawaited(_initializeE2eeAndOutbox());
    _configureNotifications();
  }

  @override
  void didUpdateWidget(covariant ChatHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      _invalidateE2eeOnboarding(dismissDialog: true);
      unawaited(_cancelVoiceRecording());
      unawaited(_removeStagedAttachment());
      unawaited(oldWidget.repository.disposeRealtime());
      _presenceSubscription?.cancel();
      unawaited(_disposeCallClient());
      _cancelTypingSubscriptions();
      _presenceByUser.clear();
      _typingByConversation.clear();
      _bindThreadsStream(
        widget.repository.watchThreads(),
        initialData: widget.repository.isConnected
            ? const []
            : widget.repository.threads,
        notify: false,
      );
      _outboxMessages = [];
      _selectedThread = null;
      _startedThreads.clear();
      _profileOverridesByUser.clear();
      _profileRefreshesInFlight.clear();
      _knownIncomingMessageIds.clear();
      _knownIncomingMessageOrder.clear();
      _activeConversationId = null;
      unawaited(_acknowledgePendingMessagesDelivered());
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
    _invalidateE2eeOnboarding(dismissDialog: true);
    WidgetsBinding.instance.removeObserver(this);
    _activeUploadToken = null;
    final stagedMedia = _stagedAttachment?.uploadedMedia?.media;
    if (stagedMedia != null) {
      unawaited(widget.repository.deleteStagedMedia(stagedMedia));
    }
    unawaited(
      _disposeVoiceRecorder().whenComplete(_voiceVisualController.dispose),
    );
    _typingStopTimer?.cancel();
    _voiceRecordingTimer?.cancel();
    _clearEndedCallTimer?.cancel();
    _presenceSubscription?.cancel();
    _threadsSubscription?.cancel();
    _outboxGeneration += 1;
    final outboxDatabase = _outboxDatabase;
    _outboxDatabase = null;
    final outboxShutdown = _disposeOfflineOutbox();
    if (outboxDatabase != null && _ownsOutboxDatabase) {
      unawaited(outboxShutdown.whenComplete(outboxDatabase.close));
    }
    _disposeNotifications();
    unawaited(_disposeCallClient().whenComplete(_callOverlay.dispose));
    _cancelTypingSubscriptions();
    unawaited(widget.repository.disposeRealtime());
    _messageController.dispose();
    _messageInsertionEvents.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_flushOutbox(ignoreBackoff: true));
      unawaited(_acknowledgePendingMessagesDelivered());
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

  void _bindThreadsStream(
    Stream<List<ChatThread>> stream, {
    required List<ChatThread> initialData,
    bool notify = true,
  }) {
    unawaited(_threadsSubscription?.cancel());
    _remoteThreads = initialData;
    _threadsSubscription = stream.listen(
      _handleThreadsChanged,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[Thread stream] $error\n$stackTrace');
      },
    );

    if (notify && mounted) {
      setState(() {});
    }
    scheduleMicrotask(_handleThreadProjectionChanged);
  }

  void _handleThreadsChanged(List<ChatThread> threads) {
    if (!mounted || _isTearingDown) return;
    setState(() {
      _remoteThreads = threads;
    });
    _handleThreadProjectionChanged();
  }

  void _handleThreadProjectionChanged() {
    if (!mounted || _isTearingDown) return;
    final threads = _availableThreads;
    _scheduleNotificationRouteResolution(threads);
    _syncTypingSubscriptions(threads);
    final isWide = (MediaQuery.maybeOf(context)?.size.width ?? 0) >= 840;
    if (isWide || _isCompactConversationOpen) {
      _scheduleConversationEntryRefresh(_selectedThreadFor(threads));
    }
  }

  Future<void> _acknowledgePendingMessagesDelivered() async {
    try {
      await widget.repository.markPendingMessagesDelivered();
    } catch (error, stackTrace) {
      debugPrint(
        '[Receipts] Could not acknowledge pending deliveries: '
        '$error\n$stackTrace',
      );
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
    final groupGateway = SupabaseGroupCallGateway(client: client);
    final groupClient = GroupCallClient(gateway: groupGateway);
    _groupCallGateway = groupGateway;
    _groupCallClient = groupClient;
    _groupCallInviteSubscription = groupGateway.watchIncomingInvites().listen(
      (invite) {
        if (!mounted ||
            _groupCallSnapshot != null ||
            _callSnapshot != null ||
            _incomingCallInvite != null) {
          return;
        }
        _updateCallOverlay(incomingGroupCallInvite: invite);
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[Group call invite watch] $error\n$stackTrace');
      },
    );
    _groupCallSnapshotSubscription = groupClient.snapshots.listen((snapshot) {
      if (!mounted) return;
      _updateCallOverlay(
        groupCallSnapshot: snapshot,
        incomingGroupCallInvite: snapshot == null
            ? _callOverlayUnchanged
            : null,
      );
    });
    _groupCallRefreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshActiveGroupCalls()),
    );
    _incomingCallSubscription = callClient.watchIncomingInvites().listen(
      (invite) {
        if (!mounted ||
            _callSnapshot != null ||
            _groupCallSnapshot != null ||
            _incomingGroupCallInvite != null) {
          return;
        }
        debugPrint(
          '[Incoming call invite] call=${invite.id} from=${invite.callerName}',
        );
        _updateCallOverlay(incomingCallInvite: invite);
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
      _updateCallOverlay(
        callSnapshot: snapshot,
        incomingCallInvite: snapshot == null ? _callOverlayUnchanged : null,
      );

      if (snapshot?.isTerminal ?? false) {
        _clearEndedCallTimer?.cancel();
        _clearEndedCallTimer = Timer(const Duration(milliseconds: 1400), () {
          if (!mounted || _callSnapshot?.callId != snapshot?.callId) {
            return;
          }
          _updateCallOverlay(callSnapshot: null);
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
    final repository = widget.repository;
    final generation = _e2eeGeneration;
    final draftProtector = await _loadE2eeDraftProtector(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
    );
    if (!_isCurrentE2eeSetup(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
    )) {
      return null;
    }

    final outbox = OfflineOutboxService(
      scope: OutboxScope(backendOrigin: backendOrigin, userId: ownerId),
      database: _outboxDatabase ??= OutboxDatabase(),
      draftProtector: draftProtector,
    );
    final connectivity = ConnectivityService();
    _outboxService = outbox;
    _connectivityService = connectivity;
    _outboxSubscription = outbox.stream.listen((_) {
      unawaited(_refreshOutboxMessages(outbox));
    });

    await outbox.start(repository);
    if (!mounted || _isTearingDown || _outboxService != outbox) {
      await connectivity.dispose();
      await outbox.dispose();
      return null;
    }
    await _refreshOutboxMessages(outbox);
    await connectivity.start(() => _flushOutbox(ignoreBackoff: true));
    return outbox;
  }

  Future<void> _initializeE2eeAndOutbox() async {
    await _ensureOfflineOutbox();
  }

  Future<E2eeDraftProtector?> _loadE2eeDraftProtector({
    required ChatRepository repository,
    required String ownerId,
    required String backendOrigin,
    required int generation,
  }) async {
    // Local preview/test data deliberately stays outside the authenticated
    // E2EE queue. A connected account must complete recovery onboarding before
    // it is allowed to create a durable outbox.
    if (!repository.isConnected) {
      return null;
    }

    while (_isCurrentE2eeSetup(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
    )) {
      final ready = await _ensureE2eeReadyForOutbox(
        repository: repository,
        ownerId: ownerId,
        backendOrigin: backendOrigin,
        generation: generation,
      );
      if (!ready) {
        return null;
      }

      try {
        return await repository.e2eeDraftProtector();
      } catch (_) {
        if (!await _showE2eeRetryDialog(
          title: 'Encryption setup needs attention',
          message:
              'The secure message queue is not ready yet. Check your connection and try again.',
          repository: repository,
          ownerId: ownerId,
          backendOrigin: backendOrigin,
          generation: generation,
        )) {
          return null;
        }
      }
    }
    return null;
  }

  Future<bool> _ensureE2eeReadyForOutbox({
    required ChatRepository repository,
    required String ownerId,
    required String backendOrigin,
    required int generation,
  }) async {
    if (!repository.isConnected) {
      return true;
    }
    if (_e2eeReadyOwnerId == ownerId) {
      return true;
    }

    final activeSetup = _e2eeSetup;
    if (activeSetup != null && _e2eeSetupOwnerId == ownerId) {
      return activeSetup;
    }

    if (activeSetup != null) {
      _invalidateE2eeOnboarding(dismissDialog: true);
      generation = _e2eeGeneration;
    }
    if (!_isCurrentE2eeSetup(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
    )) {
      return false;
    }

    final setup = _completeE2eeOnboarding(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
    );
    _e2eeSetup = setup;
    _e2eeSetupOwnerId = ownerId;
    try {
      return await setup;
    } finally {
      if (identical(_e2eeSetup, setup)) {
        _e2eeSetup = null;
        _e2eeSetupOwnerId = null;
      }
    }
  }

  Future<bool> _completeE2eeOnboarding({
    required ChatRepository repository,
    required String ownerId,
    required String backendOrigin,
    required int generation,
  }) async {
    while (_isCurrentE2eeSetup(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
    )) {
      try {
        final state = await repository.e2eeReadyState();
        if (!_isCurrentE2eeSetup(
          repository: repository,
          ownerId: ownerId,
          backendOrigin: backendOrigin,
          generation: generation,
        )) {
          return false;
        }

        if (state.requiresRecoveryPhraseRestore) {
          final restored = await _showRecoveryPhraseRestoreDialog(
            repository: repository,
            ownerId: ownerId,
            backendOrigin: backendOrigin,
            generation: generation,
          );
          if (!restored) {
            return false;
          }
          continue;
        }

        if (state.requiresRecoveryPhraseConfirmation) {
          final phrase = _normalizeRecoveryPhrase(
            await repository.recoveryPhrase(),
          );
          if (!_isCurrentE2eeSetup(
            repository: repository,
            ownerId: ownerId,
            backendOrigin: backendOrigin,
            generation: generation,
          )) {
            return false;
          }
          if (phrase == null) {
            await _showE2eeRetryDialog(
              title: 'Recovery phrase unavailable',
              message:
                  'Your recovery phrase could not be loaded securely. Try again before sending messages.',
              repository: repository,
              ownerId: ownerId,
              backendOrigin: backendOrigin,
              generation: generation,
            );
            continue;
          }

          final confirmed = await _showRecoveryPhraseConfirmationDialog(
            phrase: phrase,
            repository: repository,
            ownerId: ownerId,
            backendOrigin: backendOrigin,
            generation: generation,
          );
          if (!confirmed) {
            return false;
          }
          continue;
        }

        if (!state.isReadyForSending) {
          throw StateError('E2EE identity is incomplete.');
        }
        _e2eeReadyOwnerId = ownerId;
        return true;
      } catch (_) {
        final retry = await _showE2eeRetryDialog(
          title: 'Encryption setup needs attention',
          message:
              'Encrypted messaging could not be set up. Check your connection and try again.',
          repository: repository,
          ownerId: ownerId,
          backendOrigin: backendOrigin,
          generation: generation,
        );
        if (!retry) {
          return false;
        }
      }
    }
    return false;
  }

  Future<bool> _showRecoveryPhraseConfirmationDialog({
    required String phrase,
    required ChatRepository repository,
    required String ownerId,
    required String backendOrigin,
    required int generation,
  }) async {
    final result = await _showE2eeDialog<bool>(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
      builder: (context) => _E2eeRecoveryPhraseConfirmationDialog(
        phrase: phrase,
        onConfirm: (enteredPhrase) async {
          if (!_isCurrentE2eeSetup(
            repository: repository,
            ownerId: ownerId,
            backendOrigin: backendOrigin,
            generation: generation,
          )) {
            throw StateError('The signed-in account changed.');
          }
          await repository.confirmRecoveryPhrase(enteredPhrase);
        },
      ),
    );
    return result == true;
  }

  Future<bool> _showRecoveryPhraseRestoreDialog({
    required ChatRepository repository,
    required String ownerId,
    required String backendOrigin,
    required int generation,
  }) async {
    final result = await _showE2eeDialog<bool>(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
      builder: (context) => _E2eeRecoveryPhraseRestoreDialog(
        onRestore: (phrase) async {
          if (!_isCurrentE2eeSetup(
            repository: repository,
            ownerId: ownerId,
            backendOrigin: backendOrigin,
            generation: generation,
          )) {
            throw StateError('The signed-in account changed.');
          }
          await repository.restoreE2eeRecoveryPhrase(phrase);
        },
      ),
    );
    return result == true;
  }

  Future<bool> _showE2eeRetryDialog({
    required String title,
    required String message,
    required ChatRepository repository,
    required String ownerId,
    required String backendOrigin,
    required int generation,
  }) async {
    final result = await _showE2eeDialog<bool>(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
      builder: (context) => _E2eeRetryDialog(title: title, message: message),
    );
    return result == true;
  }

  Future<T?> _showE2eeDialog<T>({
    required ChatRepository repository,
    required String ownerId,
    required String backendOrigin,
    required int generation,
    required WidgetBuilder builder,
  }) async {
    if (!_isCurrentE2eeSetup(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
    )) {
      return null;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!_isCurrentE2eeSetup(
      repository: repository,
      ownerId: ownerId,
      backendOrigin: backendOrigin,
      generation: generation,
    )) {
      return null;
    }
    if (!mounted) {
      return null;
    }

    final route = ChatDialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: false,
    );
    _e2eeDialogShowing = true;
    _e2eeDialogRoute = route;
    final navigator = Navigator.of(context, rootNavigator: true);
    _e2eeDialogNavigator = navigator;
    try {
      return await navigator.push<T>(route);
    } finally {
      if (identical(_e2eeDialogRoute, route)) {
        _e2eeDialogRoute = null;
        _e2eeDialogNavigator = null;
        _e2eeDialogShowing = false;
      }
    }
  }

  bool _isCurrentE2eeSetup({
    required ChatRepository repository,
    required String ownerId,
    required String backendOrigin,
    required int generation,
  }) {
    return mounted &&
        !_isTearingDown &&
        identical(widget.repository, repository) &&
        _e2eeGeneration == generation &&
        widget.repository.outboxUserId == ownerId &&
        widget.repository.outboxBackendOrigin == backendOrigin;
  }

  void _invalidateE2eeOnboarding({required bool dismissDialog}) {
    _e2eeGeneration += 1;
    _e2eeSetup = null;
    _e2eeSetupOwnerId = null;
    _e2eeReadyOwnerId = null;
    if (!dismissDialog || !_e2eeDialogShowing || !mounted) {
      return;
    }
    final route = _e2eeDialogRoute;
    final navigator = _e2eeDialogNavigator;
    if (route != null && navigator != null) {
      _e2eeDialogRoute = null;
      _e2eeDialogNavigator = null;
      _e2eeDialogShowing = false;
      navigator.removeRoute(route);
    }
  }

  String? _normalizeRecoveryPhrase(String? phrase) {
    final words = phrase
        ?.trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (words == null || words.length != 24) {
      return null;
    }
    return words.join(' ');
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
    ChatThread? thread;
    for (final candidate in _availableThreads) {
      if (candidate.id == message.threadId) {
        thread = candidate;
        break;
      }
    }
    final isGroup = thread?.isGroup ?? false;
    unawaited(
      NotificationService.instance.showAppRunningMessage(
        title: isGroup ? thread!.title : message.senderName,
        body: isGroup
            ? '${message.senderName}: ${_notificationPreview(message)}'
            : _notificationPreview(message),
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
    if (route.kind == 'group_call') {
      unawaited(_refreshActiveGroupCalls());
    }
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
      _handleThreadProjectionChanged();
    });
  }

  Future<void> _disposeCallClient() async {
    _clearEndedCallTimer?.cancel();
    final incomingSubscription = _incomingCallSubscription;
    final snapshotSubscription = _callSnapshotSubscription;
    final callClient = _callClient;
    final groupInviteSubscription = _groupCallInviteSubscription;
    final groupSnapshotSubscription = _groupCallSnapshotSubscription;
    final groupClient = _groupCallClient;
    _incomingCallSubscription = null;
    _callSnapshotSubscription = null;
    _callClient = null;
    _groupCallInviteSubscription = null;
    _groupCallSnapshotSubscription = null;
    _groupCallClient = null;
    _groupCallGateway = null;
    _updateCallOverlay(
      incomingCallInvite: null,
      callSnapshot: null,
      incomingGroupCallInvite: null,
      groupCallSnapshot: null,
    );
    _groupCallRefreshTimer?.cancel();
    _groupCallRefreshTimer = null;
    await incomingSubscription?.cancel();
    await snapshotSubscription?.cancel();
    await groupInviteSubscription?.cancel();
    await groupSnapshotSubscription?.cancel();
    await callClient?.dispose();
    await groupClient?.dispose();
  }

  Future<void> _refreshActiveGroupCalls() async {
    final gateway = _groupCallGateway;
    if (gateway == null || !mounted) return;
    final groupThreads = _availableThreads.where((thread) => thread.isGroup);
    final next = <String, GroupCallSessionSummary>{};
    for (final thread in groupThreads) {
      try {
        final summary = await gateway.activeCallForConversation(thread.id);
        if (summary != null) next[thread.id] = summary;
      } catch (error) {
        debugPrint('[Group call refresh] $error');
      }
    }
    if (!mounted) return;
    setState(() {
      _activeGroupCalls
        ..clear()
        ..addAll(next);
    });
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
      final isOnline = profiledThread.isGroup
          ? false
          : presence?.isOnline ?? profiledThread.isOnline;
      final lastSeenAt = presence?.lastSeenAt ?? profiledThread.peerLastSeenAt;
      final activityLabel = isTyping
          ? profiledThread.isGroup &&
                    (typing?.displayName.trim().isNotEmpty ?? false)
                ? '${typing!.displayName} is typing...'
                : 'Typing...'
          : profiledThread.isGroup
          ? '${profiledThread.memberCount} ${profiledThread.memberCount == 1 ? 'member' : 'members'}'
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

  List<ChatThread> get _availableThreads =>
      _threadsWithActivity(_mergeThreads(_remoteThreads));

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
    final threads = _availableThreads;
    final selectedThread = _selectedThreadFor(threads);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 840;
        return PopScope(
          canPop: isWide || !_isCompactConversationOpen,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && !isWide && _isCompactConversationOpen) {
              _showCompactInbox();
            }
          },
          child: Stack(
            children: [
              ValueListenableBuilder<_CallOverlayState>(
                valueListenable: _callOverlay,
                child: Scaffold(
                  body: SafeArea(
                    child: _buildResponsiveLayout(
                      threads,
                      selectedThread,
                      isWide: isWide,
                    ),
                  ),
                ),
                builder: (context, overlay, child) => IgnorePointer(
                  ignoring: overlay.hasActiveOverlay,
                  child: ExcludeSemantics(
                    excluding: overlay.hasActiveOverlay,
                    child: child!,
                  ),
                ),
              ),
              ValueListenableBuilder<_CallOverlayState>(
                valueListenable: _callOverlay,
                builder: (context, overlay, child) => Stack(
                  children: [
                    if (overlay.incomingCallInvite case final invite?)
                      _IncomingCallOverlay(
                        invite: invite,
                        onAccept: _acceptIncomingCall,
                        onReject: _rejectIncomingCall,
                      ),
                    if (overlay.callSnapshot case final snapshot?)
                      _ActiveCallOverlay(
                        snapshot: snapshot,
                        onToggleMute: () => _toggleCallMute(snapshot),
                        onToggleCamera: () => _toggleCallCamera(snapshot),
                        onSwitchCamera: _switchCallCamera,
                        onHangUp: _hangUpCall,
                      ),
                    if (overlay.incomingGroupCallInvite case final invite?)
                      _IncomingGroupCallOverlay(
                        invite: invite,
                        onJoin: () => _joinGroupCall(invite.callId),
                        onDecline: () => _declineGroupCall(invite.callId),
                      ),
                    if (overlay.groupCallSnapshot case final snapshot?)
                      _ActiveGroupCallOverlay(
                        snapshot: snapshot,
                        onToggleMute: () => _toggleGroupMute(snapshot),
                        onToggleCamera: () => _toggleGroupCamera(snapshot),
                        onSwitchCamera: () =>
                            unawaited(_groupCallClient?.switchCamera()),
                        onLeave: _leaveGroupCall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildResponsiveLayout(
    List<ChatThread> threads,
    ChatThread? selectedThread, {
    required bool isWide,
  }) {
    final threadPane = _ThreadList(
      key: const ValueKey<String>('thread-pane'),
      threads: threads,
      selectedThread: selectedThread,
      isConnected: widget.repository.isConnected,
      onThreadSelected: isWide ? _selectThread : _selectCompactThread,
      onNewChat: _openNewChat,
      onNewGroup: _openNewGroup,
      onOpenProfile: _openProfile,
      onRefresh: _refreshConversations,
      onSignOut: _requestSignOut,
    );
    final conversationPane = selectedThread == null
        ? const _EmptyConversationPane(
            key: ValueKey<String>('empty-conversation-pane'),
          )
        : _buildConversation(thread: selectedThread, showBackButton: !isWide);

    return _ResponsiveChatShell(
      isWide: isWide,
      compactConversationOpen: _isCompactConversationOpen,
      threadPane: threadPane,
      conversationPane: conversationPane,
    );
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
      insertionEvents: _messageInsertionEvents,
      stagedAttachment: _stagedAttachment?.conversationId == thread.id
          ? _stagedAttachment
          : null,
      messageController: _messageController,
      isSending: _isSending,
      isRecordingVoice: _isRecordingVoice,
      voiceRecordingVisuals: _voiceVisualController,
      isVisible: !showBackButton || _isCompactConversationOpen,
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
      onStartGroupAudioCall: () => _startGroupCall(thread, isVideo: false),
      onStartGroupVideoCall: () => _startGroupCall(thread, isVideo: true),
      activeGroupCall: _activeGroupCalls[thread.id],
      onJoinGroupCall: _joinGroupCall,
      onOpenGroupDetails: () => _openGroupDetails(thread),
      onOpenProfile: _openProfile,
      onSignOut: _requestSignOut,
    );
  }

  List<ChatThread> _mergeThreads(List<ChatThread> threads) {
    final merged = {for (final thread in threads) thread.id: thread};
    for (final thread in _startedThreads) {
      merged.putIfAbsent(thread.id, () => thread);
    }

    final latestLocalMessages = <String, ChatMessage>{};
    for (final message in [..._localMessages, ..._outboxMessages]) {
      final existing = latestLocalMessages[message.threadId];
      if (existing == null || message.createdAt.isAfter(existing.createdAt)) {
        latestLocalMessages[message.threadId] = message;
      }
    }

    final mergedThreads = merged.values.map((thread) {
      final localMessage = latestLocalMessages[thread.id];
      final latestServerMessageAt = thread.latestMessageAt;
      if (localMessage == null ||
          (latestServerMessageAt != null &&
              !localMessage.createdAt.isAfter(latestServerMessageAt))) {
        return thread;
      }

      return thread.copyWith(
        subtitle: _threadPreviewForLocalMessage(thread, localMessage),
        lastActive: relativeTimeLabel(localMessage.createdAt),
        latestMessageAt: localMessage.createdAt,
        status: thread.unreadCount > 0
            ? ChatThreadStatus.unread
            : ChatThreadStatus.none,
      );
    }).toList();

    mergedThreads.sort((a, b) {
      final aTime = a.latestMessageAt;
      final bTime = b.latestMessageAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
    return mergedThreads;
  }

  String _threadPreviewForLocalMessage(ChatThread thread, ChatMessage message) {
    final preview = message.actionPreview;
    if (thread.isGroup) {
      return '${message.isMine ? 'You' : message.senderName}: $preview';
    }
    return message.isMine ? 'You: $preview' : preview;
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
    _scheduleConversationEntryRefresh(thread);
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
    _scheduleConversationEntryRefresh(thread);
  }

  Future<void> _openNewChat() async {
    final user = await showChatDialog<ChatUser>(
      context: context,
      builder: (context) => _NewChatDialog(repository: widget.repository),
    );

    if (user == null || !mounted) {
      return;
    }

    await _startChatWith(user);
  }

  Future<void> _openNewGroup() async {
    final draft = await showChatDialog<_NewGroupDraft>(
      context: context,
      builder: (context) => _NewGroupDialog(repository: widget.repository),
    );
    if (draft == null || !mounted) return;

    try {
      final thread = await widget.repository.createGroupConversation(
        name: draft.name,
        members: draft.members,
      );
      if (!mounted) return;
      setState(() {
        _startedThreads.removeWhere((item) => item.id == thread.id);
        _startedThreads.insert(0, thread);
        _selectedThread = thread;
        _isCompactConversationOpen = true;
      });
      _handleThreadProjectionChanged();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not create group: ${_shortError(error)}'),
        ),
      );
    }
  }

  Future<void> _openGroupDetails(ChatThread thread) async {
    if (!thread.isGroup) return;
    final result = await showChatDialog<_GroupDetailsResult>(
      context: context,
      builder: (context) =>
          _GroupDetailsDialog(repository: widget.repository, thread: thread),
    );
    if (!mounted || result == null) return;

    if (result.leftGroup) {
      final remainingThreads = _availableThreads
          .where((item) => item.id != thread.id)
          .toList();
      setState(() {
        _startedThreads.removeWhere((item) => item.id == thread.id);
        _selectedThread = null;
        _isCompactConversationOpen = false;
      });
      _bindThreadsStream(
        widget.repository.watchThreads(),
        initialData: remainingThreads,
      );
      return;
    }

    final updated = thread.copyWith(
      title: result.name,
      avatarLabel: _groupAvatarLabel(result.name),
      memberCount: result.memberCount,
      activityLabel:
          '${result.memberCount} ${result.memberCount == 1 ? 'member' : 'members'}',
    );
    final updatedThreads = _availableThreads
        .map((item) => item.id == updated.id ? updated : item)
        .toList();
    setState(() {
      _selectedThread = updated;
    });
    _bindThreadsStream(
      widget.repository.watchThreads(),
      initialData: updatedThreads,
    );
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
      _handleThreadProjectionChanged();
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

      _bindThreadsStream(
        widget.repository.watchThreads(),
        initialData: threads,
      );

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
      ChatPageRoute<void>(
        context: context,
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

  Future<void> _startGroupCall(
    ChatThread thread, {
    required bool isVideo,
  }) async {
    final groupClient = _groupCallClient;
    if (groupClient == null ||
        !widget.repository.isConnected ||
        !thread.isGroup) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group calls require a signed-in group.')),
      );
      return;
    }
    try {
      await groupClient.start(conversationId: thread.id, isVideo: isVideo);
    } on CallException catch (error, stackTrace) {
      debugPrint('[Group call start failed] $error\n$stackTrace');
      _showCallError(error.message);
    } catch (error, stackTrace) {
      debugPrint('[Group call start failed] $error\n$stackTrace');
      _showCallError('Could not start the group call.');
    }
  }

  Future<void> _joinGroupCall(String callId) async {
    final groupClient = _groupCallClient;
    if (groupClient == null) return;
    _updateCallOverlay(incomingGroupCallInvite: null);
    unawaited(ChatHaptics.lightImpact());
    try {
      await groupClient.join(callId: callId);
    } on CallException catch (error, stackTrace) {
      debugPrint('[Group call join failed] $error\n$stackTrace');
      _showCallError(error.message);
    } catch (error, stackTrace) {
      debugPrint('[Group call join failed] $error\n$stackTrace');
      _showCallError('Could not join the group call.');
    }
  }

  Future<void> _declineGroupCall(String callId) async {
    final gateway = _groupCallGateway;
    if (gateway == null) return;
    _updateCallOverlay(incomingGroupCallInvite: null);
    try {
      await gateway.decline(callId: callId);
    } catch (error) {
      debugPrint('[Group call decline failed] $error');
    }
  }

  Future<void> _leaveGroupCall() async {
    await _groupCallClient?.leave();
  }

  void _toggleGroupMute(GroupCallSnapshot snapshot) {
    final localParticipants = snapshot.participants
        .where((item) => item.isLocal)
        .toList();
    final local = localParticipants.isEmpty ? null : localParticipants.first;
    if (local != null) unawaited(_groupCallClient?.setMuted(!local.isMuted));
  }

  void _toggleGroupCamera(GroupCallSnapshot snapshot) {
    final localParticipants = snapshot.participants
        .where((item) => item.isLocal)
        .toList();
    final local = localParticipants.isEmpty ? null : localParticipants.first;
    if (local != null) {
      unawaited(_groupCallClient?.setCameraEnabled(!local.isCameraEnabled));
    }
  }

  Future<void> _acceptIncomingCall() async {
    final invite = _incomingCallInvite;
    final callClient = _callClient;
    if (invite == null || callClient == null) {
      return;
    }

    _updateCallOverlay(incomingCallInvite: null);
    unawaited(ChatHaptics.lightImpact());

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

    _updateCallOverlay(incomingCallInvite: null);
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
    final gif = await showChatDialog<GiphyGif>(
      context: context,
      builder: (context) => _GiphyPickerDialog(repository: widget.repository),
    );
    if (gif == null) {
      return null;
    }

    return widget.repository.downloadGiphyGif(gif);
  }

  Future<PickedChatMedia?> _captureCameraMedia() async {
    final captured = await showChatDialog<camera.XFile>(
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
      _voiceVisualController.reset();
      _voiceStreamDone = Completer<void>();
      _voiceRecordingStartedAt = DateTime.now();

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
            _voiceVisualController.addLevel(
              _voiceLevelFromDb(amplitude.current),
            );
          });

      _voiceRecordingTimer?.cancel();
      _voiceRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final startedAt = _voiceRecordingStartedAt;
        if (!mounted || startedAt == null) {
          return;
        }
        _voiceVisualController.updateElapsed(
          DateTime.now().difference(startedAt),
        );
      });

      if (!mounted) {
        await _cancelVoiceRecording();
        return;
      }

      setState(() {
        _isRecordingVoice = true;
      });
      unawaited(ChatHaptics.lightImpact());
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
        ? _voiceVisualController.elapsed.value
        : DateTime.now().difference(startedAt);

    _voiceVisualController.updateElapsed(elapsed);
    setState(() {
      _isRecordingVoice = false;
    });
    unawaited(ChatHaptics.lightImpact());

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

      final waveform = _compactVoiceLevels(_voiceVisualController.levels);
      _voiceBytes.clear();
      _voiceVisualController.clear();
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
    _voiceVisualController.clear();
    _voiceRecordingStartedAt = null;
    await deleteVoiceRecordingFile(_voiceRecordingFilePath);
    _voiceRecordingFilePath = null;
    _isVoiceRecordingFileBacked = false;

    if (mounted && !_isTearingDown) {
      setState(() {
        _isRecordingVoice = false;
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
      final localMessage = ChatMessage(
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
      );
      setState(() {
        _localMessages.add(localMessage);
        _stagedAttachment = null;
        _replyingTo = null;
      });
      _messageInsertionEvents.value = _MessageInsertionEvent(
        messageId: localMessage.id,
        threadId: localMessage.threadId,
        isMine: true,
      );
      unawaited(ChatHaptics.lightImpact());
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
      final queuedMessage = await activeOutbox.enqueue(
        conversationId: selectedThread.id,
        senderId: widget.repository.localUserId,
        senderName: widget.repository.localSenderName,
        body: text,
        // Retain the original encrypted-draft source even after the staging
        // upload succeeds. If membership changes before delivery, the outbox
        // must re-encrypt the bytes for the new epoch instead of retrying an
        // obsolete ciphertext object.
        pickedMedia: stagedAttachment?.pickedMedia,
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
      if (mounted) {
        _messageInsertionEvents.value = _MessageInsertionEvent(
          messageId: queuedMessage.id,
          threadId: queuedMessage.conversationId,
          isMine: true,
        );
        unawaited(ChatHaptics.lightImpact());
      }
      await _flushOutbox();
      OutboxMessage? unsent;
      for (final item in activeOutbox.items) {
        if (item.id == queuedMessage.id) {
          unsent = item;
          break;
        }
      }
      final sendError = unsent?.lastError;
      if (mounted && sendError != null && sendError.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Message not sent: $sendError')));
      }
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
    if (message.isLocked || message.hasInvalidEncryption) {
      _showMessageActionError('This encrypted message is unavailable.');
      return;
    }
    setState(() {
      _replyingTo = message;
      _editingMessage = null;
    });
  }

  void _startEdit(ChatMessage message) {
    if (message.isLocked || message.hasInvalidEncryption) {
      _showMessageActionError('This encrypted message is unavailable.');
      return;
    }
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
    if (message.isLocked || message.hasInvalidEncryption) {
      _showMessageActionError('This encrypted message is unavailable.');
      return;
    }
    if (message.messageType == ChatMessageType.text && body.isEmpty) {
      _showMessageActionError('Text messages cannot be empty.');
      return;
    }
    try {
      if (widget.repository.isConnected) {
        await widget.repository.editMessage(message: message, body: body);
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
    final confirmed = await showChatDialog<bool>(
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
    if (message.isLocked || message.hasInvalidEncryption) {
      _showMessageActionError('This encrypted message is unavailable.');
      return;
    }
    try {
      if (widget.repository.isConnected) {
        await widget.repository.toggleMessageReaction(
          message: message,
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
    final selected = await showChatModalBottomSheet<String>(
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
                  children: [
                    for (var index = 0; index < quick.length; index++)
                      ChatStagger(
                        index: index,
                        child: ActionChip(
                          label: Text(
                            quick[index],
                            style: const TextStyle(fontSize: 22),
                          ),
                          onPressed: () => Navigator.pop(context, quick[index]),
                        ),
                      ),
                  ],
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
      unawaited(ChatHaptics.selection());
      await _toggleMessageReaction(message, selected);
    }
  }

  Future<void> _copyMessage(ChatMessage message) async {
    if (message.isLocked || message.hasInvalidEncryption) {
      _showMessageActionError('This encrypted message is unavailable.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: message.body));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message copied.')));
  }

  Future<void> _forwardMessage(ChatMessage message) async {
    if (message.isLocked || message.hasInvalidEncryption) {
      _showMessageActionError('This encrypted message is unavailable.');
      return;
    }
    final destination = await showChatDialog<ChatThread>(
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

class _E2eeRecoveryPhraseConfirmationDialog extends StatefulWidget {
  const _E2eeRecoveryPhraseConfirmationDialog({
    required this.phrase,
    required this.onConfirm,
  });

  final String phrase;
  final Future<void> Function(String phrase) onConfirm;

  @override
  State<_E2eeRecoveryPhraseConfirmationDialog> createState() =>
      _E2eeRecoveryPhraseConfirmationDialogState();
}

class _E2eeRecoveryPhraseConfirmationDialogState
    extends State<_E2eeRecoveryPhraseConfirmationDialog> {
  final _controller = TextEditingController();
  bool _savedPhrase = false;
  bool _isConfirming = false;
  String? _error;

  String get _enteredPhrase => _normalizePhrase(_controller.text);

  bool get _matchesPhrase =>
      _enteredPhrase == _normalizePhrase(widget.phrase) &&
      _enteredPhrase.split(' ').length == 24;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_isConfirming) return;
    if (!_matchesPhrase) {
      setState(() {
        _error = 'Enter all 24 words exactly as shown.';
      });
      return;
    }
    if (!_savedPhrase) {
      setState(() {
        _error = 'Confirm that you have saved the recovery phrase.';
      });
      return;
    }

    setState(() {
      _isConfirming = true;
      _error = null;
    });
    try {
      await widget.onConfirm(_enteredPhrase);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
              'The recovery phrase could not be confirmed. Check the words and try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isConfirming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wordCount = _enteredPhrase.isEmpty
        ? 0
        : _enteredPhrase.split(' ').length;

    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.key_outlined),
            SizedBox(width: 10),
            Expanded(child: Text('Save your recovery phrase')),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This 24-word phrase is the only way to restore your encrypted conversations on another device. It is never sent to the server.',
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    widget.phrase,
                    key: const Key('e2ee-recovery-phrase'),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Write it down, then enter every word below to confirm before messaging is enabled.',
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('e2ee-recovery-phrase-confirmation'),
                  controller: _controller,
                  enabled: !_isConfirming,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: true,
                  maxLines: 1,
                  textCapitalization: TextCapitalization.none,
                  onChanged: (_) {
                    if (_error != null) {
                      setState(() {
                        _error = null;
                      });
                    } else {
                      setState(() {});
                    }
                  },
                  onSubmitted: (_) => _confirm(),
                  decoration: InputDecoration(
                    labelText: 'Re-enter all 24 words',
                    helperText: '$wordCount of 24 words entered',
                    errorText: _error,
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _savedPhrase,
                  onChanged: _isConfirming
                      ? null
                      : (value) {
                          setState(() {
                            _savedPhrase = value ?? false;
                            _error = null;
                          });
                        },
                  title: const Text(
                    'I have saved this recovery phrase safely.',
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: _isConfirming || !_matchesPhrase || !_savedPhrase
                ? null
                : _confirm,
            child: _isConfirming
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Confirm and continue'),
          ),
        ],
      ),
    );
  }
}

class _E2eeRecoveryPhraseRestoreDialog extends StatefulWidget {
  const _E2eeRecoveryPhraseRestoreDialog({required this.onRestore});

  final Future<void> Function(String phrase) onRestore;

  @override
  State<_E2eeRecoveryPhraseRestoreDialog> createState() =>
      _E2eeRecoveryPhraseRestoreDialogState();
}

class _E2eeRecoveryPhraseRestoreDialogState
    extends State<_E2eeRecoveryPhraseRestoreDialog> {
  final _controller = TextEditingController();
  bool _isRestoring = false;
  bool _showPhrase = false;
  String? _error;

  String get _phrase => _normalizePhrase(_controller.text);

  bool get _has24Words => _phrase.isNotEmpty && _phrase.split(' ').length == 24;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    if (_isRestoring) return;
    if (!_has24Words) {
      setState(() {
        _error = 'Enter all 24 recovery words.';
      });
      return;
    }

    setState(() {
      _isRestoring = true;
      _error = null;
    });
    try {
      await widget.onRestore(_phrase);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
              'That recovery phrase could not be used. Check the words and try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRestoring = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wordCount = _phrase.isEmpty ? 0 : _phrase.split(' ').length;

    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lock_reset_outlined),
            SizedBox(width: 10),
            Expanded(child: Text('Restore encrypted messages')),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This account already has an encryption identity, but this device does not. Enter your 24-word recovery phrase to unlock encrypted conversations. The phrase stays on this device.',
                ),
                const SizedBox(height: 18),
                TextField(
                  key: const Key('e2ee-recovery-phrase-restore'),
                  controller: _controller,
                  enabled: !_isRestoring,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: !_showPhrase,
                  maxLines: 1,
                  textCapitalization: TextCapitalization.none,
                  onChanged: (_) {
                    if (_error != null) {
                      setState(() {
                        _error = null;
                      });
                    } else {
                      setState(() {});
                    }
                  },
                  onSubmitted: (_) => _restore(),
                  decoration: InputDecoration(
                    labelText: '24-word recovery phrase',
                    helperText: '$wordCount of 24 words entered',
                    errorText: _error,
                    suffixIcon: IconButton(
                      tooltip: _showPhrase ? 'Hide phrase' : 'Show phrase',
                      onPressed: _isRestoring
                          ? null
                          : () {
                              setState(() {
                                _showPhrase = !_showPhrase;
                              });
                            },
                      icon: Icon(
                        _showPhrase
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: _isRestoring || !_has24Words ? null : _restore,
            child: _isRestoring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Restore and continue'),
          ),
        ],
      ),
    );
  }
}

class _E2eeRetryDialog extends StatelessWidget {
  const _E2eeRetryDialog({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.shield_outlined),
            const SizedBox(width: 10),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

String _normalizePhrase(String phrase) {
  return phrase
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .join(' ');
}

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog({
    required this.repository,
    this.title = 'New message',
    this.excludedUserIds = const {},
  });

  final ChatRepository repository;
  final String title;
  final Set<String> excludedUserIds;

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
      title: Row(
        children: [
          const Icon(Icons.edit_square),
          const SizedBox(width: 10),
          Text(widget.title),
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
      final users = (await widget.repository.searchUsers(
        query,
      )).where((user) => !widget.excludedUserIds.contains(user.id)).toList();
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

class _NewGroupDraft {
  const _NewGroupDraft({required this.name, required this.members});

  final String name;
  final List<ChatUser> members;
}

class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog({required this.repository});

  final ChatRepository repository;

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  final _nameController = TextEditingController();
  final _searchController = TextEditingController();
  final Map<String, ChatUser> _selectedUsers = {};
  Timer? _debounce;
  List<ChatUser> _users = const [];
  String? _error;
  bool _isLoading = false;
  int _requestId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canCreate =
        _nameController.text.trim().isNotEmpty &&
        _nameController.text.trim().length <= 80 &&
        _selectedUsers.length >= 2 &&
        _selectedUsers.length <= 49;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.group_add_outlined),
          SizedBox(width: 10),
          Text('New group'),
        ],
      ),
      content: SizedBox(
        width: 480,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('new-group-name'),
              controller: _nameController,
              autofocus: true,
              maxLength: 80,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Group name',
                prefixIcon: Icon(Icons.groups_outlined),
              ),
            ),
            if (_selectedUsers.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _selectedUsers.values
                    .map(
                      (user) => InputChip(
                        label: Text(user.displayName),
                        onDeleted: () => setState(() {
                          _selectedUsers.remove(user.id);
                        }),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 10),
            ],
            TextField(
              key: const Key('new-group-search'),
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: _scheduleSearch,
              decoration: InputDecoration(
                hintText: 'Search people',
                prefixIcon: const Icon(Icons.search),
                helperText: '${_selectedUsers.length}/49 selected',
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildResults()),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('create-group'),
          onPressed: canCreate
              ? () => Navigator.of(context).pop(
                  _NewGroupDraft(
                    name: _nameController.text.trim(),
                    members: _selectedUsers.values.toList(),
                  ),
                )
              : null,
          child: const Text('Create group'),
        ),
      ],
    );
  }

  Widget _buildResults() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_searchController.text.trim().isEmpty) {
      return const Center(
        child: Text('Search and select at least two people.'),
      );
    }
    if (_users.isEmpty) {
      return const Center(child: Text('No users found.'));
    }
    return ListView.builder(
      itemCount: _users.length,
      itemBuilder: (context, index) {
        final user = _users[index];
        final selected = _selectedUsers.containsKey(user.id);
        return CheckboxListTile(
          value: selected,
          secondary: _UserAvatar(user: user),
          title: Text(user.displayName),
          subtitle: user.email == null ? null : Text(user.email!),
          onChanged: _selectedUsers.length >= 49 && !selected
              ? null
              : (value) => setState(() {
                  if (value == true) {
                    _selectedUsers[user.id] = user;
                  } else {
                    _selectedUsers.remove(user.id);
                  }
                }),
        );
      },
    );
  }

  void _scheduleSearch(String value) {
    _debounce?.cancel();
    setState(() {
      _users = const [];
      _error = null;
      _isLoading = value.trim().isNotEmpty;
    });
    if (value.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(value));
  }

  Future<void> _search(String query) async {
    final requestId = ++_requestId;
    try {
      final users = await widget.repository.searchUsers(query);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _users = users;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = 'Could not search users.';
        _isLoading = false;
      });
    }
  }
}

class _GroupDetailsResult {
  const _GroupDetailsResult({
    required this.name,
    required this.memberCount,
    this.leftGroup = false,
  });

  final String name;
  final int memberCount;
  final bool leftGroup;
}

class _GroupDetailsDialog extends StatefulWidget {
  const _GroupDetailsDialog({required this.repository, required this.thread});

  final ChatRepository repository;
  final ChatThread thread;

  @override
  State<_GroupDetailsDialog> createState() => _GroupDetailsDialogState();
}

class _GroupDetailsDialogState extends State<_GroupDetailsDialog> {
  List<ChatGroupMember> _members = const [];
  late String _name;
  bool _isLoading = true;
  bool _isWorking = false;
  String? _error;

  bool get _isAdmin =>
      _members.any((member) => member.isCurrentUser && member.isAdmin);

  @override
  void initState() {
    super.initState();
    _name = widget.thread.title;
    unawaited(_loadMembers());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          CircleAvatar(child: Text(_groupAvatarLabel(_name))),
          const SizedBox(width: 12),
          Expanded(child: Text(_name, overflow: TextOverflow.ellipsis)),
          if (_isAdmin)
            IconButton(
              tooltip: 'Rename group',
              onPressed: _isWorking ? null : _rename,
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
      content: SizedBox(
        width: 480,
        height: 460,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_members.length} ${_members.length == 1 ? 'member' : 'members'}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (_isAdmin)
                        TextButton.icon(
                          onPressed: _isWorking ? null : _addMember,
                          icon: const Icon(Icons.person_add_alt_1_outlined),
                          label: const Text('Add'),
                        ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _members.length,
                      itemBuilder: (context, index) {
                        final member = _members[index];
                        return ListTile(
                          leading: _UserAvatar(user: member.user),
                          title: Text(
                            member.isCurrentUser
                                ? '${member.user.displayName} (you)'
                                : member.user.displayName,
                          ),
                          subtitle: member.isAdmin ? const Text('Admin') : null,
                          trailing: _isAdmin && !member.isCurrentUser
                              ? IconButton(
                                  tooltip: 'Remove member',
                                  onPressed: _isWorking
                                      ? null
                                      : () => _removeMember(member),
                                  icon: const Icon(
                                    Icons.person_remove_outlined,
                                  ),
                                )
                              : null,
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _isWorking ? null : _leave,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: const Text('Leave group'),
        ),
        FilledButton(
          onPressed: _isWorking
              ? null
              : () => Navigator.of(context).pop(
                  _GroupDetailsResult(
                    name: _name,
                    memberCount: _members.length,
                  ),
                ),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _loadMembers() async {
    try {
      final members = await widget.repository.groupMembers(widget.thread.id);
      if (!mounted) return;
      setState(() {
        _members = members;
        _isLoading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load members: ${_shortError(error)}';
        _isLoading = false;
      });
    }
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _name);
    final name = await showChatDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          key: const Key('rename-group-name'),
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == _name) return;
    await _run(() async {
      await widget.repository.renameGroup(widget.thread.id, name);
      _name = name;
    });
  }

  Future<void> _addMember() async {
    final user = await showChatDialog<ChatUser>(
      context: context,
      builder: (context) => _NewChatDialog(
        repository: widget.repository,
        title: 'Add member',
        excludedUserIds: _members.map((member) => member.user.id).toSet(),
      ),
    );
    if (user == null) return;
    await _run(() async {
      await widget.repository.addGroupMember(widget.thread.id, user);
      await _loadMembers();
    });
  }

  Future<void> _removeMember(ChatGroupMember member) async {
    await _run(() async {
      await widget.repository.removeGroupMember(
        widget.thread.id,
        member.user.id,
      );
      await _loadMembers();
    });
  }

  Future<void> _leave() async {
    final confirmed = await showChatDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave group?'),
        content: const Text(
          'You will lose access to this group and its messages.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await widget.repository.leaveGroup(widget.thread.id);
      if (mounted) {
        Navigator.of(context).pop(
          _GroupDetailsResult(name: _name, memberCount: 0, leftGroup: true),
        );
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _isWorking = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _shortError(error));
    } finally {
      if (mounted) setState(() => _isWorking = false);
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

class _ResponsiveChatShell extends StatelessWidget {
  const _ResponsiveChatShell({
    required this.isWide,
    required this.compactConversationOpen,
    required this.threadPane,
    required this.conversationPane,
  });

  final bool isWide;
  final bool compactConversationOpen;
  final Widget threadPane;
  final Widget conversationPane;

  @override
  Widget build(BuildContext context) {
    final policy = context.chatMotion;
    final duration = policy.duration(policy.theme.emphasizedDuration);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final threadWidth = isWide ? 360.0 : width;
        final conversationWidth = isWide ? math.max(0.0, width - 361) : width;
        final showThread = isWide || !compactConversationOpen;
        final showConversation = isWide || compactConversationOpen;
        final threadLeft = isWide
            ? 0.0
            : compactConversationOpen
            ? -width
            : 0.0;
        final conversationLeft = isWide
            ? 361.0
            : compactConversationOpen
            ? 0.0
            : width;

        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedPositioned(
                duration: duration,
                curve: Curves.easeOutCubic,
                left: threadLeft,
                top: 0,
                bottom: 0,
                width: threadWidth,
                child: _ResponsivePaneActivity(
                  active: showThread,
                  child: threadPane,
                ),
              ),
              AnimatedPositioned(
                duration: duration,
                curve: Curves.easeOutCubic,
                left: conversationLeft,
                top: 0,
                bottom: 0,
                width: conversationWidth,
                child: _ResponsivePaneActivity(
                  active: showConversation,
                  child: conversationPane,
                ),
              ),
              if (isWide)
                const Positioned(
                  left: 360,
                  top: 0,
                  bottom: 0,
                  child: VerticalDivider(width: 1),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ResponsivePaneActivity extends StatelessWidget {
  const _ResponsivePaneActivity({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !active,
      child: IgnorePointer(
        ignoring: !active,
        child: ExcludeFocus(
          excluding: !active,
          child: ExcludeSemantics(
            excluding: !active,
            child: TickerMode(
              enabled: active,
              child: HeroMode(enabled: active, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThreadList extends StatefulWidget {
  const _ThreadList({
    super.key,
    required this.threads,
    required this.selectedThread,
    required this.isConnected,
    required this.onThreadSelected,
    required this.onNewChat,
    required this.onNewGroup,
    required this.onOpenProfile,
    required this.onRefresh,
    required this.onSignOut,
  });

  final List<ChatThread> threads;
  final ChatThread? selectedThread;
  final bool isConnected;
  final ValueChanged<ChatThread> onThreadSelected;
  final VoidCallback onNewChat;
  final VoidCallback onNewGroup;
  final VoidCallback onOpenProfile;
  final Future<void> Function() onRefresh;
  final VoidCallback onSignOut;

  @override
  State<_ThreadList> createState() => _ThreadListState();
}

class _ThreadListState extends State<_ThreadList> {
  final TextEditingController searchController = TextEditingController();
  String _query = '';
  _ThreadStatusFilter statusFilter = _ThreadStatusFilter.all;

  List<ChatThread> get threads {
    final normalizedQuery = _query.trim().toLowerCase();
    return widget.threads.where((thread) {
      final statusMatches = switch (statusFilter) {
        _ThreadStatusFilter.all => true,
        _ThreadStatusFilter.unread => thread.status == ChatThreadStatus.unread,
        _ThreadStatusFilter.sent => thread.status == ChatThreadStatus.sent,
        _ThreadStatusFilter.delivered =>
          thread.status == ChatThreadStatus.delivered,
        _ThreadStatusFilter.read => thread.status == ChatThreadStatus.read,
      };
      if (!statusMatches) return false;
      if (normalizedQuery.isEmpty) return true;
      return thread.title.toLowerCase().contains(normalizedQuery) ||
          thread.displaySubtitle.toLowerCase().contains(normalizedQuery);
    }).toList();
  }

  ChatThread? get selectedThread => widget.selectedThread;
  bool get isConnected => widget.isConnected;
  ValueChanged<ChatThread> get onThreadSelected => widget.onThreadSelected;
  VoidCallback get onNewChat => widget.onNewChat;
  VoidCallback get onNewGroup => widget.onNewGroup;
  VoidCallback get onOpenProfile => widget.onOpenProfile;
  Future<void> Function() get onRefresh => widget.onRefresh;
  VoidCallback get onSignOut => widget.onSignOut;

  String get emptyMessage {
    if (widget.threads.isEmpty) return 'No conversations yet.';
    if (_query.trim().isNotEmpty) return 'No conversations match your search.';
    return 'No ${statusFilter.label.toLowerCase()} conversations.';
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  void onSearchChanged(String value) {
    setState(() {
      _query = value;
    });
  }

  void onStatusFilterChanged(_ThreadStatusFilter value) {
    if (value == statusFilter) return;
    setState(() {
      statusFilter = value;
    });
    unawaited(ChatHaptics.selection());
  }

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
                  tooltip: 'New group',
                  onPressed: onNewGroup,
                  icon: const Icon(Icons.group_add_outlined),
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
            _ThreadFilterBar(
              selected: statusFilter,
              onSelected: onStatusFilterChanged,
            ),
            const SizedBox(height: 12),
            _BackendStatusPill(isConnected: isConnected),
            const SizedBox(height: 16),
            Expanded(
              child: RefreshIndicator(
                onRefresh: onRefresh,
                child: ChatStateSwitcher(
                  alignment: Alignment.topCenter,
                  child: threads.isEmpty
                      ? ListView(
                          key: ValueKey<String>('threads-empty-$emptyMessage'),
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            SizedBox(
                              height: 280,
                              child: _EmptyThreadList(message: emptyMessage),
                            ),
                          ],
                        )
                      : ListView.separated(
                          key: const ValueKey<String>('threads-list'),
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: threads.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final thread = threads[index];
                            return ChatStagger(
                              key: ValueKey<String>(
                                'thread-motion-${thread.id}',
                              ),
                              index: index,
                              child: ChatPressScale(
                                row: true,
                                child: _ThreadTile(
                                  key: ValueKey<String>('thread-${thread.id}'),
                                  thread: thread,
                                  isSelected: thread.id == selectedThread?.id,
                                  onTap: () => onThreadSelected(thread),
                                ),
                              ),
                            );
                          },
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

class _ThreadFilterBar extends StatelessWidget {
  const _ThreadFilterBar({required this.selected, required this.onSelected});

  static const _itemWidth = 76.0;
  static const _spacing = 6.0;

  final _ThreadStatusFilter selected;
  final ValueChanged<_ThreadStatusFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policy = context.chatMotion;
    final filters = _ThreadStatusFilter.values;
    final selectedIndex = filters.indexOf(selected);
    final totalWidth =
        filters.length * _itemWidth + (filters.length - 1) * _spacing;

    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: policy.duration(policy.theme.emphasizedDuration),
                curve: Curves.easeOutCubic,
                left: selectedIndex * (_itemWidth + _spacing),
                top: 0,
                width: _itemWidth,
                height: 36,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var index = 0; index < filters.length; index++) ...[
                    if (index > 0) const SizedBox(width: _spacing),
                    SizedBox(
                      width: _itemWidth,
                      height: 36,
                      child: Semantics(
                        button: true,
                        selected: filters[index] == selected,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            key: Key(
                              'thread-status-filter-${filters[index].name}',
                            ),
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => onSelected(filters[index]),
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: policy.duration(
                                  policy.theme.microDuration,
                                ),
                                style: theme.textTheme.labelMedium!.copyWith(
                                  color: filters[index] == selected
                                      ? theme.colorScheme.onSecondaryContainer
                                      : theme.colorScheme.onSurfaceVariant,
                                  fontWeight: filters[index] == selected
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                ),
                                child: Text(
                                  filters[index].label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyThreadList extends StatelessWidget {
  const _EmptyThreadList({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
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
      child: ChatStateSwitcher(
        alignment: Alignment.centerLeft,
        child: Row(
          key: ValueKey<bool>(isConnected),
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
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    super.key,
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
        duration: context.chatMotion.duration(
          context.chatMotion.theme.standardDuration,
        ),
        curve: Curves.easeOutCubic,
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
                        child: ChatStateSwitcher(
                          alignment: Alignment.centerLeft,
                          offset: const Offset(0, 4),
                          child: Text(
                            thread.displaySubtitle,
                            key: ValueKey<String>(
                              '${thread.id}:${thread.displaySubtitle}',
                            ),
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
                      ),
                      ChatSizeFade(
                        alignment: Alignment.centerRight,
                        child: thread.unreadCount > 0
                            ? Padding(
                                key: ValueKey<String>(
                                  'unread-${thread.id}-visible',
                                ),
                                padding: const EdgeInsets.only(left: 8),
                                child: _UnreadBadge(
                                  key: Key('unread-badge-${thread.id}'),
                                  count: thread.unreadCount,
                                ),
                              )
                            : null,
                      ),
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
  const _EmptyConversationPane({super.key});

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

class _ConversationPane extends StatefulWidget {
  const _ConversationPane({
    super.key,
    required this.thread,
    required this.repository,
    required this.localMessages,
    required this.insertionEvents,
    required this.stagedAttachment,
    required this.messageController,
    required this.isSending,
    required this.isRecordingVoice,
    required this.voiceRecordingVisuals,
    required this.isVisible,
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
    required this.onStartGroupAudioCall,
    required this.onStartGroupVideoCall,
    required this.activeGroupCall,
    required this.onJoinGroupCall,
    required this.onOpenGroupDetails,
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
  final ValueListenable<_MessageInsertionEvent?> insertionEvents;
  final _StagedMediaAttachment? stagedAttachment;
  final TextEditingController messageController;
  final bool isSending;
  final bool isRecordingVoice;
  final _VoiceRecordingVisualController voiceRecordingVisuals;
  final bool isVisible;
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
  final VoidCallback onStartGroupAudioCall;
  final VoidCallback onStartGroupVideoCall;
  final GroupCallSessionSummary? activeGroupCall;
  final Future<void> Function(String callId) onJoinGroupCall;
  final VoidCallback onOpenGroupDetails;
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
  State<_ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends State<_ConversationPane>
    with WidgetsBindingObserver, RouteAware {
  final ScrollController messagesScrollController = ScrollController();
  StreamSubscription<List<ChatMessage>>? _messageSubscription;
  List<ChatMessage> _remoteMessages = const [];
  final Set<String> _animatedMessageIds = {};
  PageRoute<dynamic>? _route;
  bool _routeVisible = true;
  bool _appActive = true;
  bool _markReadInFlight = false;
  bool _receivedInitialRemoteSnapshot = false;
  bool _didInitialScroll = false;
  bool _isNearLatest = true;
  int _unseenMessageCount = 0;
  String? _lastReadFingerprint;

  ChatThread get thread => widget.thread;
  ChatRepository get repository => widget.repository;
  List<ChatMessage> get localMessages => widget.localMessages;
  _StagedMediaAttachment? get stagedAttachment => widget.stagedAttachment;
  TextEditingController get messageController => widget.messageController;
  bool get isSending => widget.isSending;
  bool get isRecordingVoice => widget.isRecordingVoice;
  _VoiceRecordingVisualController get voiceRecordingVisuals =>
      widget.voiceRecordingVisuals;
  bool get showBackButton => widget.showBackButton;
  VoidCallback get onBackToInbox => widget.onBackToInbox;
  VoidCallback get onSend => widget.onSend;
  ValueChanged<ChatMediaSource> get onAttachMedia => widget.onAttachMedia;
  VoidCallback get onToggleVoiceRecording => widget.onToggleVoiceRecording;
  Future<void> Function() get onRemoveAttachment => widget.onRemoveAttachment;
  VoidCallback get onRetryAttachment => widget.onRetryAttachment;
  Future<void> Function(String) get onRetryOutboxMessage =>
      widget.onRetryOutboxMessage;
  ValueChanged<String> get onComposerChanged => widget.onComposerChanged;
  VoidCallback get onStartAudioCall => widget.onStartAudioCall;
  VoidCallback get onStartVideoCall => widget.onStartVideoCall;
  VoidCallback get onStartGroupAudioCall => widget.onStartGroupAudioCall;
  VoidCallback get onStartGroupVideoCall => widget.onStartGroupVideoCall;
  GroupCallSessionSummary? get activeGroupCall => widget.activeGroupCall;
  Future<void> Function(String) get onJoinGroupCall => widget.onJoinGroupCall;
  VoidCallback get onOpenGroupDetails => widget.onOpenGroupDetails;
  VoidCallback get onOpenProfile => widget.onOpenProfile;
  VoidCallback get onSignOut => widget.onSignOut;
  ChatMessage? get replyingTo => widget.replyingTo;
  ChatMessage? get editingMessage => widget.editingMessage;
  VoidCallback get onCancelComposerAction => widget.onCancelComposerAction;
  ValueChanged<ChatMessage> get onReply => widget.onReply;
  ValueChanged<ChatMessage> get onEdit => widget.onEdit;
  Future<void> Function(ChatMessage) get onDelete => widget.onDelete;
  Future<void> Function(ChatMessage) get onReact => widget.onReact;
  Future<void> Function(ChatMessage, String) get onToggleReaction =>
      widget.onToggleReaction;
  Future<void> Function(ChatMessage) get onForward => widget.onForward;
  Future<void> Function(ChatMessage) get onCopy => widget.onCopy;

  List<ChatMessage> get _messages {
    final messagesById = <String, ChatMessage>{
      for (final message in _remoteMessages) message.id: message,
      for (final message in localMessages) message.id: message,
    };
    return messagesById.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    messagesScrollController.addListener(_handleScrollPosition);
    widget.insertionEvents.addListener(_handleInsertionEvent);
    _remoteMessages = ChatSeed.messagesFor(thread.id);
    _bindMessageStream();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextRoute = ModalRoute.of(context);
    if (nextRoute is PageRoute<dynamic> && !identical(nextRoute, _route)) {
      if (_route != null) chatRouteObserver.unsubscribe(this);
      _route = nextRoute;
      _routeVisible = nextRoute.isCurrent;
      chatRouteObserver.subscribe(this, nextRoute);
    }
  }

  @override
  void didUpdateWidget(covariant _ConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.insertionEvents != widget.insertionEvents) {
      oldWidget.insertionEvents.removeListener(_handleInsertionEvent);
      widget.insertionEvents.addListener(_handleInsertionEvent);
    }
    if (oldWidget.repository != repository ||
        oldWidget.thread.id != thread.id) {
      _lastReadFingerprint = null;
      _remoteMessages = ChatSeed.messagesFor(thread.id);
      _animatedMessageIds.clear();
      _receivedInitialRemoteSnapshot = false;
      _didInitialScroll = false;
      _isNearLatest = true;
      _unseenMessageCount = 0;
      _bindMessageStream();
      return;
    }

    if (!oldWidget.isVisible && widget.isVisible) {
      _scheduleMarkRead();
      _scheduleScrollToLatest(initial: !_didInitialScroll);
    }
  }

  @override
  void dispose() {
    chatRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    widget.insertionEvents.removeListener(_handleInsertionEvent);
    messagesScrollController.removeListener(_handleScrollPosition);
    unawaited(_messageSubscription?.cancel());
    messagesScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (_appActive) _scheduleMarkRead();
  }

  @override
  void didPush() {
    _routeVisible = true;
    _scheduleMarkRead();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _scheduleMarkRead();
  }

  @override
  void didPushNext() {
    _routeVisible = false;
  }

  @override
  void didPop() {
    _routeVisible = false;
  }

  void _bindMessageStream() {
    unawaited(_messageSubscription?.cancel());
    _messageSubscription = repository
        .watchMessages(thread.id)
        .listen(
          _handleRemoteMessages,
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('[Message stream ${thread.id}] $error\n$stackTrace');
          },
        );
  }

  void _handleRemoteMessages(List<ChatMessage> messages) {
    if (!mounted) return;
    final existingIds = _messages.map((message) => message.id).toSet();
    final newMessages = messages
        .where((message) => !existingIds.contains(message.id))
        .toList(growable: false);
    final animateNewMessages = _receivedInitialRemoteSnapshot;
    final shouldFollow = _isNearLatest;

    setState(() {
      _remoteMessages = messages;
      if (animateNewMessages) {
        _animatedMessageIds.addAll(newMessages.map((message) => message.id));
        if (!shouldFollow) {
          _unseenMessageCount += newMessages.length;
        }
      }
      _receivedInitialRemoteSnapshot = true;
    });

    if (!_didInitialScroll) {
      _scheduleScrollToLatest(initial: true);
    } else if (newMessages.isNotEmpty && shouldFollow) {
      _scheduleScrollToLatest();
    }
    _scheduleMarkRead();
  }

  void _handleInsertionEvent() {
    final event = widget.insertionEvents.value;
    if (!mounted || event == null || event.threadId != thread.id) return;
    final shouldFollow = _isNearLatest;
    setState(() {
      _animatedMessageIds.add(event.messageId);
      if (!shouldFollow) _unseenMessageCount += 1;
    });
    if (shouldFollow) _scheduleScrollToLatest();
  }

  void _handleScrollPosition() {
    if (!messagesScrollController.hasClients) return;
    final position = messagesScrollController.position;
    final isNearLatest = position.maxScrollExtent - position.pixels <= 96;
    if (isNearLatest == _isNearLatest &&
        !(isNearLatest && _unseenMessageCount > 0)) {
      return;
    }
    setState(() {
      _isNearLatest = isNearLatest;
      if (isNearLatest) _unseenMessageCount = 0;
    });
  }

  void _scheduleMarkRead() {
    if (!mounted ||
        !repository.isConnected ||
        !widget.isVisible ||
        !_routeVisible ||
        !_appActive ||
        _markReadInFlight) {
      return;
    }

    final unreadIncoming = _remoteMessages
        .where((message) => !message.isMine && !message.isRead)
        .toList(growable: false);
    if (unreadIncoming.isEmpty) return;
    final fingerprint = unreadIncoming.map((message) => message.id).join('|');
    if (_lastReadFingerprint == fingerprint) return;

    _lastReadFingerprint = fingerprint;
    _markReadInFlight = true;
    unawaited(
      repository
          .markConversationRead(thread.id)
          .catchError((Object error, StackTrace stackTrace) {
            if (_lastReadFingerprint == fingerprint) {
              _lastReadFingerprint = null;
            }
            debugPrint('[Read receipt ${thread.id}] $error\n$stackTrace');
          })
          .whenComplete(() {
            _markReadInFlight = false;
          }),
    );
  }

  void _scheduleScrollToLatest({bool explicit = false, bool initial = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !messagesScrollController.hasClients) return;
      if (!explicit && !initial && !_isNearLatest) return;
      final target = messagesScrollController.position.maxScrollExtent;
      final policy = context.chatMotion;
      if (initial || policy.reduceMotion) {
        messagesScrollController.jumpTo(target);
      } else {
        unawaited(
          messagesScrollController.animateTo(
            target,
            duration: policy.theme.standardDuration,
            curve: Curves.easeOutCubic,
          ),
        );
      }
      _didInitialScroll = true;
      if (_unseenMessageCount > 0) {
        setState(() {
          _unseenMessageCount = 0;
          _isNearLatest = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messages = _messages;

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
                    ChatStateSwitcher(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        thread.title,
                        key: ValueKey<String>('header-${thread.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
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
                          child: ChatStateSwitcher(
                            alignment: Alignment.centerLeft,
                            offset: const Offset(0, 4),
                            child: Text(
                              thread.activityLabel,
                              key: ValueKey<String>(
                                '${thread.id}:${thread.activityLabel}',
                              ),
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
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Safety numbers',
                onPressed: () => _showSafetyNumbers(context),
                icon: const Icon(Icons.shield_outlined),
              ),
              if (thread.isGroup) ...[
                IconButton(
                  tooltip: 'Start voice group call (media E2EE is phase 2)',
                  onPressed: onStartGroupAudioCall,
                  icon: const Icon(Icons.call_outlined),
                ),
                IconButton(
                  tooltip: 'Start video group call (media E2EE is phase 2)',
                  onPressed: onStartGroupVideoCall,
                  icon: const Icon(Icons.videocam_outlined),
                ),
                IconButton(
                  tooltip: 'Group info',
                  onPressed: onOpenGroupDetails,
                  icon: const Icon(Icons.group_outlined),
                ),
              ] else ...[
                IconButton(
                  tooltip: 'Call (media E2EE is phase 2)',
                  onPressed: onStartAudioCall,
                  icon: const Icon(Icons.call_outlined),
                ),
                IconButton(
                  tooltip: 'Video (media E2EE is phase 2)',
                  onPressed: onStartVideoCall,
                  icon: const Icon(Icons.videocam_outlined),
                ),
              ],
            ],
          ),
        ),
        if (thread.isGroup && activeGroupCall != null)
          MaterialBanner(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            leading: Icon(
              activeGroupCall!.isVideo ? Icons.videocam : Icons.call,
              color: Theme.of(context).colorScheme.primary,
            ),
            content: Text(
              '${activeGroupCall!.title} · ${activeGroupCall!.participantCount} '
              '${activeGroupCall!.participantCount == 1 ? 'person' : 'people'} active',
            ),
            actions: [
              TextButton(
                onPressed: () => onJoinGroupCall(activeGroupCall!.callId),
                child: const Text('Join'),
              ),
            ],
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: messages.isEmpty
                    ? const _EmptyMessageList()
                    : ListView.builder(
                        controller: messagesScrollController,
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 72),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          return _AnimatedMessageEntry(
                            key: ValueKey<String>(
                              'message-entry-${message.id}',
                            ),
                            animate: _animatedMessageIds.contains(message.id),
                            isMine: message.isMine,
                            onComplete: () {
                              if (!mounted) return;
                              setState(() {
                                _animatedMessageIds.remove(message.id);
                              });
                            },
                            child: _MessageBubble(
                              key: ValueKey<String>('message-${message.id}'),
                              message: message,
                              repository: repository,
                              onRetry: () => onRetryOutboxMessage(message.id),
                              onReply: onReply,
                              onEdit: onEdit,
                              onDelete: onDelete,
                              onReact: onReact,
                              onToggleReaction: onToggleReaction,
                              onForward: onForward,
                              onCopy: onCopy,
                            ),
                          );
                        },
                      ),
              ),
              if (_unseenMessageCount > 0)
                Positioned(
                  right: 16,
                  bottom: 14,
                  child: ChatEntrance(
                    key: const ValueKey<String>('new-messages-control'),
                    beginOffset: const Offset(0, 8),
                    child: ChatPressScale(
                      child: FilledButton.tonalIcon(
                        onPressed: () =>
                            _scheduleScrollToLatest(explicit: true),
                        icon: const Icon(Icons.keyboard_arrow_down),
                        label: Text(
                          _unseenMessageCount == 1
                              ? 'New message'
                              : '$_unseenMessageCount new messages',
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _MessageComposer(
          controller: messageController,
          isSending: isSending,
          isRecordingVoice: isRecordingVoice,
          voiceRecordingVisuals: voiceRecordingVisuals,
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

  Future<void> _showSafetyNumbers(BuildContext context) {
    return showChatDialog<void>(
      context: context,
      builder: (context) => _SafetyNumbersDialog(
        repository: repository,
        conversationId: thread.id,
      ),
    );
  }
}

class _SafetyNumbersDialog extends StatefulWidget {
  const _SafetyNumbersDialog({
    required this.repository,
    required this.conversationId,
  });

  final ChatRepository repository;
  final String conversationId;

  @override
  State<_SafetyNumbersDialog> createState() => _SafetyNumbersDialogState();
}

class _SafetyNumbersDialogState extends State<_SafetyNumbersDialog> {
  late Future<List<ConversationSafetyIdentity>> _identities;
  String? _verifyingUserId;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _identities = widget.repository.conversationSafetyIdentities(
      widget.conversationId,
    );
  }

  Future<void> _markVerified(ConversationSafetyIdentity identity) async {
    final confirmed = await showChatDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify this identity?'),
        content: const Text(
          'Only continue after comparing this safety number with the other person through a trusted channel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mark verified'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _verifyingUserId = identity.userId;
      _error = null;
    });
    try {
      await widget.repository.markSafetyIdentityVerified(identity);
      if (!mounted) return;
      setState(_reload);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() => _verifyingUserId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.shield_outlined),
          SizedBox(width: 10),
          Text('Safety numbers'),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: FutureBuilder<List<ConversationSafetyIdentity>>(
          future: _identities,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _SafetyNumbersError(
                message: 'Could not load safety numbers: ${snapshot.error}',
                onRetry: () => setState(_reload),
              );
            }

            final identities = snapshot.data ?? const [];
            if (identities.isEmpty) {
              return const Text("Keys aren't ready for this conversation yet.");
            }

            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 430),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Compare these fingerprints out of band. A changed verified identity blocks sending until you verify it again.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    for (final identity in identities) ...[
                      _SafetyNumberIdentityCard(
                        identity: identity,
                        isVerifying: _verifyingUserId == identity.userId,
                        onMarkVerified:
                            identity.isVerified && !identity.hasChanged
                            ? null
                            : () => _markVerified(identity),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Could not update verification: $_error',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _SafetyNumbersError extends StatelessWidget {
  const _SafetyNumbersError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}

class _SafetyNumberIdentityCard extends StatelessWidget {
  const _SafetyNumberIdentityCard({
    required this.identity,
    required this.isVerifying,
    required this.onMarkVerified,
  });

  final ConversationSafetyIdentity identity;
  final bool isVerifying;
  final VoidCallback? onMarkVerified;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = switch ((identity.hasChanged, identity.isVerified)) {
      (true, _) => 'Changed — sending blocked',
      (false, true) => 'Verified',
      (false, false) => 'Unverified',
    };
    final statusColor = identity.hasChanged
        ? theme.colorScheme.error
        : identity.isVerified
        ? const Color(0xFF148A5B)
        : theme.colorScheme.onSurfaceVariant;
    final fingerprint = identity.fingerprint
        .split(RegExp(r'\s+'))
        .where((group) => group.isNotEmpty)
        .join(' ');

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              identity.userId,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              status,
              style: theme.textTheme.labelLarge?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(
              fingerprint,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: 0.4,
              ),
            ),
            if (onMarkVerified != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: isVerifying ? null : onMarkVerified,
                icon: isVerifying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.verified_user_outlined),
                label: const Text('Mark verified'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _MessageAction { reply, react, edit, delete, forward, copy }

class _IncomingGroupCallOverlay extends StatelessWidget {
  const _IncomingGroupCallOverlay({
    required this.invite,
    required this.onJoin,
    required this.onDecline,
  });

  final GroupCallInvite invite;
  final VoidCallback onJoin;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: ChatSpringPop(
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
                        invite.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${invite.callerName} started a '
                        '${invite.isVideo ? 'video' : 'voice'} call',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FilledButton.tonal(
                            onPressed: onDecline,
                            child: const Text('Not now'),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: onJoin,
                            icon: const Icon(Icons.call),
                            label: const Text('Join'),
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
      ),
    );
  }
}

class _ActiveGroupCallOverlay extends StatelessWidget {
  const _ActiveGroupCallOverlay({
    required this.snapshot,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onLeave,
  });

  final GroupCallSnapshot snapshot;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final isVideo = snapshot.credentials.isVideo;
    return Positioned.fill(
      child: Material(
        color: const Color(0xFF0B1112),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        snapshot.credentials.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      '${snapshot.participants.length} connected',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: snapshot.participants.isEmpty
                    ? const Center(
                        child: Text(
                          'Waiting for others…',
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 360,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: 1.25,
                            ),
                        itemCount: snapshot.participants.length,
                        itemBuilder: (context, index) {
                          final participant = snapshot.participants[index];
                          return ChatSpringPop(
                            key: ValueKey<String>(
                              'participant-${participant.identity}',
                            ),
                            child: _GroupCallParticipantTile(
                              participant: participant,
                              showVideo: isVideo,
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _CallActionButton(
                      icon: _localIsMuted ? Icons.mic_off : Icons.mic,
                      label: _localIsMuted ? 'Unmute' : 'Mute',
                      onPressed: onToggleMute,
                    ),
                    if (isVideo) ...[
                      const SizedBox(width: 12),
                      _CallActionButton(
                        icon: _localCameraEnabled
                            ? Icons.videocam
                            : Icons.videocam_off,
                        label: _localCameraEnabled ? 'Camera' : 'Camera off',
                        onPressed: onToggleCamera,
                      ),
                      const SizedBox(width: 12),
                      _CallActionButton(
                        icon: Icons.cameraswitch,
                        label: 'Flip',
                        onPressed: onSwitchCamera,
                      ),
                    ],
                    const SizedBox(width: 12),
                    _CallActionButton(
                      icon: Icons.call_end,
                      label: 'Leave',
                      color: Colors.redAccent,
                      onPressed: onLeave,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _localIsMuted {
    final local = snapshot.participants.where((item) => item.isLocal).toList();
    return local.isNotEmpty && local.first.isMuted;
  }

  bool get _localCameraEnabled {
    final local = snapshot.participants.where((item) => item.isLocal).toList();
    return local.isNotEmpty && local.first.isCameraEnabled;
  }
}

class _GroupCallParticipantTile extends StatelessWidget {
  const _GroupCallParticipantTile({
    required this.participant,
    required this.showVideo,
  });

  final GroupCallParticipant participant;
  final bool showVideo;

  @override
  Widget build(BuildContext context) {
    final track = participant.videoTrack;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: const Color(0xFF182526),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showVideo && track != null)
              RepaintBoundary(child: VideoTrackRenderer(track))
            else
              Center(
                child: CircleAvatar(
                  radius: 34,
                  backgroundColor: Colors.white24,
                  child: Text(
                    _initials(participant.displayName),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      participant.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (participant.isMuted)
                    const Icon(Icons.mic_off, color: Colors.white, size: 18),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty);
    final value = parts.map((part) => part.characters.first).take(2).join();
    return value.isEmpty ? '?' : value.toUpperCase();
  }
}

class _CallActionButton extends StatelessWidget {
  const _CallActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ChatPressScale(
          child: IconButton.filled(
            tooltip: label,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              backgroundColor: color ?? Colors.white24,
              foregroundColor: Colors.white,
            ),
            icon: ChatStateSwitcher(
              child: Icon(icon, key: ValueKey<IconData>(icon)),
            ),
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }
}

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
            child: ChatSpringPop(
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
                        invite.isVideo
                            ? 'Incoming video call'
                            : 'Incoming call',
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
    final motionSpec = _callWidgetMotionSpec(context);
    return Positioned.fill(
      child: Material(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: isVideo
                  ? RepaintBoundary(
                      key: ValueKey<String>('remote-${snapshot.callId}'),
                      child: CallVideoView(
                        renderer: snapshot.remoteRenderer,
                        placeholderIcon: Icons.person,
                      ),
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
                    CallStatusLabel(snapshot: snapshot, motionSpec: motionSpec),
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
                      child: RepaintBoundary(
                        key: ValueKey<String>('local-${snapshot.callId}'),
                        child: CallVideoView(
                          renderer: snapshot.localRenderer,
                          mirror: true,
                          placeholderIcon: Icons.videocam_off,
                        ),
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
                motionSpec: motionSpec,
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

CallWidgetMotionSpec _callWidgetMotionSpec(BuildContext context) {
  final policy = context.chatMotion;
  return CallWidgetMotionSpec(
    statusTransitionDuration: policy.duration(policy.theme.standardDuration),
    controlTransitionDuration: policy.duration(policy.theme.microDuration),
    pressScale: policy.scale(policy.theme.pressScale),
    reducedMotion: policy.reduceMotion,
  );
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

class _AnimatedMessageEntry extends StatefulWidget {
  const _AnimatedMessageEntry({
    super.key,
    required this.animate,
    required this.isMine,
    required this.onComplete,
    required this.child,
  });

  final bool animate;
  final bool isMine;
  final VoidCallback onComplete;
  final Widget child;

  @override
  State<_AnimatedMessageEntry> createState() => _AnimatedMessageEntryState();
}

class _AnimatedMessageEntryState extends State<_AnimatedMessageEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _settleTimer;
  bool _didResolveDependencies = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this, value: 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didResolveDependencies) return;
    _didResolveDependencies = true;
    if (widget.animate) _start();
  }

  @override
  void didUpdateWidget(covariant _AnimatedMessageEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !oldWidget.animate) _start();
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    final policy = context.chatMotion;
    _settleTimer?.cancel();
    if (policy.reduceMotion) {
      _controller.value = 1;
      scheduleMicrotask(widget.onComplete);
      return;
    }

    _controller.value = policy.theme.entryScale;
    unawaited(
      _controller.animateWith(
        SpringSimulation(policy.theme.spring, policy.theme.entryScale, 1, 0),
      ),
    );
    _settleTimer = Timer(policy.theme.maximumDuration, () {
      if (!mounted) return;
      _controller
        ..stop()
        ..value = 1;
      widget.onComplete();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatMotion.theme;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          final scale = _controller.value
              .clamp(theme.entryScale, theme.maximumOvershoot)
              .toDouble();
          final progress = ((scale - theme.entryScale) / (1 - theme.entryScale))
              .clamp(0.0, 1.0)
              .toDouble();
          final beginOffset = Offset(
            widget.isMine ? theme.standardOffset : -theme.standardOffset,
            theme.standardOffset,
          );
          return Opacity(
            opacity: progress,
            child: Transform.translate(
              offset: Offset.lerp(beginOffset, Offset.zero, progress)!,
              child: Transform.scale(
                alignment: widget.isMine
                    ? Alignment.bottomRight
                    : Alignment.bottomLeft,
                scale: scale,
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    super.key,
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
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  bool _actionsOpen = false;

  ChatMessage get message => widget.message;
  ChatRepository get repository => widget.repository;
  Future<void> Function() get onRetry => widget.onRetry;
  ValueChanged<ChatMessage> get onReply => widget.onReply;
  ValueChanged<ChatMessage> get onEdit => widget.onEdit;
  Future<void> Function(ChatMessage) get onDelete => widget.onDelete;
  Future<void> Function(ChatMessage) get onReact => widget.onReact;
  Future<void> Function(ChatMessage, String) get onToggleReaction =>
      widget.onToggleReaction;
  Future<void> Function(ChatMessage) get onForward => widget.onForward;
  Future<void> Function(ChatMessage) get onCopy => widget.onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (message.messageType == ChatMessageType.call) {
      return _CallEventBubble(message: message);
    }

    final isMine = message.isMine;
    final media = message.media;
    final encryptionUnavailable =
        message.isLocked || message.hasInvalidEncryption;
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
            if (message.encryptionState == ChatMessageEncryptionState.legacy &&
                !message.isDeleted)
              _MessageFlag(
                icon: Icons.history_outlined,
                label: 'Legacy (not end-to-end encrypted)',
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
            else if (encryptionUnavailable)
              _EncryptedMessageUnavailable(
                isInvalid: message.hasInvalidEncryption,
                color: textColor,
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
                onLongPress: message.isDeleted || encryptionUnavailable
                    ? null
                    : () => _showActions(context),
                onSecondaryTapDown: message.isDeleted || encryptionUnavailable
                    ? null
                    : (_) => _showActions(context),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: _actionsOpen ? -4 : 0),
                  duration: context.chatMotion.duration(
                    context.chatMotion.theme.standardDuration,
                  ),
                  curve: Curves.easeOutCubic,
                  child: bubble,
                  builder: (context, offset, child) => Transform.translate(
                    offset: Offset(0, offset),
                    child: child,
                  ),
                ),
              ),
              if (message.reactions.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: message.reactions
                      .map(
                        (reaction) => ChatSpringPop(
                          key: ValueKey<String>(
                            '${message.id}:${reaction.emoji}',
                          ),
                          child: ActionChip(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: reaction.reactedByMe
                                ? theme.colorScheme.primaryContainer
                                : theme.colorScheme.surfaceContainerHighest,
                            label: ChatStateSwitcher(
                              child: Text(
                                '${reaction.emoji} ${reaction.count}',
                                key: ValueKey<int>(reaction.count),
                              ),
                            ),
                            onPressed: encryptionUnavailable
                                ? null
                                : () {
                                    unawaited(ChatHaptics.selection());
                                    unawaited(
                                      onToggleReaction(message, reaction.emoji),
                                    );
                                  },
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
    if (message.isLocked || message.hasInvalidEncryption) {
      return;
    }

    final renderBox = context.findRenderObject() as RenderBox?;
    final messageRect = renderBox != null
        ? renderBox.localToGlobal(Offset.zero) & renderBox.size
        : Rect.fromLTWH(
            0,
            MediaQuery.sizeOf(context).height / 2,
            MediaQuery.sizeOf(context).width,
            80,
          );

    setState(() {
      _actionsOpen = true;
    });

    ChatMessageOverlayResult? result;
    try {
      result = await Navigator.of(context).push<ChatMessageOverlayResult>(
        ChatMessageOverlayRoute(
          context: context,
          message: message,
          messageRect: messageRect,
          isMine: message.isMine,
          messageWidgetBuilder: (ctx) => _buildBubbleContent(ctx),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _actionsOpen = false;
        });
      }
    }

    if (result == null) return;

    if (result.reactionEmoji case final emoji?) {
      await onToggleReaction(message, emoji);
      return;
    }

    switch (result.action) {
      case ChatOverlayActionKind.reply:
        onReply(message);
        return;
      case ChatOverlayActionKind.react:
        await onReact(message);
        return;
      case ChatOverlayActionKind.edit:
        onEdit(message);
        return;
      case ChatOverlayActionKind.delete:
        await onDelete(message);
        return;
      case ChatOverlayActionKind.forward:
        await onForward(message);
        return;
      case ChatOverlayActionKind.copy:
        await onCopy(message);
        return;
      case null:
        return;
    }
  }

  Widget _buildBubbleContent(BuildContext context) {
    final theme = Theme.of(context);
    final isMine = message.isMine;
    final media = message.media;
    final encryptionUnavailable =
        message.isLocked || message.hasInvalidEncryption;
    final hasText = message.body.trim().isNotEmpty;
    final bubbleColor = isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isMine
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return DecoratedBox(
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
            else if (encryptionUnavailable)
              _EncryptedMessageUnavailable(
                isInvalid: message.hasInvalidEncryption,
                color: textColor,
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
                  Text(
                    _formatTime(message.createdAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: textColor.withValues(alpha: 0.72),
                    ),
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

class _EncryptedMessageUnavailable extends StatelessWidget {
  const _EncryptedMessageUnavailable({
    required this.isInvalid,
    required this.color,
  });

  final bool isInvalid;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isInvalid ? Icons.gpp_bad_outlined : Icons.lock_outline,
          size: 18,
          color: color.withValues(alpha: 0.82),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            isInvalid
                ? 'Could not verify this encrypted message.'
                : 'Encrypted message unavailable on this device.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: color.withValues(alpha: 0.82),
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
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
    final text = switch (message.callEvent?.trim().toLowerCase()) {
      'started' => 'Call started',
      'ended' => 'Call ended',
      'failed' => 'Call failed',
      'rejected' => 'Call declined',
      _ => 'Call updated',
    };

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

class _MotionHero extends StatelessWidget {
  const _MotionHero({required this.tag, required this.child});

  final Object tag;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return HeroMode(
      enabled: context.chatMotion.heroEnabled,
      child: Hero(tag: tag, child: child),
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
          ChatMediaPageRoute<void>(
            context: context,
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
          _MotionHero(
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
  const _VoiceRecordingCard({required this.visuals});

  final _VoiceRecordingVisualController visuals;

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
          ValueListenableBuilder<Duration>(
            valueListenable: visuals.elapsed,
            builder: (context, elapsed, child) => Semantics(
              label: 'Recording ${_spokenDuration(elapsed)}',
              child: ExcludeSemantics(
                child: Text(
                  _formatDuration(elapsed),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _LiveVoiceWaveform(
              visuals: visuals,
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

class _LiveVoiceWaveform extends StatefulWidget {
  const _LiveVoiceWaveform({
    required this.visuals,
    required this.height,
    required this.barColor,
    required this.trackColor,
  });

  final _VoiceRecordingVisualController visuals;
  final double height;
  final Color barColor;
  final Color trackColor;

  @override
  State<_LiveVoiceWaveform> createState() => _LiveVoiceWaveformState();
}

class _LiveVoiceWaveformState extends State<_LiveVoiceWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  List<double> _fromLevels = const [];
  List<double> _toLevels = const [];

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(vsync: this, value: 1);
    _toLevels = List<double>.of(widget.visuals.levels);
    _fromLevels = _toLevels;
    widget.visuals.addListener(_handleLevelsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final policy = context.chatMotion;
    _animation.duration = policy.duration(const Duration(milliseconds: 120));
    if (policy.reduceMotion) _animation.value = 1;
  }

  @override
  void didUpdateWidget(covariant _LiveVoiceWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visuals != widget.visuals) {
      oldWidget.visuals.removeListener(_handleLevelsChanged);
      widget.visuals.addListener(_handleLevelsChanged);
      _fromLevels = const [];
      _toLevels = List<double>.of(widget.visuals.levels);
      _animation.value = 1;
    }
  }

  @override
  void dispose() {
    widget.visuals.removeListener(_handleLevelsChanged);
    _animation.dispose();
    super.dispose();
  }

  void _handleLevelsChanged() {
    if (!mounted) return;
    final current = _interpolateWaveformLevels(
      _fromLevels,
      _toLevels,
      Curves.easeOutCubic.transform(_animation.value),
    );
    setState(() {
      _fromLevels = current;
      _toLevels = List<double>.of(widget.visuals.levels);
    });
    if (context.chatMotion.reduceMotion) {
      _animation.value = 1;
    } else {
      unawaited(_animation.forward(from: 0));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: CustomPaint(
        painter: _LiveVoiceWaveformPainter(
          animation: _animation,
          fromLevels: _fromLevels,
          toLevels: _toLevels,
          barColor: widget.barColor,
          trackColor: widget.trackColor,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _LiveVoiceWaveformPainter extends CustomPainter {
  _LiveVoiceWaveformPainter({
    required this.animation,
    required this.fromLevels,
    required this.toLevels,
    required this.barColor,
    required this.trackColor,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final List<double> fromLevels;
  final List<double> toLevels;
  final Color barColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    _paintVoiceWaveform(
      canvas: canvas,
      size: size,
      levels: _waveformLevels(
        _interpolateWaveformLevels(
          fromLevels,
          toLevels,
          Curves.easeOutCubic.transform(animation.value),
        ),
      ),
      barColor: barColor,
      trackColor: trackColor,
    );
  }

  @override
  bool shouldRepaint(covariant _LiveVoiceWaveformPainter oldDelegate) {
    return oldDelegate.animation != animation ||
        !listEquals(oldDelegate.fromLevels, fromLevels) ||
        !listEquals(oldDelegate.toLevels, toLevels) ||
        oldDelegate.barColor != barColor ||
        oldDelegate.trackColor != trackColor;
  }
}

List<double> _interpolateWaveformLevels(
  List<double> from,
  List<double> to,
  double progress,
) {
  if (from.isEmpty && to.isEmpty) return const [];
  final count = math.max(from.length, to.length);
  double sample(List<double> values, int index) {
    if (values.isEmpty) return 0.08;
    if (count <= 1 || values.length == 1) return values.first;
    final sourceIndex = (index * (values.length - 1) / (count - 1)).round();
    return values[sourceIndex];
  }

  return List<double>.generate(count, (index) {
    final start = sample(from, index);
    final end = sample(to, index);
    return start + (end - start) * progress;
  }, growable: false);
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

    if (media.isEncrypted) {
      final bytes = await repository.mediaBytes(media);
      await player.setAudioSource(_BytesAudioSource(bytes, media.mimeType));
      _loadedSourceKey = sourceKey;
      return;
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
    _paintVoiceWaveform(
      canvas: canvas,
      size: size,
      levels: levels,
      barColor: barColor,
      trackColor: trackColor,
    );
  }

  @override
  bool shouldRepaint(covariant _VoiceWaveformPainter oldDelegate) {
    return !listEquals(oldDelegate.levels, levels) ||
        oldDelegate.barColor != barColor ||
        oldDelegate.trackColor != trackColor;
  }
}

void _paintVoiceWaveform({
  required Canvas canvas,
  required Size size,
  required List<double> levels,
  required Color barColor,
  required Color trackColor,
}) {
  if (size.width <= 0 || size.height <= 0 || levels.isEmpty) return;

  final preferredGap = size.width < 180 ? 2.0 : 3.0;
  final maximumBars = math.max(1, (size.width / (2 + preferredGap)).floor());
  final visibleLevels = levels.length <= maximumBars
      ? levels
      : _compactVoiceLevels(levels, target: maximumBars);
  final count = visibleLevels.length;
  final gap = count == 1
      ? 0.0
      : math.min(
          preferredGap,
          math.max(0.0, (size.width - count * 2) / (count - 1)),
        );
  final barWidth = math.max(1.0, (size.width - gap * (count - 1)) / count);
  final radius = Radius.circular(barWidth / 2);
  final centerY = size.height / 2;
  final trackPaint = Paint()..color = trackColor;
  final barPaint = Paint()..color = barColor;

  for (var index = 0; index < count; index += 1) {
    final left = index * (barWidth + gap);
    final level = visibleLevels[index].clamp(0.0, 1.0).toDouble();
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
  Future<Uint8List>? _decryptedBytes;

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
    _decryptedBytes =
        widget.media.isEncrypted && widget.media.localBytes == null
        ? widget.repository.mediaBytes(widget.media)
        : null;
    _signedUrl = widget.media.localBytes == null && !widget.media.isEncrypted
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

    if (widget.media.isEncrypted) {
      return FutureBuilder<Uint8List>(
        future: _decryptedBytes,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) {
            if (snapshot.hasError) {
              return ColoredBox(
                color: Colors.black.withValues(alpha: 0.08),
                child: const Center(child: Icon(Icons.broken_image_outlined)),
              );
            }
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
          return Image.memory(
            bytes,
            fit: widget.fit,
            gaplessPlayback: true,
            filterQuality: FilterQuality.high,
          );
        },
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
                child: _MotionHero(
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
    late final String label;
    late final Widget icon;

    if (message.sendState == ChatMessageSendState.failed) {
      label = 'Failed';
      icon = IconButton(
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
    } else if (message.sendState == ChatMessageSendState.sending) {
      label = 'Sending';
      icon = Icon(
        Icons.sync,
        key: const Key('message-status-sending'),
        size: 15,
        color: fallbackColor,
      );
    } else if (message.sendState == ChatMessageSendState.pending) {
      label = 'Pending';
      icon = Icon(
        Icons.schedule,
        key: const Key('message-status-pending'),
        size: 15,
        color: fallbackColor,
      );
    } else if (message.isRead) {
      label = 'Read';
      icon = const Icon(
        Icons.done_all,
        key: Key('message-status-read'),
        size: 15,
        color: Color(0xFF53BDEB),
      );
    } else if (message.isDelivered) {
      label = 'Delivered';
      icon = Icon(
        Icons.done_all,
        key: const Key('message-status-delivered'),
        size: 15,
        color: fallbackColor,
      );
    } else {
      label = 'Sent';
      icon = Icon(
        Icons.done,
        key: const Key('message-status-sent'),
        size: 15,
        color: fallbackColor,
      );
    }

    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: ChatStateSwitcher(offset: const Offset(0, 3), child: icon),
      ),
    );
  }
}

class _MessageComposer extends StatefulWidget {
  const _MessageComposer({
    required this.controller,
    required this.isSending,
    required this.isRecordingVoice,
    required this.voiceRecordingVisuals,
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
  final _VoiceRecordingVisualController voiceRecordingVisuals;
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
  State<_MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<_MessageComposer> {
  final LayerLink _attachmentLink = LayerLink();
  final GlobalKey _attachmentAnchorKey = GlobalKey();
  final FocusNode _attachmentFocus = FocusNode(debugLabel: 'attachment');
  final List<FocusNode> _attachmentActionFocus = List.generate(
    ChatMediaSource.values.length,
    (index) => FocusNode(debugLabel: 'attachment-action-$index'),
  );
  OverlayEntry? _attachmentOverlay;
  bool _attachmentMenuOpen = false;
  bool _attachmentMenuAbove = true;

  bool get _attachmentEnabled => !widget.isSending && !widget.isRecordingVoice;

  @override
  void didUpdateWidget(covariant _MessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_attachmentEnabled && _attachmentMenuOpen) {
      _closeAttachmentMenu();
    }
  }

  @override
  void dispose() {
    _attachmentOverlay?.remove();
    _attachmentFocus.dispose();
    for (final focusNode in _attachmentActionFocus) {
      focusNode.dispose();
    }
    super.dispose();
  }

  void _toggleAttachmentMenu() {
    if (!_attachmentEnabled) return;
    if (_attachmentMenuOpen) {
      _closeAttachmentMenu();
      return;
    }

    final anchorContext = _attachmentAnchorKey.currentContext;
    final anchorBox = anchorContext?.findRenderObject() as RenderBox?;
    final anchorTop = anchorBox?.localToGlobal(Offset.zero).dy ?? 0;
    _attachmentMenuAbove = anchorTop > MediaQuery.sizeOf(context).height * 0.42;
    _attachmentOverlay = OverlayEntry(builder: _buildAttachmentOverlay);
    Overlay.of(context, rootOverlay: true).insert(_attachmentOverlay!);
    setState(() {
      _attachmentMenuOpen = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _attachmentMenuOpen) {
        _attachmentActionFocus.first.requestFocus();
      }
    });
  }

  void _closeAttachmentMenu() {
    _attachmentOverlay?.remove();
    _attachmentOverlay = null;
    if (mounted && _attachmentMenuOpen) {
      setState(() {
        _attachmentMenuOpen = false;
      });
      _attachmentFocus.requestFocus();
    }
  }

  void _selectAttachment(ChatMediaSource source) {
    _closeAttachmentMenu();
    unawaited(ChatHaptics.selection());
    widget.onAttachMedia(source);
  }

  Widget _buildAttachmentOverlay(BuildContext overlayContext) {
    final actions = <(ChatMediaSource, IconData, String)>[
      (ChatMediaSource.gallery, Icons.photo_library_outlined, 'Photo or GIF'),
      (ChatMediaSource.giphy, Icons.gif_box_outlined, 'GIF'),
      (ChatMediaSource.camera, Icons.photo_camera_outlined, 'Camera'),
    ];
    final beginOffset = _attachmentMenuAbove
        ? const Offset(0, 8)
        : const Offset(0, -8);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _closeAttachmentMenu,
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeAttachmentMenu,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          CompositedTransformFollower(
            link: _attachmentLink,
            showWhenUnlinked: false,
            targetAnchor: _attachmentMenuAbove
                ? Alignment.topLeft
                : Alignment.bottomLeft,
            followerAnchor: _attachmentMenuAbove
                ? Alignment.bottomLeft
                : Alignment.topLeft,
            offset: Offset(0, _attachmentMenuAbove ? -8 : 8),
            child: FocusTraversalGroup(
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                color: Theme.of(overlayContext).colorScheme.surface,
                child: IntrinsicWidth(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var index = 0; index < actions.length; index++)
                        ChatStagger(
                          index: index,
                          beginOffset: beginOffset,
                          child: ListTile(
                            key: Key(
                              'attachment-option-${actions[index].$1.name}',
                            ),
                            focusNode: _attachmentActionFocus[index],
                            leading: Icon(actions[index].$2),
                            title: Text(actions[index].$3),
                            onTap: () => _selectAttachment(actions[index].$1),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policy = context.chatMotion;
    final composerAction = widget.editingMessage ?? widget.replyingTo;

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
            ChatSizeFade(
              child: composerAction == null
                  ? null
                  : Padding(
                      key: ValueKey<String>(
                        'composer-action-${composerAction.id}',
                      ),
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _ComposerActionCard(
                        message: composerAction,
                        isEditing: widget.editingMessage != null,
                        onCancel: widget.onCancelComposerAction,
                      ),
                    ),
            ),
            ChatSizeFade(
              child: widget.stagedAttachment == null
                  ? null
                  : Padding(
                      key: ValueKey<String>(
                        'staged-${widget.stagedAttachment!.conversationId}-${widget.stagedAttachment!.status.name}',
                      ),
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _StagedAttachmentCard(
                        attachment: widget.stagedAttachment!,
                        onRemove: widget.onRemoveAttachment,
                        onRetry: widget.onRetryAttachment,
                      ),
                    ),
            ),
            ChatSizeFade(
              child: widget.isRecordingVoice
                  ? Padding(
                      key: const ValueKey<String>('recording-visible'),
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _VoiceRecordingCard(
                        visuals: widget.voiceRecordingVisuals,
                      ),
                    )
                  : null,
            ),
            Row(
              children: [
                CompositedTransformTarget(
                  link: _attachmentLink,
                  child: ChatPressScale(
                    enabled: _attachmentEnabled,
                    child: IconButton(
                      key: _attachmentAnchorKey,
                      focusNode: _attachmentFocus,
                      tooltip: _attachmentMenuOpen
                          ? 'Close attachments'
                          : 'Attach',
                      onPressed: _attachmentEnabled
                          ? _toggleAttachmentMenu
                          : null,
                      icon: AnimatedRotation(
                        turns: _attachmentMenuOpen ? 0.125 : 0,
                        duration: policy.duration(
                          policy.theme.standardDuration,
                        ),
                        curve: Curves.easeOutCubic,
                        child: const Icon(Icons.add),
                      ),
                    ),
                  ),
                ),
                ChatPressScale(
                  enabled: !widget.isSending,
                  child: IconButton(
                    tooltip: widget.isRecordingVoice
                        ? 'Stop voice message'
                        : 'Record voice message',
                    onPressed: widget.isSending
                        ? null
                        : widget.onToggleVoiceRecording,
                    icon: ChatStateSwitcher(
                      child: Icon(
                        widget.isRecordingVoice
                            ? Icons.stop
                            : Icons.mic_none_outlined,
                        key: ValueKey<bool>(widget.isRecordingVoice),
                      ),
                    ),
                    color: widget.isRecordingVoice
                        ? theme.colorScheme.error
                        : null,
                  ),
                ),
                Expanded(
                  child: TextField(
                    key: const Key('message-composer'),
                    controller: widget.controller,
                    enabled: !widget.isRecordingVoice,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    onChanged: widget.onChanged,
                    decoration: const InputDecoration(hintText: 'Message'),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: widget.controller,
                  builder: (context, _, child) {
                    final uploadReady =
                        widget.stagedAttachment == null ||
                        widget.stagedAttachment!.canSend;
                    final failed =
                        widget.stagedAttachment?.status ==
                        _AttachmentUploadState.failed;
                    final enabled =
                        !widget.isSending &&
                        !widget.isRecordingVoice &&
                        uploadReady &&
                        !failed;
                    return ChatPressScale(
                      enabled: enabled,
                      child: FilledButton(
                        onPressed: enabled ? widget.onSend : null,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          padding: EdgeInsets.zero,
                        ),
                        child: ChatStateSwitcher(
                          child: widget.isSending
                              ? const SizedBox(
                                  key: ValueKey<String>('composer-sending'),
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.send,
                                  key: ValueKey<String>('composer-send'),
                                ),
                        ),
                      ),
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
        Positioned(
          right: -2,
          bottom: -2,
          child: AnimatedScale(
            duration: context.chatMotion.duration(
              context.chatMotion.theme.standardDuration,
            ),
            curve: Curves.easeOutCubic,
            scale: thread.isOnline || thread.isTyping ? 1 : 0,
            child: AnimatedOpacity(
              duration: context.chatMotion.duration(
                context.chatMotion.theme.microDuration,
              ),
              opacity: thread.isOnline || thread.isTyping ? 1 : 0,
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
          ),
        ),
      ],
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final label = count > 99 ? '99+' : '$count';
    return ChatSpringPop(
      child: Container(
        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: colorScheme.error,
          borderRadius: BorderRadius.circular(11),
        ),
        child: ChatStateSwitcher(
          child: Text(
            label,
            key: ValueKey<String>(label),
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onError,
              fontWeight: FontWeight.w800,
            ),
          ),
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

String _spokenDuration(Duration duration) {
  final totalSeconds = math.max(0, duration.inSeconds);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (minutes == 0) return '$seconds seconds';
  if (seconds == 0) return '$minutes minutes';
  return '$minutes minutes $seconds seconds';
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

String _groupAvatarLabel(String name) {
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
