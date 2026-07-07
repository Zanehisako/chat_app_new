import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:realtime_calls/realtime_calls.dart';

void main() {
  testWidgets('CallControls exposes expected media actions', (tester) async {
    var muteCount = 0;
    var cameraCount = 0;
    var switchCount = 0;
    var hangupCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallControls(
            mediaState: const CallMediaState.initial(isVideo: true),
            onToggleMute: () => muteCount++,
            onToggleCamera: () => cameraCount++,
            onSwitchCamera: () => switchCount++,
            onHangUp: () => hangupCount++,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Mute'));
    await tester.tap(find.byTooltip('Turn camera off'));
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.tap(find.byTooltip('Hang up'));

    expect(muteCount, 1);
    expect(cameraCount, 1);
    expect(switchCount, 1);
    expect(hangupCount, 1);
  });

  testWidgets('CallStatusLabel keeps terminal failure details out of the UI', (
    tester,
  ) async {
    final localRenderer = RTCVideoRenderer();
    final remoteRenderer = RTCVideoRenderer();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallStatusLabel(
            snapshot: CallSnapshot(
              callId: 'call-1',
              conversationId: 'conversation-1',
              peerUserId: 'peer-1',
              peerName: 'Peer',
              direction: CallDirection.outgoing,
              state: CallState.failed,
              mediaState: const CallMediaState.initial(isVideo: false),
              localRenderer: localRenderer,
              remoteRenderer: remoteRenderer,
              errorMessage: 'TURN credentials missing',
            ),
          ),
        ),
      ),
    );

    expect(find.text('Call failed'), findsOneWidget);
    expect(find.text('TURN credentials missing'), findsNothing);
  });
}
