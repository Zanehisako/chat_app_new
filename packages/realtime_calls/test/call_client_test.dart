import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_calls/realtime_calls.dart';

void main() {
  test('disposing an unused client does not touch uninitialized renderers', () {
    final client = CallClient(signaling: _FakeCallSignaling());

    expect(client.dispose(), completes);
  });
}

class _FakeCallSignaling implements CallSignaling {
  @override
  String get localUserId => 'local-user';

  @override
  Future<void> acceptInvite(String callId) async {}

  @override
  Future<CallInvite> createInvite({
    required String conversationId,
    required String calleeId,
    required String callerName,
    required bool isVideo,
    required DateTime expiresAt,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> endCall(String callId) async {}

  @override
  Future<void> failCall(String callId, String reason) async {}

  @override
  Future<List<IceServer>> fetchIceServers() async => const [];

  @override
  Future<void> rejectInvite(String callId) async {}

  @override
  Future<void> sendSignal(CallSignal signal) async {}

  @override
  Stream<CallInvite> watchIncomingInvites() => const Stream.empty();

  @override
  Stream<CallSignal> watchSignals(String callId) => const Stream.empty();
}
