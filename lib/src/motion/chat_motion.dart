import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

@immutable
class ChatMotionTheme extends ThemeExtension<ChatMotionTheme> {
  const ChatMotionTheme({
    required this.microDuration,
    required this.standardDuration,
    required this.emphasizedDuration,
    required this.maximumDuration,
    required this.staggerDuration,
    required this.pressScale,
    required this.rowPressScale,
    required this.entryScale,
    required this.maximumOvershoot,
    required this.smallOffset,
    required this.standardOffset,
    required this.routeOffset,
    required this.springMass,
    required this.springStiffness,
    required this.springDamping,
  });

  static const standard = ChatMotionTheme(
    microDuration: Duration(milliseconds: 140),
    standardDuration: Duration(milliseconds: 220),
    emphasizedDuration: Duration(milliseconds: 340),
    maximumDuration: Duration(milliseconds: 480),
    staggerDuration: Duration(milliseconds: 45),
    pressScale: 0.96,
    rowPressScale: 0.985,
    entryScale: 0.92,
    maximumOvershoot: 1.04,
    smallOffset: 4,
    standardOffset: 8,
    routeOffset: 14,
    springMass: 1,
    springStiffness: 380,
    springDamping: 28,
  );

  final Duration microDuration;
  final Duration standardDuration;
  final Duration emphasizedDuration;
  final Duration maximumDuration;
  final Duration staggerDuration;
  final double pressScale;
  final double rowPressScale;
  final double entryScale;
  final double maximumOvershoot;
  final double smallOffset;
  final double standardOffset;
  final double routeOffset;
  final double springMass;
  final double springStiffness;
  final double springDamping;

  SpringDescription get spring => SpringDescription(
    mass: springMass,
    stiffness: springStiffness,
    damping: springDamping,
  );

  static const Curve emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Curve emphasizedEase = Cubic(0.2, 0.0, 0.0, 1.0);

  @override
  ChatMotionTheme copyWith({
    Duration? microDuration,
    Duration? standardDuration,
    Duration? emphasizedDuration,
    Duration? maximumDuration,
    Duration? staggerDuration,
    double? pressScale,
    double? rowPressScale,
    double? entryScale,
    double? maximumOvershoot,
    double? smallOffset,
    double? standardOffset,
    double? routeOffset,
    double? springMass,
    double? springStiffness,
    double? springDamping,
  }) {
    return ChatMotionTheme(
      microDuration: microDuration ?? this.microDuration,
      standardDuration: standardDuration ?? this.standardDuration,
      emphasizedDuration: emphasizedDuration ?? this.emphasizedDuration,
      maximumDuration: maximumDuration ?? this.maximumDuration,
      staggerDuration: staggerDuration ?? this.staggerDuration,
      pressScale: pressScale ?? this.pressScale,
      rowPressScale: rowPressScale ?? this.rowPressScale,
      entryScale: entryScale ?? this.entryScale,
      maximumOvershoot: maximumOvershoot ?? this.maximumOvershoot,
      smallOffset: smallOffset ?? this.smallOffset,
      standardOffset: standardOffset ?? this.standardOffset,
      routeOffset: routeOffset ?? this.routeOffset,
      springMass: springMass ?? this.springMass,
      springStiffness: springStiffness ?? this.springStiffness,
      springDamping: springDamping ?? this.springDamping,
    );
  }

  @override
  ChatMotionTheme lerp(ThemeExtension<ChatMotionTheme>? other, double t) {
    if (other is! ChatMotionTheme) {
      return this;
    }

    return ChatMotionTheme(
      microDuration: _lerpDuration(microDuration, other.microDuration, t),
      standardDuration: _lerpDuration(
        standardDuration,
        other.standardDuration,
        t,
      ),
      emphasizedDuration: _lerpDuration(
        emphasizedDuration,
        other.emphasizedDuration,
        t,
      ),
      maximumDuration: _lerpDuration(maximumDuration, other.maximumDuration, t),
      staggerDuration: _lerpDuration(staggerDuration, other.staggerDuration, t),
      pressScale: lerpDouble(pressScale, other.pressScale, t)!,
      rowPressScale: lerpDouble(rowPressScale, other.rowPressScale, t)!,
      entryScale: lerpDouble(entryScale, other.entryScale, t)!,
      maximumOvershoot: lerpDouble(
        maximumOvershoot,
        other.maximumOvershoot,
        t,
      )!,
      smallOffset: lerpDouble(smallOffset, other.smallOffset, t)!,
      standardOffset: lerpDouble(standardOffset, other.standardOffset, t)!,
      routeOffset: lerpDouble(routeOffset, other.routeOffset, t)!,
      springMass: lerpDouble(springMass, other.springMass, t)!,
      springStiffness: lerpDouble(springStiffness, other.springStiffness, t)!,
      springDamping: lerpDouble(springDamping, other.springDamping, t)!,
    );
  }
}

@immutable
class ChatMotionPolicy {
  const ChatMotionPolicy({required this.theme, required this.reduceMotion});

  factory ChatMotionPolicy.of(BuildContext context) {
    final mediaQuery = MediaQuery.maybeOf(context);
    return ChatMotionPolicy(
      theme:
          Theme.of(context).extension<ChatMotionTheme>() ??
          ChatMotionTheme.standard,
      reduceMotion:
          (mediaQuery?.disableAnimations ?? false) ||
          (mediaQuery?.accessibleNavigation ?? false),
    );
  }

  final ChatMotionTheme theme;
  final bool reduceMotion;

  Duration duration(Duration value) => reduceMotion ? Duration.zero : value;

  double scale(double value) => reduceMotion ? 1 : value;

  double offset(double value) => reduceMotion ? 0 : value;

  bool get heroEnabled => !reduceMotion;
}

extension ChatMotionContext on BuildContext {
  ChatMotionPolicy get chatMotion => ChatMotionPolicy.of(this);
}

enum ChatHapticKind { selection, lightImpact }

typedef ChatHapticDelegate = Future<void> Function(ChatHapticKind kind);

class ChatHaptics {
  ChatHaptics._();

  static ChatHapticDelegate? _debugDelegate;

  @visibleForTesting
  static set debugDelegate(ChatHapticDelegate? delegate) {
    _debugDelegate = delegate;
  }

  static Future<void> selection() => _dispatch(ChatHapticKind.selection);

  static Future<void> lightImpact() => _dispatch(ChatHapticKind.lightImpact);

  static Future<void> _dispatch(ChatHapticKind kind) async {
    final delegate = _debugDelegate;
    if (delegate != null) {
      await delegate(kind);
      return;
    }

    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }

    try {
      switch (kind) {
        case ChatHapticKind.selection:
          await HapticFeedback.selectionClick();
          break;
        case ChatHapticKind.lightImpact:
          await HapticFeedback.lightImpact();
          break;
      }
    } on MissingPluginException {
      // Some desktop-like test and embedded targets expose no haptics channel.
    } on PlatformException {
      // Haptics are best-effort and must never block the interaction.
    }
  }
}

Duration _lerpDuration(Duration a, Duration b, double t) {
  return Duration(
    microseconds: lerpDouble(a.inMicroseconds, b.inMicroseconds, t)!.round(),
  );
}
