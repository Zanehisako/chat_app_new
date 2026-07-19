import 'package:flutter/material.dart';

import 'chat_motion.dart';
import 'chat_motion_widgets.dart';

final RouteObserver<PageRoute<dynamic>> chatRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

class ChatPageTransitionsBuilder extends PageTransitionsBuilder {
  const ChatPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final policy = context.chatMotion;
    if (policy.reduceMotion || route.isFirst) {
      return child;
    }

    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.035, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

class ChatPageRoute<T> extends PageRouteBuilder<T> {
  ChatPageRoute({
    required BuildContext context,
    required WidgetBuilder builder,
    RouteSettings? settings,
    bool fullscreenDialog = false,
  }) : this._(
         policy: ChatMotionPolicy.of(context),
         builder: builder,
         settings: settings,
         fullscreenDialog: fullscreenDialog,
       );

  ChatPageRoute._({
    required ChatMotionPolicy policy,
    required WidgetBuilder builder,
    super.settings,
    super.fullscreenDialog,
  }) : super(
         transitionDuration: policy.duration(policy.theme.standardDuration),
         reverseTransitionDuration: policy.duration(policy.theme.microDuration),
         pageBuilder: (context, animation, secondaryAnimation) =>
             builder(context),
         transitionsBuilder: (context, animation, secondaryAnimation, child) {
           if (policy.reduceMotion) return child;
           final curved = CurvedAnimation(
             parent: animation,
             curve: Curves.easeOutCubic,
             reverseCurve: Curves.easeInCubic,
           );
           return FadeTransition(
             opacity: curved,
             child: SlideTransition(
               position: Tween<Offset>(
                 begin: Offset(policy.theme.routeOffset / 400, 0),
                 end: Offset.zero,
               ).animate(curved),
               child: child,
             ),
           );
         },
       );
}

class ChatMediaPageRoute<T> extends PageRouteBuilder<T> {
  ChatMediaPageRoute({
    required BuildContext context,
    required WidgetBuilder builder,
    RouteSettings? settings,
  }) : this._(
         policy: ChatMotionPolicy.of(context),
         builder: builder,
         settings: settings,
       );

  ChatMediaPageRoute._({
    required ChatMotionPolicy policy,
    required WidgetBuilder builder,
    super.settings,
  }) : super(
         opaque: false,
         barrierColor: Colors.black,
         transitionDuration: policy.duration(policy.theme.emphasizedDuration),
         reverseTransitionDuration: policy.duration(
           policy.theme.standardDuration,
         ),
         pageBuilder: (context, animation, secondaryAnimation) =>
             builder(context),
         transitionsBuilder: (context, animation, secondaryAnimation, child) {
           if (policy.reduceMotion) return child;
           final curved = CurvedAnimation(
             parent: animation,
             curve: Curves.easeOutCubic,
             reverseCurve: Curves.easeInCubic,
           );
           return FadeTransition(opacity: curved, child: child);
         },
       );
}

class ChatDialogRoute<T> extends RawDialogRoute<T> {
  ChatDialogRoute({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    Color barrierColor = const Color(0x8A000000),
    String? barrierLabel,
    RouteSettings? settings,
    bool useSafeArea = true,
  }) : this._(
         policy: ChatMotionPolicy.of(context),
         builder: builder,
         barrierDismissible: barrierDismissible,
         barrierColor: barrierColor,
         barrierLabel:
             barrierLabel ??
             MaterialLocalizations.of(context).modalBarrierDismissLabel,
         settings: settings,
         useSafeArea: useSafeArea,
       );

  ChatDialogRoute._({
    required ChatMotionPolicy policy,
    required WidgetBuilder builder,
    super.barrierDismissible,
    required Color barrierColor,
    required String barrierLabel,
    super.settings,
    required bool useSafeArea,
  }) : super(
         barrierColor: barrierColor,
         barrierLabel: barrierLabel,
         transitionDuration: policy.duration(policy.theme.standardDuration),
         pageBuilder: (context, animation, secondaryAnimation) {
           final child = Builder(builder: builder);
           return useSafeArea ? SafeArea(child: child) : child;
         },
         transitionBuilder: (context, animation, secondaryAnimation, child) {
           if (policy.reduceMotion) return child;
           final curved = CurvedAnimation(
             parent: animation,
             curve: Curves.easeOutCubic,
             reverseCurve: Curves.easeInCubic,
           );
           return FadeTransition(
             opacity: curved,
             child: ScaleTransition(
               scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
               child: child,
             ),
           );
         },
       );
}

Future<T?> showChatDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color barrierColor = const Color(0x8A000000),
  String? barrierLabel,
  bool useRootNavigator = true,
  bool useSafeArea = true,
  RouteSettings? routeSettings,
}) {
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    ChatDialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      settings: routeSettings,
      useSafeArea: useSafeArea,
    ),
  );
}

Future<T?> showChatModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  RouteSettings? routeSettings,
}) {
  final policy = context.chatMotion;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    routeSettings: routeSettings,
    sheetAnimationStyle: AnimationStyle(
      duration: policy.duration(policy.theme.standardDuration),
      reverseDuration: policy.duration(policy.theme.microDuration),
    ),
    builder: (context) => ChatEntrance(
      beginOffset: Offset(0, policy.offset(policy.theme.standardOffset)),
      beginScale: 1,
      duration: policy.theme.standardDuration,
      child: Builder(builder: builder),
    ),
  );
}
