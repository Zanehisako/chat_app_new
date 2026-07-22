import 'package:chat_app/src/motion/chat_message_overlay.dart';
import 'package:chat_app/src/motion/chat_motion.dart';
import 'package:chat_app/src/motion/chat_motion_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    ChatHaptics.debugDelegate = null;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('motion tokens stay finite and within the product limits', () {
    const motion = ChatMotionTheme.standard;

    expect(motion.springMass, 1);
    expect(motion.springStiffness, 380);
    expect(motion.springDamping, 28);
    expect(motion.staggerDuration, const Duration(milliseconds: 45));
    expect(motion.pressScale, 0.96);
    expect(motion.rowPressScale, 0.985);
    expect(motion.entryScale, 0.92);
    expect(motion.maximumOvershoot, 1.04);
    expect(
      motion.emphasizedDuration,
      lessThanOrEqualTo(motion.maximumDuration),
    );
    expect(motion.maximumDuration, const Duration(milliseconds: 480));
  });

  testWidgets('system accessibility settings disable authored motion', (
    tester,
  ) async {
    late ChatMotionPolicy policy;

    await tester.pumpWidget(
      _MotionHarness(
        mediaQueryData: const MediaQueryData(disableAnimations: true),
        builder: (context) {
          policy = ChatMotionPolicy.of(context);
          return const ChatEntrance(child: Text('Ready'));
        },
      ),
    );

    expect(policy.reduceMotion, isTrue);
    expect(policy.heroEnabled, isFalse);
    expect(policy.duration(const Duration(seconds: 1)), Duration.zero);
    expect(policy.scale(0.5), 1);
    expect(policy.offset(20), 0);
    expect(find.text('Ready'), findsOneWidget);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
  });

  testWidgets('spring pop and press feedback settle within the hard cap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _MotionHarness(
        builder: (context) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ChatSpringPop(
                child: SizedBox(
                  key: Key('spring-child'),
                  width: 40,
                  height: 40,
                ),
              ),
              ChatPressScale(
                child: Container(
                  key: const Key('press-child'),
                  width: 40,
                  height: 40,
                  color: Colors.blue,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 480));
    expect(_scaleFor(tester, find.byType(ChatSpringPop)), 1);

    final listener = tester.widget<Listener>(
      find
          .descendant(
            of: find.byType(ChatPressScale),
            matching: find.byType(Listener),
          )
          .first,
    );
    listener.onPointerDown!(const PointerDownEvent());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(_scaleFor(tester, find.byType(ChatPressScale)), lessThan(1));

    listener.onPointerUp!(const PointerUpEvent());
    await tester.pump(const Duration(milliseconds: 480));
    expect(_scaleFor(tester, find.byType(ChatPressScale)), 1);
  });

  testWidgets('state switcher excludes its outgoing child from semantics', (
    tester,
  ) async {
    var showSecond = false;
    late StateSetter setState;

    await tester.pumpWidget(
      _MotionHarness(
        builder: (context) => StatefulBuilder(
          builder: (context, update) {
            setState = update;
            return ChatStateSwitcher(
              child: Text(
                showSecond ? 'Second' : 'First',
                key: ValueKey<bool>(showSecond),
              ),
            );
          },
        ),
      ),
    );

    setState(() => showSecond = true);
    await tester.pump();

    final semantics = tester.widgetList<ExcludeSemantics>(
      find.byType(ExcludeSemantics),
    );
    expect(semantics.any((widget) => widget.excluding), isTrue);

    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  test('haptics dispatch only on supported platforms', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await ChatHaptics.selection();
    expect(calls, isEmpty);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await ChatHaptics.selection();
    await ChatHaptics.lightImpact();

    expect(calls, hasLength(2));
    expect(
      calls.every((call) => call.method == 'HapticFeedback.vibrate'),
      isTrue,
    );
    expect(calls.map((call) => call.arguments), [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.lightImpact',
    ]);
  });

  test('injectable haptics preserve interaction intent', () async {
    final received = <ChatHapticKind>[];
    ChatHaptics.debugDelegate = (kind) async => received.add(kind);

    await ChatHaptics.selection();
    await ChatHaptics.lightImpact();

    expect(received, [ChatHapticKind.selection, ChatHapticKind.lightImpact]);
  });

  testWidgets('animated reaction pill dispatches emoji selection', (
    tester,
  ) async {
    String? selectedEmoji;
    var moreClicked = false;

    await tester.pumpWidget(
      _MotionHarness(
        builder: (context) => AnimatedReactionPill(
          emojis: const ['❤️', '😂', '👍'],
          onSelectEmoji: (emoji) => selectedEmoji = emoji,
          onMoreReactions: () => moreClicked = true,
        ),
      ),
    );

    expect(find.text('❤️'), findsOneWidget);
    expect(find.text('😂'), findsOneWidget);
    expect(find.text('👍'), findsOneWidget);

    await tester.tap(find.text('❤️'));
    await tester.pump();

    expect(selectedEmoji, '❤️');

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();

    expect(moreClicked, isTrue);
  });

  testWidgets('floating action menu card dispatches selected action', (
    tester,
  ) async {
    ChatOverlayActionKind? dispatchedAction;

    await tester.pumpWidget(
      _MotionHarness(
        builder: (context) => FloatingActionMenuCard(
          sent: true,
          hasText: true,
          isMine: true,
          theme: ThemeData.light(),
          onAction: (action) => dispatchedAction = action,
        ),
      ),
    );

    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Reply'));
    await tester.pump();

    expect(dispatchedAction, ChatOverlayActionKind.reply);
  });
}

class _MotionHarness extends StatelessWidget {
  const _MotionHarness({required this.builder, this.mediaQueryData});

  final WidgetBuilder builder;
  final MediaQueryData? mediaQueryData;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        extensions: const <ThemeExtension<dynamic>>[ChatMotionTheme.standard],
      ),
      home: MediaQuery(
        data: mediaQueryData ?? const MediaQueryData(),
        child: Material(child: Builder(builder: builder)),
      ),
    );
  }
}

double _scaleFor(WidgetTester tester, Finder animatedWidget) {
  final transform = tester.widget<Transform>(
    find.descendant(of: animatedWidget, matching: find.byType(Transform)).first,
  );
  return transform.transform.entry(0, 0);
}
