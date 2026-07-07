import 'call_models.dart';

abstract class CallSignaling {
  String get localUserId;

  Future<List<IceServer>> fetchIceServers();

  Future<CallInvite> createInvite({
    required String conversationId,
    required String calleeId,
    required String callerName,
    required bool isVideo,
    required DateTime expiresAt,
  });

  Stream<CallInvite> watchIncomingInvites();

  Stream<CallSignal> watchSignals(String callId);

  Future<void> acceptInvite(String callId);

  Future<void> rejectInvite(String callId);

  Future<void> endCall(String callId);

  Future<void> failCall(String callId, String reason);

  Future<void> sendSignal(CallSignal signal);
}
