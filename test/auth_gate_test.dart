import 'dart:async';

import 'package:chat_app/src/auth_gate.dart';
import 'package:chat_app/src/auth_screen.dart';
import 'package:chat_app/src/auth_service.dart';
import 'package:chat_app/src/chat_home_page.dart';
import 'package:chat_app/src/chat_repository.dart';
import 'package:chat_app/src/motion/chat_motion_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets(
    'AuthGate caches repositories and immediately replaces auth surfaces',
    (tester) async {
      final client = SupabaseClient('https://example.supabase.co', 'test-key');
      client.auth.stopAutoRefresh();
      final authService = _FakeAuthService();
      final repositories = <ChatRepository>[];
      addTearDown(() async {
        await authService.dispose();
        client.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: AuthGate(
            client: client,
            authService: authService,
            repositoryFactory: (_) {
              final repository = ChatRepository();
              repositories.add(repository);
              return repository;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(AuthPage), findsOneWidget);
      expect(find.byType(ChatHomePage), findsNothing);
      final signedOutEntrance = tester.state(
        _entranceFor(find.byType(AuthPage)),
      );

      final userOneSession = _sessionFor('user-1');
      authService.emit(AuthChangeEvent.signedIn, userOneSession);
      await tester.pump();

      final firstChatFinder = find.byType(ChatHomePage);
      expect(firstChatFinder, findsOneWidget);
      expect(find.byType(AuthPage), findsNothing);
      expect(
        find.ancestor(
          of: firstChatFinder,
          matching: find.byType(AnimatedSwitcher),
        ),
        findsNothing,
      );
      final firstChat = tester.widget<ChatHomePage>(firstChatFinder);
      final firstRepository = firstChat.repository;
      final firstChatState = tester.state(firstChatFinder);
      final firstChatEntrance = tester.state(_entranceFor(firstChatFinder));
      expect(firstChat.key, const ValueKey<String>('user-1'));
      expect(firstChatEntrance, isNot(same(signedOutEntrance)));
      expect(repositories, hasLength(1));

      await tester.pump(const Duration(milliseconds: 500));
      authService.emit(AuthChangeEvent.tokenRefreshed, userOneSession);
      await tester.pump();

      final refreshedChat = tester.widget<ChatHomePage>(firstChatFinder);
      expect(refreshedChat.repository, same(firstRepository));
      expect(tester.state(firstChatFinder), same(firstChatState));
      expect(
        tester.state(_entranceFor(firstChatFinder)),
        same(firstChatEntrance),
      );
      expect(repositories, hasLength(1));

      authService.emit(AuthChangeEvent.passwordRecovery, userOneSession);
      await tester.pump();

      expect(find.byType(ChatHomePage), findsNothing);
      expect(find.byType(AuthPage), findsOneWidget);
      expect(
        tester.widget<AuthPage>(find.byType(AuthPage)).initialMode,
        AuthMode.resetPassword,
      );
      expect(
        tester.state(_entranceFor(find.byType(AuthPage))),
        isNot(same(firstChatEntrance)),
      );

      await tester.pump(const Duration(milliseconds: 500));
      authService.emit(AuthChangeEvent.signedOut, null);
      await tester.pump();

      expect(find.byType(ChatHomePage), findsNothing);
      expect(
        tester.widget<AuthPage>(find.byType(AuthPage)).initialMode,
        AuthMode.signIn,
      );

      authService.emit(AuthChangeEvent.signedIn, userOneSession);
      await tester.pump();

      final remountedUserOneChat = tester.widget<ChatHomePage>(firstChatFinder);
      expect(remountedUserOneChat.key, const ValueKey<String>('user-1'));
      expect(remountedUserOneChat.repository, isNot(same(firstRepository)));
      final remountedUserOneRepository = remountedUserOneChat.repository;
      final remountedUserOneState = tester.state(firstChatFinder);
      final remountedUserOneEntrance = tester.state(
        _entranceFor(firstChatFinder),
      );
      expect(repositories, hasLength(2));

      final userTwoSession = _sessionFor('user-2');
      authService.emit(AuthChangeEvent.tokenRefreshed, userTwoSession);
      await tester.pump();

      final userTwoChat = tester.widget<ChatHomePage>(firstChatFinder);
      expect(userTwoChat.key, const ValueKey<String>('user-2'));
      expect(userTwoChat.repository, isNot(same(remountedUserOneRepository)));
      expect(tester.state(firstChatFinder), isNot(same(remountedUserOneState)));
      expect(
        tester.state(_entranceFor(firstChatFinder)),
        isNot(same(remountedUserOneEntrance)),
      );
      expect(repositories, hasLength(3));

      authService.emit(AuthChangeEvent.signedOut, null);
      await tester.pump();

      expect(find.byType(ChatHomePage), findsNothing);
      expect(find.byType(AuthPage), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}

Finder _entranceFor(Finder child) {
  return find.ancestor(of: child, matching: find.byType(ChatEntrance)).first;
}

class _FakeAuthService implements ChatAuthService {
  final StreamController<AuthState> _states =
      StreamController<AuthState>.broadcast(sync: true);
  Session? _session;

  void emit(AuthChangeEvent event, Session? session) {
    _session = session;
    _states.add(AuthState(event, session));
  }

  Future<void> dispose() => _states.close();

  @override
  Stream<AuthState> get authStateChanges => _states.stream;

  @override
  Session? get currentSession => _session;

  @override
  User? get currentUser => _session?.user;

  @override
  Future<void> sendPasswordReset(String email) => throw UnimplementedError();

  @override
  Future<void> sendPhoneOtp(String phone) => throw UnimplementedError();

  @override
  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<bool> signInWithGoogle() async => false;

  @override
  Future<void> signOut() async {
    emit(AuthChangeEvent.signedOut, null);
  }

  @override
  Future<AuthResponse> signUpWithEmail({
    required String displayName,
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<UserResponse> updatePassword(String password) =>
      throw UnimplementedError();

  @override
  Future<AuthResponse> verifyPhoneOtp({
    required String phone,
    required String token,
  }) => throw UnimplementedError();
}

Session _sessionFor(String userId) {
  return Session(
    accessToken: 'test-access-token-$userId',
    tokenType: 'bearer',
    user: User(
      id: userId,
      appMetadata: const <String, dynamic>{},
      userMetadata: const <String, dynamic>{'display_name': 'Test User'},
      aud: 'authenticated',
      email: '$userId@example.com',
      createdAt: DateTime.utc(2026).toIso8601String(),
    ),
  );
}
