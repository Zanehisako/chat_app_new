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

  testWidgets('CallStatusLabel uses a finite keyed status transition', (
    tester,
  ) async {
    final localRenderer = RTCVideoRenderer();
    final remoteRenderer = RTCVideoRenderer();
    final state = ValueNotifier<CallState>(CallState.dialing);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<CallState>(
            valueListenable: state,
            builder: (context, value, child) {
              return CallStatusLabel(
                snapshot: _snapshot(
                  state: value,
                  localRenderer: localRenderer,
                  remoteRenderer: remoteRenderer,
                ),
                motionSpec: const CallWidgetMotionSpec(
                  statusTransitionDuration: Duration(milliseconds: 200),
                  controlTransitionDuration: Duration(milliseconds: 100),
                ),
              );
            },
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<CallState>(CallState.dialing)),
      findsOneWidget,
    );

    state.value = CallState.active;
    await tester.pump();

    expect(find.text('Calling...'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<CallState>(CallState.active)),
      findsOneWidget,
    );
    final statusLabel = find.byType(CallStatusLabel);
    expect(
      find.descendant(of: statusLabel, matching: find.byType(FadeTransition)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: statusLabel, matching: find.byType(ScaleTransition)),
      findsNWidgets(2),
    );

    await tester.pumpAndSettle();

    expect(find.text('Calling...'), findsNothing);
    expect(find.text('Connected'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion switches status and controls immediately', (
    tester,
  ) async {
    final localRenderer = RTCVideoRenderer();
    final remoteRenderer = RTCVideoRenderer();
    var callState = CallState.dialing;
    var mediaState = const CallMediaState.initial(isVideo: false);
    late StateSetter setHostState;
    const motionSpec = CallWidgetMotionSpec(
      statusTransitionDuration: Duration(seconds: 1),
      controlTransitionDuration: Duration(seconds: 1),
      pressScale: 0.8,
      reducedMotion: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return Column(
                children: [
                  CallStatusLabel(
                    snapshot: _snapshot(
                      state: callState,
                      localRenderer: localRenderer,
                      remoteRenderer: remoteRenderer,
                    ),
                    motionSpec: motionSpec,
                  ),
                  CallControls(
                    mediaState: mediaState,
                    showCameraControls: false,
                    motionSpec: motionSpec,
                    onToggleMute: () {
                      setState(() {
                        mediaState = mediaState.copyWith(
                          isMuted: !mediaState.isMuted,
                        );
                      });
                    },
                    onToggleCamera: () {},
                    onSwitchCamera: () {},
                    onHangUp: () {},
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    setHostState(() => callState = CallState.active);
    await tester.pump();

    expect(find.text('Calling...'), findsNothing);
    expect(find.text('Connected'), findsOneWidget);

    final muteScale = _muteAnimatedScale();
    expect(muteScale, findsOneWidget);
    expect(tester.widget<AnimatedScale>(muteScale).duration, Duration.zero);
    expect(tester.widget<AnimatedScale>(muteScale).scale, 1);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Mute')),
    );
    await tester.pump();

    expect(tester.widget<AnimatedScale>(muteScale).scale, 1);

    await gesture.up();
    await tester.pump();

    expect(find.byTooltip('Unmute'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsNothing);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(CallControls),
        matching: find.byType(AnimatedSwitcher),
      ),
      findsNothing,
    );
  });

  testWidgets('CallControls press and icon motion settles', (tester) async {
    var mediaState = const CallMediaState.initial(isVideo: false);
    const duration = Duration(milliseconds: 100);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return CallControls(
                mediaState: mediaState,
                showCameraControls: false,
                motionSpec: const CallWidgetMotionSpec(
                  controlTransitionDuration: duration,
                  pressScale: 0.9,
                ),
                onToggleMute: () {
                  setState(() {
                    mediaState = mediaState.copyWith(
                      isMuted: !mediaState.isMuted,
                    );
                  });
                },
                onToggleCamera: () {},
                onSwitchCamera: () {},
                onHangUp: () {},
              );
            },
          ),
        ),
      ),
    );

    final muteScale = _muteAnimatedScale();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Mute')),
    );
    await tester.pump();
    await tester.pump(duration);

    expect(_currentScale(tester, muteScale), closeTo(0.9, 0.001));

    await gesture.up();
    await tester.pump();

    expect(find.byTooltip('Unmute'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);

    await tester.pump(duration);
    await tester.pumpAndSettle();

    expect(_currentScale(tester, muteScale), closeTo(1, 0.001));
    expect(find.byIcon(Icons.mic), findsNothing);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
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
            snapshot: _snapshot(
              state: CallState.failed,
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

Finder _muteAnimatedScale() {
  return find
      .descendant(
        of: find.byType(CallControls),
        matching: find.byType(AnimatedScale),
      )
      .first;
}

double _currentScale(WidgetTester tester, Finder animatedScale) {
  final transition = find.descendant(
    of: animatedScale,
    matching: find.byType(ScaleTransition),
  );
  expect(transition, findsOneWidget);
  return tester.widget<ScaleTransition>(transition).scale.value;
}

CallSnapshot _snapshot({
  required CallState state,
  required RTCVideoRenderer localRenderer,
  required RTCVideoRenderer remoteRenderer,
  String? errorMessage,
}) {
  return CallSnapshot(
    callId: 'call-1',
    conversationId: 'conversation-1',
    peerUserId: 'peer-1',
    peerName: 'Peer',
    direction: CallDirection.outgoing,
    state: state,
    mediaState: const CallMediaState.initial(isVideo: false),
    localRenderer: localRenderer,
    remoteRenderer: remoteRenderer,
    errorMessage: errorMessage,
  );
}
