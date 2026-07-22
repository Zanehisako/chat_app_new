import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'chat_motion.dart';

class ChatPressScale extends StatefulWidget {
  const ChatPressScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.row = false,
    this.triggerHaptic = false,
  });

  final Widget child;
  final bool enabled;
  final bool row;
  final bool triggerHaptic;

  @override
  State<ChatPressScale> createState() => _ChatPressScaleState();
}

class _ChatPressScaleState extends State<ChatPressScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _settleTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this, value: 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.chatMotion.reduceMotion && _controller.value != 1) {
      _settleTimer?.cancel();
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant ChatPressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      _release();
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _press() {
    if (!widget.enabled) return;
    final policy = context.chatMotion;
    _settleTimer?.cancel();
    if (widget.triggerHaptic) {
      unawaited(ChatHaptics.lightImpact());
    }
    if (policy.reduceMotion) {
      _controller.value = 1;
      return;
    }
    final target = widget.row
        ? policy.theme.rowPressScale
        : policy.theme.pressScale;
    unawaited(
      _controller.animateTo(
        target,
        duration: policy.theme.microDuration,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _release() {
    final policy = context.chatMotion;
    _settleTimer?.cancel();
    if (policy.reduceMotion) {
      _controller
        ..stop()
        ..value = 1;
      return;
    }

    unawaited(
      _controller.animateWith(
        SpringSimulation(policy.theme.spring, _controller.value, 1, 0),
      ),
    );
    _settleTimer = Timer(policy.theme.maximumDuration, () {
      if (!mounted) return;
      _controller
        ..stop()
        ..value = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final maximumOvershoot = context.chatMotion.theme.maximumOvershoot;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _press(),
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          final scale = _controller.value
              .clamp(0.9, maximumOvershoot)
              .toDouble();
          return Transform.scale(scale: scale, child: child);
        },
      ),
    );
  }
}

class ChatEntrance extends StatefulWidget {
  const ChatEntrance({
    super.key,
    required this.child,
    this.beginOffset = const Offset(0, 8),
    this.beginScale = 0.98,
    this.delay = Duration.zero,
    this.duration,
  });

  final Widget child;
  final Offset beginOffset;
  final double beginScale;
  final Duration delay;
  final Duration? duration;

  @override
  State<ChatEntrance> createState() => _ChatEntranceState();
}

class _ChatEntranceState extends State<ChatEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _delayTimer;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final policy = context.chatMotion;
    _controller.duration = policy.duration(
      widget.duration ?? policy.theme.standardDuration,
    );
    if (policy.reduceMotion) {
      _delayTimer?.cancel();
      _controller.value = 1;
      _started = true;
      return;
    }
    if (!_started) {
      _started = true;
      final delay = policy.duration(widget.delay);
      if (delay == Duration.zero) {
        unawaited(_controller.forward());
      } else {
        _delayTimer = Timer(delay, () {
          if (mounted) unawaited(_controller.forward());
        });
      }
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final progress = Curves.easeOutCubic.transform(_controller.value);
        final offset = Offset.lerp(widget.beginOffset, Offset.zero, progress)!;
        final scale = lerpDouble(widget.beginScale, 1, progress)!;
        return Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: offset,
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
    );
  }
}

class ChatStateSwitcher extends StatelessWidget {
  const ChatStateSwitcher({
    super.key,
    required this.child,
    this.duration,
    this.offset,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final Duration? duration;
  final Offset? offset;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final policy = context.chatMotion;
    final transitionOffset = offset ?? Offset(0, policy.theme.standardOffset);
    return AnimatedSwitcher(
      duration: policy.duration(duration ?? policy.theme.standardDuration),
      reverseDuration: policy.duration(policy.theme.microDuration),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) {
            final outgoing = animation.status == AnimationStatus.reverse;
            final progress = Curves.easeOutCubic.transform(animation.value);
            return IgnorePointer(
              ignoring: outgoing,
              child: ExcludeSemantics(
                excluding: outgoing,
                child: Opacity(
                  opacity: progress,
                  child: Transform.translate(
                    offset: Offset.lerp(
                      transitionOffset,
                      Offset.zero,
                      progress,
                    )!,
                    child: child,
                  ),
                ),
              ),
            );
          },
        );
      },
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: alignment,
          children: [...previousChildren, ?currentChild],
        );
      },
      child: child,
    );
  }
}

class ChatSizeFade extends StatelessWidget {
  const ChatSizeFade({
    super.key,
    required this.child,
    this.alignment = Alignment.topCenter,
    this.duration,
  });

  final Widget? child;
  final AlignmentGeometry alignment;
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final policy = context.chatMotion;
    return AnimatedSize(
      duration: policy.duration(duration ?? policy.theme.standardDuration),
      curve: Curves.easeOutCubic,
      alignment: alignment,
      child: ChatStateSwitcher(
        duration: duration,
        alignment: Alignment.topCenter,
        child:
            child ??
            const SizedBox.shrink(
              key: ValueKey<String>('chat-size-fade-empty'),
            ),
      ),
    );
  }
}

class ChatSpringPop extends StatefulWidget {
  const ChatSpringPop({
    super.key,
    required this.child,
    this.beginOffset = Offset.zero,
    this.beginScale,
  });

  final Widget child;
  final Offset beginOffset;
  final double? beginScale;

  @override
  State<ChatSpringPop> createState() => _ChatSpringPopState();
}

class _ChatSpringPopState extends State<ChatSpringPop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _settleTimer;
  bool _started = false;
  double _entryScale = ChatMotionTheme.standard.entryScale;
  double _maximumOvershoot = ChatMotionTheme.standard.maximumOvershoot;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final policy = context.chatMotion;
    _entryScale = widget.beginScale ?? policy.theme.entryScale;
    _maximumOvershoot = policy.theme.maximumOvershoot;
    if (policy.reduceMotion) {
      _settleTimer?.cancel();
      _controller.value = 1;
      _started = true;
      return;
    }
    if (_started) return;
    _started = true;
    _controller.value = _entryScale;
    unawaited(
      _controller.animateWith(
        SpringSimulation(policy.theme.spring, _entryScale, 1, 0),
      ),
    );
    _settleTimer = Timer(policy.theme.maximumDuration, () {
      if (!mounted) return;
      _controller
        ..stop()
        ..value = 1;
    });
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final scale = _controller.value
            .clamp(_entryScale, _maximumOvershoot)
            .toDouble();
        final progress = ((scale - _entryScale) / (1 - _entryScale)).clamp(
          0.0,
          1.0,
        );
        return Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: Offset.lerp(widget.beginOffset, Offset.zero, progress)!,
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
    );
  }
}

class ChatStagger extends StatelessWidget {
  const ChatStagger({
    super.key,
    required this.index,
    required this.child,
    this.maximumTotalDelay = const Duration(milliseconds: 180),
    this.beginOffset = const Offset(0, 8),
  });

  final int index;
  final Widget child;
  final Duration maximumTotalDelay;
  final Offset beginOffset;

  @override
  Widget build(BuildContext context) {
    final policy = context.chatMotion;
    final delay = Duration(
      microseconds: math.min(
        index * policy.theme.staggerDuration.inMicroseconds,
        maximumTotalDelay.inMicroseconds,
      ),
    );
    return ChatEntrance(delay: delay, beginOffset: beginOffset, child: child);
  }
}
