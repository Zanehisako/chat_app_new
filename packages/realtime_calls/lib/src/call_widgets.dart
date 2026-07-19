import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_models.dart';

/// Motion values used by the reusable call widgets.
///
/// Host apps can map their own motion policy into this package-local type
/// without making the package depend on app-private motion classes.
@immutable
class CallWidgetMotionSpec {
  const CallWidgetMotionSpec({
    this.statusTransitionDuration = const Duration(milliseconds: 220),
    this.controlTransitionDuration = const Duration(milliseconds: 140),
    this.pressScale = 0.96,
    this.reducedMotion = false,
  }) : assert(pressScale > 0 && pressScale <= 1);

  final Duration statusTransitionDuration;
  final Duration controlTransitionDuration;
  final double pressScale;
  final bool reducedMotion;
}

class CallVideoView extends StatelessWidget {
  const CallVideoView({
    super.key,
    required this.renderer,
    this.mirror = false,
    this.placeholderIcon = Icons.person,
  });

  final RTCVideoRenderer renderer;
  final bool mirror;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    if (renderer.srcObject == null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Icon(placeholderIcon, color: Colors.white70, size: 56),
        ),
      );
    }

    return RTCVideoView(
      renderer,
      mirror: mirror,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }
}

class CallControls extends StatelessWidget {
  const CallControls({
    super.key,
    required this.mediaState,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onSwitchCamera,
    required this.onHangUp,
    this.showCameraControls = true,
    this.motionSpec = const CallWidgetMotionSpec(),
  });

  final CallMediaState mediaState;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onHangUp;
  final bool showCameraControls;
  final CallWidgetMotionSpec motionSpec;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            _CallControlButton(
              tooltip: mediaState.isMuted ? 'Unmute' : 'Mute',
              icon: mediaState.isMuted ? Icons.mic_off : Icons.mic,
              motionSpec: motionSpec,
              onPressed: onToggleMute,
            ),
            if (showCameraControls) ...[
              _CallControlButton(
                tooltip: mediaState.isCameraEnabled
                    ? 'Turn camera off'
                    : 'Turn camera on',
                icon: mediaState.isCameraEnabled
                    ? Icons.videocam
                    : Icons.videocam_off,
                motionSpec: motionSpec,
                onPressed: onToggleCamera,
              ),
              _CallControlButton(
                tooltip: 'Switch camera',
                icon: Icons.cameraswitch,
                motionSpec: motionSpec,
                onPressed: onSwitchCamera,
              ),
            ],
            _CallControlButton(
              tooltip: 'Hang up',
              icon: Icons.call_end,
              danger: true,
              motionSpec: motionSpec,
              onPressed: onHangUp,
            ),
          ],
        ),
      ),
    );
  }
}

class CallStatusLabel extends StatelessWidget {
  const CallStatusLabel({
    super.key,
    required this.snapshot,
    this.motionSpec = const CallWidgetMotionSpec(),
  });

  final CallSnapshot snapshot;
  final CallWidgetMotionSpec motionSpec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (snapshot.state) {
      CallState.dialing => 'Calling...',
      CallState.ringing => 'Ringing...',
      CallState.connecting => 'Connecting...',
      CallState.active => 'Connected',
      CallState.ended => 'Call ended',
      CallState.rejected => 'Call declined',
      CallState.failed => 'Call failed',
      CallState.idle => '',
    };
    final text = Text(
      label,
      key: ValueKey<CallState>(snapshot.state),
      maxLines: 2,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w700,
      ),
    );

    if (motionSpec.reducedMotion) {
      return text;
    }

    return AnimatedSwitcher(
      duration: motionSpec.statusTransitionDuration,
      reverseDuration: motionSpec.controlTransitionDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final outgoing = animation.status == AnimationStatus.reverse;
        return ExcludeSemantics(
          excluding: outgoing,
          child: FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(animation),
              child: child,
            ),
          ),
        );
      },
      child: text,
    );
  }
}

class _CallControlButton extends StatefulWidget {
  const _CallControlButton({
    required this.tooltip,
    required this.icon,
    required this.motionSpec,
    required this.onPressed,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final CallWidgetMotionSpec motionSpec;
  final VoidCallback onPressed;
  final bool danger;

  @override
  State<_CallControlButton> createState() => _CallControlButtonState();
}

class _CallControlButtonState extends State<_CallControlButton> {
  bool _isPressed = false;

  @override
  void didUpdateWidget(covariant _CallControlButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.motionSpec.reducedMotion && _isPressed) {
      _isPressed = false;
    }
  }

  void _setPressed(bool value) {
    if (_isPressed == value || (value && widget.motionSpec.reducedMotion)) {
      return;
    }
    setState(() => _isPressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final motionSpec = widget.motionSpec;
    final controlDuration = motionSpec.reducedMotion
        ? Duration.zero
        : motionSpec.controlTransitionDuration;
    final icon = Icon(widget.icon, key: ValueKey<IconData>(widget.icon));
    final animatedIcon = motionSpec.reducedMotion
        ? icon
        : AnimatedSwitcher(
            duration: controlDuration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: icon,
          );

    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _isPressed ? motionSpec.pressScale : 1,
        duration: controlDuration,
        curve: Curves.easeOutCubic,
        child: IconButton.filled(
          tooltip: widget.tooltip,
          style: IconButton.styleFrom(
            backgroundColor: widget.danger
                ? Colors.red.shade700
                : Colors.white24,
            foregroundColor: Colors.white,
            minimumSize: const Size.square(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: widget.onPressed,
          icon: animatedIcon,
        ),
      ),
    );
  }
}
