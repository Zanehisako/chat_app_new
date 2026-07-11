import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:realtime_calls/realtime_calls.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseCallSignaling implements CallSignaling {
  SupabaseCallSignaling({required this.client});

  static const _directTurnUrls = String.fromEnvironment(
    'CALL_TURN_URLS',
    defaultValue: '',
  );
  static const _directTurnUsername = String.fromEnvironment(
    'CALL_TURN_USERNAME',
    defaultValue: '',
  );
  static const _directTurnCredential = String.fromEnvironment(
    'CALL_TURN_CREDENTIAL',
    defaultValue: '',
  );
  static const _stunUrls = String.fromEnvironment(
    'CALL_STUN_URLS',
    defaultValue: '',
  );
  static const _allowPublicStunFallback = bool.fromEnvironment(
    'CALL_ALLOW_PUBLIC_STUN_FALLBACK',
    defaultValue: true,
  );

  final SupabaseClient client;

  @override
  String get localUserId {
    final userId =
        client.auth.currentUser?.id ?? client.auth.currentSession?.user.id;
    if (userId == null || userId.isEmpty) {
      throw const CallException('Sign in before starting calls.');
    }
    return userId;
  }

  @override
  Future<List<IceServer>> fetchIceServers() async {
    final configured = _configuredIceServers();
    if (configured.isNotEmpty) {
      return configured;
    }

    try {
      final response = await client.functions.invoke('turn-credentials');
      final data = response.data;
      final iceServers = _iceServersFromPayload(data);
      if (iceServers.isNotEmpty) {
        return iceServers;
      }
    } catch (error) {
      if (!_allowPublicStunFallback) {
        throw CallException(
          'Could not load TURN credentials.',
          details:
              'Deploy supabase/functions/turn-credentials or pass '
              'CALL_TURN_URLS/CALL_TURN_USERNAME/CALL_TURN_CREDENTIAL. '
              'Supabase Edge Function error: $error',
        );
      }
    }

    if (_allowPublicStunFallback) {
      return const [
        IceServer(urls: ['stun:stun.l.google.com:19302']),
      ];
    }

    throw const CallException(
      'Missing TURN configuration.',
      details:
          'Calls need self-hosted TURN for production internet reliability.',
    );
  }

  @override
  Future<CallInvite> createInvite({
    required String conversationId,
    required String calleeId,
    required String callerName,
    required bool isVideo,
    required DateTime expiresAt,
  }) async {
    final row = await client
        .from('call_sessions')
        .insert({
          'conversation_id': conversationId,
          'caller_id': localUserId,
          'callee_id': calleeId,
          'caller_name': callerName,
          'is_video': isVideo,
          'status': 'ringing',
          'expires_at': expiresAt.toUtc().toIso8601String(),
        })
        .select()
        .single();

    return _inviteFromRow(row);
  }

  @override
  Stream<CallInvite> watchIncomingInvites() {
    final userId = localUserId;
    late final StreamController<CallInvite> controller;
    StreamSubscription<List<Map<String, dynamic>>>? realtimeSubscription;
    Timer? realtimeRetryTimer;
    Timer? pollingTimer;
    var isFetching = false;
    var isClosing = false;
    var realtimeAttempt = 0;
    var pollFailureCount = 0;
    final emittedInviteIds = <String>{};

    void emitInvites(List<CallInvite> invites) {
      invites.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final invite in invites) {
        if (invite.isExpired || !emittedInviteIds.add(invite.id)) {
          continue;
        }
        if (!controller.isClosed) {
          controller.add(invite);
        }
      }
    }

    Future<void> fetchInvites() async {
      if (isFetching || controller.isClosed) {
        return;
      }
      isFetching = true;
      try {
        emitInvites(await _fetchIncomingInvites(userId));
        if (pollFailureCount > 0) {
          debugPrint('[Incoming calls] Polling connection recovered.');
        }
        pollFailureCount = 0;
      } catch (error) {
        if (pollFailureCount == 0) {
          debugPrint(
            '[Incoming calls] Polling unavailable '
            '(${error.runtimeType}); retrying.',
          );
        }
        pollFailureCount += 1;
      } finally {
        isFetching = false;
      }
    }

    late void Function() startRealtime;

    void scheduleRealtimeRetry(Object? error) {
      if (isClosing || controller.isClosed || realtimeRetryTimer != null) {
        return;
      }
      final delaySeconds = realtimeAttempt < 5 ? 1 << realtimeAttempt : 30;
      realtimeAttempt += 1;
      final errorLabel = error == null ? 'closed' : error.runtimeType;
      debugPrint(
        '[Incoming calls] Realtime $errorLabel; retrying in '
        '${delaySeconds}s while polling remains active.',
      );
      realtimeRetryTimer = Timer(Duration(seconds: delaySeconds), () {
        realtimeRetryTimer = null;
        startRealtime();
      });
    }

    startRealtime = () {
      if (isClosing || controller.isClosed || realtimeSubscription != null) {
        return;
      }
      try {
        late final StreamSubscription<List<Map<String, dynamic>>> subscription;
        subscription = client
            .from('call_sessions')
            .stream(primaryKey: ['id'])
            .eq('callee_id', userId)
            .listen(
              (rows) {
                if (realtimeAttempt > 0) {
                  debugPrint(
                    '[Incoming calls] Realtime subscription recovered.',
                  );
                }
                realtimeAttempt = 0;
                emitInvites(
                  rows
                      .where((row) => row['status']?.toString() == 'ringing')
                      .map(_inviteFromRow)
                      .where((invite) => !invite.isExpired)
                      .toList(),
                );
              },
              onError: (Object error, StackTrace _) {
                if (identical(realtimeSubscription, subscription)) {
                  realtimeSubscription = null;
                }
                scheduleRealtimeRetry(error);
              },
              onDone: () {
                if (identical(realtimeSubscription, subscription)) {
                  realtimeSubscription = null;
                }
                scheduleRealtimeRetry(null);
              },
              cancelOnError: true,
            );
        realtimeSubscription = subscription;
      } catch (error) {
        realtimeSubscription = null;
        scheduleRealtimeRetry(error);
      }
    };

    controller = StreamController<CallInvite>(
      onListen: () {
        startRealtime();
        unawaited(fetchInvites());
        pollingTimer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(fetchInvites()),
        );
      },
      onCancel: () async {
        isClosing = true;
        realtimeRetryTimer?.cancel();
        pollingTimer?.cancel();
        await realtimeSubscription?.cancel();
        realtimeSubscription = null;
      },
    );

    return controller.stream;
  }

  Future<List<CallInvite>> _fetchIncomingInvites(String userId) async {
    final rows = await client
        .from('call_sessions')
        .select()
        .eq('callee_id', userId)
        .eq('status', 'ringing')
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at');

    return List<Map<String, dynamic>>.from(
      rows,
    ).map(_inviteFromRow).where((invite) => !invite.isExpired).toList();
  }

  @override
  Stream<CallSignal> watchSignals(String callId) {
    return client
        .from('call_signal_events')
        .stream(primaryKey: ['id'])
        .eq('call_id', callId)
        .order('created_at')
        .map(
          (rows) => rows
              .map(_signalFromRow)
              .where((signal) => signal.senderId != localUserId)
              .toList(),
        )
        .expand((signals) => signals);
  }

  @override
  Future<void> acceptInvite(String callId) async {
    await _updateCall(callId, {
      'status': 'accepted',
      'accepted_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> rejectInvite(String callId) async {
    await sendSignal(
      CallSignal(
        callId: callId,
        senderId: localUserId,
        type: CallSignalType.reject,
      ),
    );
    await _updateCall(callId, {
      'status': 'rejected',
      'ended_by_id': localUserId,
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> endCall(String callId) async {
    await sendSignal(
      CallSignal(
        callId: callId,
        senderId: localUserId,
        type: CallSignalType.hangup,
      ),
    );
    await _updateCall(callId, {
      'status': 'ended',
      'ended_by_id': localUserId,
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> failCall(String callId, String reason) async {
    await _updateCall(callId, {
      'status': 'failed',
      'failure_reason': reason,
      'ended_by_id': localUserId,
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> sendSignal(CallSignal signal) async {
    await client.from('call_signal_events').insert({
      'call_id': signal.callId,
      'sender_id': localUserId,
      'event_type': signal.type.value,
      'sdp': signal.sdp,
      'sdp_type': signal.sdpType,
      'candidate': signal.candidate,
      'sdp_mid': signal.sdpMid,
      'sdp_m_line_index': signal.sdpMLineIndex,
    });
  }

  Future<void> _updateCall(String callId, Map<String, dynamic> values) async {
    await client.from('call_sessions').update(values).eq('id', callId);
  }

  List<IceServer> _configuredIceServers() {
    final servers = <IceServer>[];
    final stunUrls = _splitUrls(_stunUrls);
    if (stunUrls.isNotEmpty) {
      servers.add(IceServer(urls: stunUrls));
    }

    final turnUrls = _splitUrls(_directTurnUrls);
    if (turnUrls.isNotEmpty) {
      servers.add(
        IceServer(
          urls: turnUrls,
          username: _directTurnUsername,
          credential: _directTurnCredential,
        ),
      );
    }
    return servers;
  }
}

List<String> _splitUrls(String value) {
  return value
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

List<IceServer> _iceServersFromPayload(Object? data) {
  final payload = data is String ? json.decode(data) : data;
  if (payload is! Map) {
    return const [];
  }
  final servers = payload['iceServers'];
  if (servers is! List) {
    return const [];
  }
  return servers
      .whereType<Map>()
      .map((server) => IceServer.fromJson(Map<String, dynamic>.from(server)))
      .toList();
}

CallInvite _inviteFromRow(Map<String, dynamic> row) {
  return CallInvite(
    id: row['id']?.toString() ?? '',
    conversationId: row['conversation_id']?.toString() ?? '',
    callerId: row['caller_id']?.toString() ?? '',
    calleeId: row['callee_id']?.toString() ?? '',
    callerName: row['caller_name']?.toString() ?? 'Incoming call',
    isVideo: row['is_video'] == true,
    createdAt: _readTimestamp(row['created_at']),
    expiresAt: _readTimestamp(row['expires_at']),
  );
}

CallSignal _signalFromRow(Map<String, dynamic> row) {
  return CallSignal(
    id: row['id']?.toString(),
    callId: row['call_id']?.toString() ?? '',
    senderId: row['sender_id']?.toString() ?? '',
    type: CallSignalType.fromValue(row['event_type']?.toString() ?? ''),
    sdp: row['sdp']?.toString(),
    sdpType: row['sdp_type']?.toString(),
    candidate: row['candidate']?.toString(),
    sdpMid: row['sdp_mid']?.toString(),
    sdpMLineIndex: row['sdp_m_line_index'] is int
        ? row['sdp_m_line_index'] as int
        : int.tryParse(row['sdp_m_line_index']?.toString() ?? ''),
    createdAt: _readTimestamp(row['created_at']),
  );
}

DateTime _readTimestamp(Object? value) {
  if (value is DateTime) {
    return value.toUtc();
  }
  return DateTime.tryParse(value?.toString() ?? '')?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
