import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_models.dart';

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
  });

  final CallMediaState mediaState;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback onSwitchCamera;
  final VoidCallback onHangUp;
  final bool showCameraControls;

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
                onPressed: onToggleCamera,
              ),
              _CallControlButton(
                tooltip: 'Switch camera',
                icon: Icons.cameraswitch,
                onPressed: onSwitchCamera,
              ),
            ],
            _CallControlButton(
              tooltip: 'Hang up',
              icon: Icons.call_end,
              danger: true,
              onPressed: onHangUp,
            ),
          ],
        ),
      ),
    );
  }
}

class CallStatusLabel extends StatelessWidget {
  const CallStatusLabel({super.key, required this.snapshot});

  final CallSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      switch (snapshot.state) {
        CallState.dialing => 'Calling...',
        CallState.ringing => 'Ringing...',
        CallState.connecting => 'Connecting...',
        CallState.active => 'Connected',
        CallState.ended => 'Call ended',
        CallState.rejected => 'Call declined',
        CallState.failed => 'Call failed',
        CallState.idle => '',
      },
      maxLines: 2,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _CallControlButton extends StatelessWidget {
  const _CallControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: danger ? Colors.red.shade700 : Colors.white24,
        foregroundColor: Colors.white,
        minimumSize: const Size.square(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}
