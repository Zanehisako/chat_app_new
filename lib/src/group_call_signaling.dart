import 'dart:async';

import 'package:realtime_calls/realtime_calls.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class GroupCallInvite {
  const GroupCallInvite({
    required this.callId,
    required this.conversationId,
    required this.title,
    required this.callerName,
    required this.isVideo,
  });

  final String callId;
  final String conversationId;
  final String title;
  final String callerName;
  final bool isVideo;
}

class GroupCallSessionSummary {
  const GroupCallSessionSummary({
    required this.callId,
    required this.conversationId,
    required this.title,
    required this.isVideo,
    required this.participantCount,
  });

  final String callId;
  final String conversationId;
  final String title;
  final bool isVideo;
  final int participantCount;
}

class SupabaseGroupCallGateway implements GroupCallGateway {
  SupabaseGroupCallGateway({
    required this.client,
    Future<dynamic> Function(String function, Map<String, dynamic> params)?
    rpcInvoker,
  }) : _rpcInvoker =
           rpcInvoker ??
           ((function, params) => client.rpc(function, params: params));

  final SupabaseClient client;
  final Future<dynamic> Function(String function, Map<String, dynamic> params)
  _rpcInvoker;

  String get _userId {
    final id = client.auth.currentUser?.id;
    if (id == null || id.isEmpty) {
      throw const CallException('Sign in before joining group calls.');
    }
    return id;
  }

  @override
  Future<GroupCallCredentials> start({
    required String conversationId,
    required bool isVideo,
  }) => _invokeToken({
    'action': 'start',
    'conversation_id': conversationId,
    'is_video': isVideo,
  });

  @override
  Future<GroupCallCredentials> join({required String callId}) =>
      _invokeToken({'action': 'join', 'call_id': callId});

  Future<GroupCallCredentials> _invokeToken(Map<String, dynamic> body) async {
    try {
      final response = await client.functions.invoke(
        'group-call-token',
        body: body,
      );
      final data = response.data;
      if (data is! Map) {
        throw const CallException('Invalid group call response.');
      }
      final payload = Map<String, dynamic>.from(data);
      final error = payload['error']?.toString().trim();
      if (error != null && error.isNotEmpty) throw CallException(error);
      return GroupCallCredentials(
        callId: _required(payload, 'call_id'),
        conversationId: _required(payload, 'conversation_id'),
        roomName: _required(payload, 'room_name'),
        serverUrl: _required(payload, 'server_url'),
        participantToken: _required(payload, 'participant_token'),
        title: _required(payload, 'title'),
        participantId: _required(payload, 'participant_id'),
        participantName: _required(payload, 'participant_name'),
        isVideo: payload['is_video'] == true,
      );
    } on CallException {
      rethrow;
    } on FunctionException catch (error) {
      final details = error.details;
      final message = details is Map
          ? details['error']?.toString().trim()
          : details?.toString().trim();
      throw CallException(
        message == null || message.isEmpty
            ? 'Could not connect to the group call.'
            : message,
        details: 'HTTP ${error.status}',
      );
    } catch (error) {
      throw CallException(
        'Could not connect to the group call.',
        details: '$error',
      );
    }
  }

  @override
  Future<void> leave({required String callId}) async {
    await _rpc('leave_group_call', {'target_call_id': callId});
  }

  @override
  Future<void> fail({required String callId, String? reason}) async {
    await _rpc('fail_group_call', {
      'target_call_id': callId,
      'reason': reason ?? 'client_failure',
    });
  }

  Future<void> decline({required String callId}) async {
    await _rpc('decline_group_call', {'target_call_id': callId});
  }

  Future<GroupCallSessionSummary?> activeCallForConversation(
    String conversationId,
  ) async {
    final result = await client
        .from('group_call_sessions')
        .select('id, conversation_id, title, is_video')
        .eq('conversation_id', conversationId)
        .eq('status', 'active')
        .maybeSingle();
    if (result == null) return null;
    final participants = await client
        .from('group_call_participants')
        .select('user_id')
        .eq('call_id', result['id'])
        .inFilter('status', ['joining', 'joined']);
    return GroupCallSessionSummary(
      callId: result['id'].toString(),
      conversationId: result['conversation_id'].toString(),
      title: result['title']?.toString() ?? 'Group call',
      isVideo: result['is_video'] == true,
      participantCount: (participants as List).length,
    );
  }

  Stream<GroupCallInvite> watchIncomingInvites() {
    final controller = StreamController<GroupCallInvite>.broadcast();
    final seen = <String>{};
    Timer? timer;
    var closed = false;
    Future<void> poll() async {
      if (closed) return;
      try {
        final rows = await client
            .from('group_call_participants')
            .select(
              'call_id, status, group_call_sessions!inner(id, conversation_id, title, started_by_name, is_video, status)',
            )
            .eq('user_id', _userId)
            .eq('status', 'invited')
            .eq('group_call_sessions.status', 'active');
        for (final row in rows as List) {
          final session = Map<String, dynamic>.from(
            row['group_call_sessions'] as Map,
          );
          final id = row['call_id'].toString();
          if (!seen.add(id)) continue;
          controller.add(
            GroupCallInvite(
              callId: id,
              conversationId: session['conversation_id'].toString(),
              title: session['title']?.toString() ?? 'Group call',
              callerName: session['started_by_name']?.toString() ?? 'Someone',
              isVideo: session['is_video'] == true,
            ),
          );
        }
      } catch (error, stackTrace) {
        if (!closed) controller.addError(error, stackTrace);
      }
    }

    unawaited(poll());
    timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(poll()),
    );
    controller.onCancel = () async {
      closed = true;
      timer?.cancel();
      await controller.close();
    };
    return controller.stream;
  }

  Future<void> _rpc(String function, Map<String, dynamic> params) async {
    try {
      await _rpcInvoker(function, params);
    } on PostgrestException catch (error) {
      throw CallException(error.message, details: error.details?.toString());
    }
  }

  String _required(Map<String, dynamic> data, String key) {
    final value = data[key]?.toString().trim() ?? '';
    if (value.isEmpty) {
      throw CallException('Group call response is missing $key.');
    }
    return value;
  }
}
