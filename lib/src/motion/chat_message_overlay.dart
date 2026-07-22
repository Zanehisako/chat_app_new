import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chat_models.dart';
import 'chat_motion.dart';
import 'chat_motion_widgets.dart';

enum ChatOverlayActionKind {
  reply,
  react,
  edit,
  delete,
  forward,
  copy,
}

class ChatMessageOverlayResult {
  const ChatMessageOverlayResult.action(this.action) : reactionEmoji = null;
  const ChatMessageOverlayResult.reaction(this.reactionEmoji) : action = null;

  final ChatOverlayActionKind? action;
  final String? reactionEmoji;
}

class ChatMessageOverlayRoute extends RawDialogRoute<ChatMessageOverlayResult> {
  ChatMessageOverlayRoute({
    required BuildContext context,
    required this.message,
    required this.messageRect,
    required this.isMine,
    required this.messageWidgetBuilder,
    bool barrierDismissible = true,
  }) : super(
          barrierDismissible: barrierDismissible,
          barrierColor: Colors.black.withValues(alpha: 0.54),
          barrierLabel:
              MaterialLocalizations.of(context).modalBarrierDismissLabel,
          transitionDuration: context.chatMotion.theme.standardDuration,
          pageBuilder: (context, animation, secondaryAnimation) {
            return _ChatMessageOverlayContent(
              message: message,
              messageRect: messageRect,
              isMine: isMine,
              messageWidgetBuilder: messageWidgetBuilder,
            );
          },
          transitionBuilder: (context, animation, secondaryAnimation, child) {
            final policy = context.chatMotion;
            if (policy.reduceMotion) return child;
            final curved = CurvedAnimation(
              parent: animation,
              curve: ChatMotionTheme.emphasizedDecelerate,
              reverseCurve: Curves.easeInCubic,
            );
            return BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: 6 * curved.value,
                sigmaY: 6 * curved.value,
              ),
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
                  child: child,
                ),
              ),
            );
          },
        );

  final ChatMessage message;
  final Rect messageRect;
  final bool isMine;
  final WidgetBuilder messageWidgetBuilder;
}

class _ChatMessageOverlayContent extends StatefulWidget {
  const _ChatMessageOverlayContent({
    required this.message,
    required this.messageRect,
    required this.isMine,
    required this.messageWidgetBuilder,
  });

  final ChatMessage message;
  final Rect messageRect;
  final bool isMine;
  final WidgetBuilder messageWidgetBuilder;

  @override
  State<_ChatMessageOverlayContent> createState() =>
      __ChatMessageOverlayContentState();
}

