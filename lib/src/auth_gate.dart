import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_screen.dart';
import 'auth_service.dart';
import 'chat_home_page.dart';
import 'chat_repository.dart';
import 'motion/chat_motion_widgets.dart';
import 'notification_service.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.client,
    @visibleForTesting this.authService,
    @visibleForTesting this.repositoryFactory,
  });

  final SupabaseClient client;
  final ChatAuthService? authService;
  final ChatRepository Function(SupabaseClient client)? repositoryFactory;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final ChatAuthService _authService;
  StreamSubscription<AuthState>? _authSubscription;
  Session? _session;
  ChatRepository? _repository;
  String? _repositoryUserId;
  bool _isRecoveringPassword = false;
  String? _authStreamError;

  @override
  void initState() {
    super.initState();
    _authService =
        widget.authService ?? SupabaseAuthService(client: widget.client);
    _session = _authService.currentSession;
    final repository = _updateRepositoryFor(_session);
    unawaited(_syncCurrentProfile(repository));
    _authSubscription = _authService.authStateChanges.listen(
      _handleAuthState,
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted) return;
        setState(() {
          _authStreamError = 'Auth session changed. Please try again.';
        });
      },
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session != null && !_isRecoveringPassword) {
      final userId = session.user.id;
      final repository = _repository;
      assert(repository != null && _repositoryUserId == userId);
      return ChatEntrance(
        key: ValueKey<String>('chat-$userId'),
        child: ChatHomePage(
          key: ValueKey<String>(userId),
          repository: repository!,
          onSignOut: _signOut,
        ),
      );
    }

    final initialMode = _isRecoveringPassword
        ? AuthMode.resetPassword
        : AuthMode.signIn;
    return ChatEntrance(
      key: ValueKey<String>('auth-${initialMode.name}'),
      child: AuthPage(
        key: ValueKey(initialMode),
        authService: _authService,
        initialMode: initialMode,
        bannerMessage: _authStreamError,
        onPasswordResetComplete: _handlePasswordResetComplete,
      ),
    );
  }

  void _handleAuthState(AuthState state) {
    if (!mounted) return;
    final repository = _updateRepositoryFor(state.session);
    setState(() {
      _session = state.session;
      _authStreamError = null;
      if (state.event == AuthChangeEvent.passwordRecovery) {
        _isRecoveringPassword = true;
      } else if (state.event == AuthChangeEvent.signedOut) {
        _isRecoveringPassword = false;
      } else if (state.event == AuthChangeEvent.signedIn &&
          !_isRecoveringPassword) {
        _isRecoveringPassword = false;
      }
    });

    if (state.session != null) {
      unawaited(_syncCurrentProfile(repository));
      unawaited(
        NotificationService.instance.refreshRegistration(client: widget.client),
      );
    }
  }

  void _handlePasswordResetComplete() {
    final session = _authService.currentSession;
    _updateRepositoryFor(session);
    setState(() {
      _isRecoveringPassword = false;
      _session = session;
    });
  }

  ChatRepository? _updateRepositoryFor(Session? session) {
    final userId = session?.user.id;
    if (userId == null) {
      _repository = null;
      _repositoryUserId = null;
      return null;
    }

    final repository = _repository;
    if (_repositoryUserId == userId && repository != null) {
      return repository;
    }

    final replacement =
        widget.repositoryFactory?.call(widget.client) ??
        ChatRepository(client: widget.client);
    _repository = replacement;
    _repositoryUserId = userId;
    return replacement;
  }

  Future<void> _signOut() async {
    final userId = _session?.user.id;
    try {
      if (userId != null) {
        await NotificationService.instance.unregisterDeviceToken(
          client: widget.client,
          userId: userId,
        );
      }
    } finally {
      await _authService.signOut();
    }
  }

  Future<void> _syncCurrentProfile(ChatRepository? repository) async {
    if (repository == null) return;
    try {
      await repository.upsertCurrentProfile();
    } catch (_) {
      // Profile sync is best-effort; messaging still handles backend errors.
    }
  }
}
