import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_calls/realtime_calls.dart';

void main() {
  test('IceServer serializes urls and credentials for WebRTC config', () {
    const server = IceServer(
      urls: ['turn:turn.example.com:3478?transport=udp'],
      username: '1750000000:user',
      credential: 'secret',
    );

    expect(server.toJson(), {
      'urls': 'turn:turn.example.com:3478?transport=udp',
      'username': '1750000000:user',
      'credential': 'secret',
    });
  });

  test('CallSignalType parses persisted values', () {
    expect(CallSignalType.fromValue('offer'), CallSignalType.offer);
    expect(
      CallSignalType.fromValue('ice_candidate'),
      CallSignalType.iceCandidate,
    );
    expect(
      () => CallSignalType.fromValue('unknown'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('CallMediaState toggles immutable media controls', () {
    const state = CallMediaState.initial(isVideo: true);
    final muted = state.copyWith(isMuted: true, isCameraEnabled: false);

    expect(state.isMuted, isFalse);
    expect(state.isCameraEnabled, isTrue);
    expect(muted.isMuted, isTrue);
    expect(muted.isCameraEnabled, isFalse);
  });
}