class __ChatMessageOverlayContentState
    extends State<_ChatMessageOverlayContent> {
  static const List<String> quickEmojis = [
    '❤️',
    '😂',
    '😮',
    '😢',
    '🙏',
    '👍',
    '🔥',
    '👏',
  ];

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    final isMine = widget.isMine;
    final messageRect = widget.messageRect;

    final placeReactionAbove = messageRect.top > 120;
    final sent = widget.message.sendState == ChatMessageSendState.sent;
    final hasText = widget.message.body.trim().isNotEmpty;

    final double availableWidth = math.min(screenSize.width - 24.0, messageRect.width + 40.0);
    final double calculatedLeft = isMine
        ? (screenSize.width - availableWidth - 12.0)
        : messageRect.left;
    final double left = calculatedLeft.clamp(12.0, math.max(12.0, screenSize.width - availableWidth - 12.0)).toDouble();

    final double top = (placeReactionAbove
        ? math.max(16.0, messageRect.top - 80.0)
        : math.min(screenSize.height - 300.0, messageRect.top)).toDouble();

    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(context),
          child: const SizedBox.expand(),
        ),

        // Floating Positioned Content Container
        Positioned(
          left: left,
          top: top,
          width: availableWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (placeReactionAbove) ...[
                AnimatedReactionPill(
                  emojis: quickEmojis,
                  onSelectEmoji: (emoji) => Navigator.pop(
                    context,
                    ChatMessageOverlayResult.reaction(emoji),
                  ),
                  onMoreReactions: () => Navigator.pop(
                    context,
                    const ChatMessageOverlayResult.action(
                      ChatOverlayActionKind.react,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // Focused Message Container
              ChatSpringPop(
                beginScale: 0.98,
                child: Material(
                  color: Colors.transparent,
                  elevation: 8,
                  shadowColor: Colors.black38,
                  borderRadius: BorderRadius.circular(12),
                  child: IgnorePointer(
                    child: widget.messageWidgetBuilder(context),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              if (!placeReactionAbove) ...[
                AnimatedReactionPill(
                  emojis: quickEmojis,
                  onSelectEmoji: (emoji) => Navigator.pop(
                    context,
                    ChatMessageOverlayResult.reaction(emoji),
                  ),
                  onMoreReactions: () => Navigator.pop(
                    context,
                    const ChatMessageOverlayResult.action(
                      ChatOverlayActionKind.react,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // Floating Actions Menu Card
              FloatingActionMenuCard(
                sent: sent,
                hasText: hasText,
                isMine: isMine,
                theme: theme,
                onAction: (action) => Navigator.pop(
                  context,
                  ChatMessageOverlayResult.action(action),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class AnimatedReactionPill extends StatefulWidget {
  const AnimatedReactionPill({
    super.key,
    required this.emojis,
    required this.onSelectEmoji,
    required this.onMoreReactions,
  });

  final List<String> emojis;
  final ValueChanged<String> onSelectEmoji;
  final VoidCallback onMoreReactions;

  @override
  State<AnimatedReactionPill> createState() => _AnimatedReactionPillState();
}

class _AnimatedReactionPillState extends State<AnimatedReactionPill> {
  int? _hoveredIndex;

  void _updateHoverIndex(double localX, double itemWidth) {
    if (itemWidth <= 0) return;
    final index = (localX / itemWidth).floor();
    final clampedIndex = index.clamp(0, widget.emojis.length);

    if (_hoveredIndex != clampedIndex) {
      setState(() {
        _hoveredIndex = clampedIndex;
      });
      ChatHaptics.selection();
    }
  }

  void _clearHoverIndex() {
    if (_hoveredIndex != null) {
      setState(() {
        _hoveredIndex = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final backgroundColor = isDark
        ? const Color(0xFF222732)
        : const Color(0xFFFFFFFF);

    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.black.withValues(alpha: 0.10);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalItems = widget.emojis.length + 1; // Emojis + Plus button
        final itemWidth = math.min(42.0, constraints.maxWidth / totalItems);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (details) =>
              _updateHoverIndex(details.localPosition.dx, itemWidth),
          onPanUpdate: (details) =>
              _updateHoverIndex(details.localPosition.dx, itemWidth),
          onPanEnd: (_) {
            final activeIndex = _hoveredIndex;
            _clearHoverIndex();
            if (activeIndex != null) {
              if (activeIndex < widget.emojis.length) {
                widget.onSelectEmoji(widget.emojis[activeIndex]);
              } else if (activeIndex == widget.emojis.length) {
                widget.onMoreReactions();
              }
            }
          },
          onPanCancel: _clearHoverIndex,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: borderColor, width: 1.4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.emojis.length; i++)
                  _buildEmojiItem(
                    index: i,
                    emoji: widget.emojis[i],
                    width: itemWidth,
                  ),
                _buildPlusButton(
                  index: widget.emojis.length,
                  width: itemWidth,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmojiItem({
    required int index,
    required String emoji,
    required double width,
  }) {
    double scale = 1.0;
    double translateY = 0.0;

    final hovered = _hoveredIndex;
    final isHovered = hovered == index;
    if (hovered != null) {
      final distance = (index - hovered).abs();
      if (distance == 0) {
        scale = 1.70;
        translateY = -15.0;
      } else if (distance == 1) {
        scale = 1.28;
        translateY = -6.0;
      }
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      hitTestBehavior: HitTestBehavior.opaque,
      onEnter: (_) {
        if (_hoveredIndex != index) {
          setState(() => _hoveredIndex = index);
          ChatHaptics.selection();
        }
      },
      onHover: (_) {
        if (_hoveredIndex != index) {
          setState(() => _hoveredIndex = index);
          ChatHaptics.selection();
        }
      },
      onExit: (_) {
        if (_hoveredIndex == index) {
          setState(() => _hoveredIndex = null);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ChatHaptics.lightImpact();
          widget.onSelectEmoji(emoji);
        },
        child: SizedBox(
          width: width,
          height: 38,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: ChatMotionTheme.emphasizedDecelerate,
              transform: Matrix4.translationValues(0, translateY, 0)
                ..scale(scale),
              transformAlignment: Alignment.bottomCenter,
              child: PlayfulAnimatedEmoji(
                emoji: emoji,
                isHovered: isHovered,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlusButton({required int index, required double width}) {
    double scale = 1.0;
    double translateY = 0.0;

    final hovered = _hoveredIndex;
    if (hovered != null) {
      final distance = (index - hovered).abs();
      if (distance == 0) {
        scale = 1.4;
        translateY = -8.0;
      } else if (distance == 1) {
        scale = 1.15;
        translateY = -3.0;
      }
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      hitTestBehavior: HitTestBehavior.opaque,
      onEnter: (_) {
        if (_hoveredIndex != index) {
          setState(() => _hoveredIndex = index);
          ChatHaptics.selection();
        }
      },
      onHover: (_) {
        if (_hoveredIndex != index) {
          setState(() => _hoveredIndex = index);
          ChatHaptics.selection();
        }
      },
      onExit: (_) {
        if (_hoveredIndex == index) {
          setState(() => _hoveredIndex = null);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ChatHaptics.lightImpact();
          widget.onMoreReactions();
        },
        child: SizedBox(
          width: width,
          height: 38,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: ChatMotionTheme.emphasizedDecelerate,
              transform: Matrix4.translationValues(0, translateY, 0)
                ..scale(scale),
              transformAlignment: Alignment.bottomCenter,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.primaryContainer,
                ),
                child: Icon(
                  Icons.add_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FloatingActionMenuCard extends StatelessWidget {
  const FloatingActionMenuCard({
    super.key,
    required this.sent,
    required this.hasText,
    required this.isMine,
    required this.theme,
    required this.onAction,
  });

  final bool sent;
  final bool hasText;
  final bool isMine;
  final ThemeData theme;
  final ValueChanged<ChatOverlayActionKind> onAction;

  @override
  Widget build(BuildContext context) {
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark
        ? const Color(0xEE242934)
        : const Color(0xEEFFFFFF);

    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    final actions = <_ActionItem>[
      if (sent) ...[
        const _ActionItem(
          kind: ChatOverlayActionKind.reply,
          label: 'Reply',
          icon: Icons.reply_rounded,
        ),
        const _ActionItem(
          kind: ChatOverlayActionKind.react,
          label: 'React',
          icon: Icons.add_reaction_outlined,
        ),
        const _ActionItem(
          kind: ChatOverlayActionKind.forward,
          label: 'Forward',
          icon: Icons.forward_rounded,
        ),
      ],
      if (hasText)
        const _ActionItem(
          kind: ChatOverlayActionKind.copy,
          label: 'Copy',
          icon: Icons.copy_rounded,
        ),
      if (isMine && sent) ...[
        const _ActionItem(
          kind: ChatOverlayActionKind.edit,
          label: 'Edit',
          icon: Icons.edit_rounded,
        ),
        const _ActionItem(
          kind: ChatOverlayActionKind.delete,
          label: 'Delete',
          icon: Icons.delete_outline_rounded,
          isDestructive: true,
        ),
      ],
    ];

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 220,
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            for (var i = 0; i < actions.length; i++) ...[
              ChatStagger(
                index: i,
                child: ChatPressScale(
                  triggerHaptic: true,
                  row: true,
                  child: InkWell(
                    onTap: () => onAction(actions[i].kind),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            actions[i].icon,
                            size: 20,
                            color: actions[i].isDestructive
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurface,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              actions[i].label,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: actions[i].isDestructive
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (i < actions.length - 1)
                Divider(
                  height: 1,
                  thickness: 0.5,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                ),
            ],
          ],
        ),
      ),
    ),
    );
  }
}

class _ActionItem {
  const _ActionItem({
    required this.kind,
    required this.label,
    required this.icon,
    this.isDestructive = false,
  });

  final ChatOverlayActionKind kind;
  final String label;
  final IconData icon;
  final bool isDestructive;
}

class PlayfulAnimatedEmoji extends StatefulWidget {
  const PlayfulAnimatedEmoji({
    super.key,
    required this.emoji,
    required this.isHovered,
    this.baseFontSize = 24.0,
  });

  final String emoji;
  final bool isHovered;
  final double baseFontSize;

  @override
  State<PlayfulAnimatedEmoji> createState() => _PlayfulAnimatedEmojiState();
}

class _PlayfulAnimatedEmojiState extends State<PlayfulAnimatedEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _durationForEmoji(widget.emoji),
    );
    if (widget.isHovered) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant PlayfulAnimatedEmoji oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isHovered != oldWidget.isHovered) {
      if (widget.isHovered) {
        _controller.duration = _durationForEmoji(widget.emoji);
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Duration _durationForEmoji(String emoji) {
    switch (emoji) {
      case '😂':
        return const Duration(milliseconds: 580);
      case '❤️':
        return const Duration(milliseconds: 820);
      case '🔥':
        return const Duration(milliseconds: 520);
      case '👍':
        return const Duration(milliseconds: 680);
      case '😮':
        return const Duration(milliseconds: 920);
      case '😢':
        return const Duration(milliseconds: 1000);
      case '👏':
        return const Duration(milliseconds: 600);
      case '🙏':
      default:
        return const Duration(milliseconds: 920);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        double rotation = 0.0;
        double translateY = 0.0;
        double scale = 1.0;

        if (widget.isHovered) {
          final t = _controller.value;
          final sinPhase = math.sin(t * math.pi);

          switch (widget.emoji) {
            case '😂':
              rotation = lerpDouble(-0.14, 0.14, t)!;
              translateY = lerpDouble(0.0, -3.0, sinPhase)!;
              break;
            case '❤️':
              scale = lerpDouble(1.0, 1.20, sinPhase)!;
              break;
            case '🔥':
              rotation = lerpDouble(-0.10, 0.10, t)!;
              scale = lerpDouble(1.0, 1.15, sinPhase)!;
              break;
            case '👍':
              translateY = lerpDouble(0.0, -5.0, sinPhase)!;
              break;
            case '😮':
              scale = lerpDouble(1.0, 1.16, sinPhase)!;
              translateY = lerpDouble(0.0, -3.0, sinPhase)!;
              break;
            case '😢':
              rotation = lerpDouble(-0.08, 0.08, t)!;
              translateY = lerpDouble(0.0, 2.0, sinPhase)!;
              break;
            case '👏':
              scale = lerpDouble(1.0, 1.16, sinPhase)!;
              break;
            case '🙏':
            default:
              scale = lerpDouble(1.0, 1.10, sinPhase)!;
              break;
          }
        }

        return Transform.translate(
          offset: Offset(0, translateY),
          child: Transform.rotate(
            angle: rotation,
            child: Transform.scale(
              scale: scale,
              child: Text(
                widget.emoji,
                style: TextStyle(
                  fontSize: widget.baseFontSize,
                  height: 1.0,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
