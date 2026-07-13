import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_calls/realtime_calls.dart';

void main() {
  test('group call credentials preserve room authorization metadata', () {
    const credentials = GroupCallCredentials(
      callId: 'call-1',
      conversationId: 'conversation-1',
      roomName: 'chat-group-room',
      serverUrl: 'wss://calls.example.test',
      participantToken: 'token',
      title: 'Launch Team',
      participantId: 'user-1',
      participantName: 'Alex',
      isVideo: true,
    );

    expect(credentials.callId, 'call-1');
    expect(credentials.roomName, 'chat-group-room');
    expect(credentials.isVideo, isTrue);
  });

  test('group call snapshot exposes terminal states', () {
    final credentials = const GroupCallCredentials(
      callId: 'call-1',
      conversationId: 'conversation-1',
      roomName: 'room',
      serverUrl: 'wss://calls.example.test',
      participantToken: 'token',
      title: 'Team',
      participantId: 'user-1',
      participantName: 'Alex',
      isVideo: false,
    );
    final snapshot = GroupCallSnapshot(
      credentials: credentials,
      state: GroupCallState.ended,
      participants: const [],
    );

    expect(snapshot.isTerminal, isTrue);
    expect(snapshot.participants, isEmpty);
  });
}
