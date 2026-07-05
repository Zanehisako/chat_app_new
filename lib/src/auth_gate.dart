import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_screen.dart';
import 'auth_service.dart';
import 'chat_home_page.dart';
import 'chat_repository.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.client});

  final SupabaseClient client;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final ChatAuthService _authService;
  StreamSubscription<AuthState>? _authSubscription;
  Session? _session;
  bool _isRecoveringPassword = false;
  String? _authStreamError;

  @override
  void initState() {
    super.initState();
    _authService = SupabaseAuthService(client: widget.client);
    _session = _authService.currentSession;
    _authSubscription = _authService.authStateChanges.listen(
      _handleAuthState,
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted) {
          return;
        }

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
    if (_session != null && !_isRecoveringPassword) {
      return ChatHomePage(
        repository: ChatRepository(client: widget.client),
        onSignOut: _authService.signOut,
      );
    }

    final initialMode = _isRecoveringPassword
        ? AuthMode.resetPassword
        : AuthMode.signIn;

    return AuthPage(
      key: ValueKey(initialMode),
      authService: _authService,
      initialMode: initialMode,
      bannerMessage: _authStreamError,
      onPasswordResetComplete: () {
        setState(() {
          _isRecoveringPassword = false;
          _session = _authService.currentSession;
        });
      },
    );
  }

  void _handleAuthState(AuthState state) {
    if (!mounted) {
      return;
    }

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
  }
}
