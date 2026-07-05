import 'package:chat_app/src/app.dart';
import 'package:chat_app/src/auth_screen.dart';
import 'package:chat_app/src/auth_service.dart';
import 'package:chat_app/src/chat_home_page.dart';
import 'package:chat_app/src/chat_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('renders local preview chat without auth and sends message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());

    expect(find.text('Welcome back'), findsNothing);
    expect(find.text('Design Studio'), findsOneWidget);
    expect(find.text('Samira is typing...'), findsOneWidget);
    expect(find.byTooltip('Sign out'), findsOneWidget);

    await tester.tap(find.text('Design Studio'));
    await tester.pumpAndSettle();

    expect(
      find.text('The new chat layout is in a good place.'),
      findsOneWidget,
    );
    expect(find.text('Typing...'), findsOneWidget);
    expect(find.byKey(const Key('message-status-read')), findsOneWidget);
    expect(find.byKey(const Key('message-status-delivered')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('message-composer')),
      'Hello Supabase',
    );
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(find.text('Hello Supabase'), findsOneWidget);
    expect(find.byKey(const Key('message-status-sent')), findsOneWidget);
  });

  testWidgets('shows typing, online, and active since status priority', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());

    expect(find.text('Samira is typing...'), findsOneWidget);

    await tester.tap(find.text('Design Studio'));
    await tester.pumpAndSettle();
    expect(find.text('Typing...'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to chats'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Product Team'));
    await tester.pumpAndSettle();
    expect(find.text('Online'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to chats'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maria Chen'));
    await tester.pumpAndSettle();
    expect(find.text('Active since 1h ago'), findsOneWidget);
  });

  testWidgets('starts an empty local preview direct message from user search', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());

    await tester.tap(find.byTooltip('New chat'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('new-chat-search')), 'sam');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Samira Haddad'));
    await tester.pumpAndSettle();

    expect(find.text('Samira Haddad'), findsOneWidget);
    expect(find.text('No messages yet.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('message-composer')),
      'Starting a new thread',
    );
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(find.text('Starting a new thread'), findsOneWidget);
  });

  testWidgets('compact chat opens threads, goes back, and signs out', (
    WidgetTester tester,
  ) async {
    var signedOut = false;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatHomePage(
          repository: ChatRepository(),
          onSignOut: () async {
            signedOut = true;
          },
        ),
      ),
    );

    expect(find.text('Messages'), findsOneWidget);
    expect(find.byTooltip('Sign out'), findsOneWidget);

    await tester.tap(find.text('Product Team'));
    await tester.pumpAndSettle();

    expect(
      find.text('The release notes are ready for the build review.'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Back to chats'));
    await tester.pumpAndSettle();

    expect(find.text('Messages'), findsOneWidget);

    await tester.tap(find.byTooltip('Sign out'));
    await tester.pump();

    expect(signedOut, isTrue);
  });

  testWidgets('renders auth screen and switches modes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_wrapAuthPage());

    expect(find.text('Welcome back'), findsOneWidget);

    await _tapText(tester, 'Create account');
    expect(find.text('Create your account'), findsOneWidget);

    await _tapText(tester, 'Sign in');
    await _tapText(tester, 'Forgot password?');
    expect(find.text('Reset your password'), findsOneWidget);

    await _tapText(tester, 'Sign in');
    await _tapText(tester, 'Use phone number');
    expect(find.text('Continue with phone'), findsOneWidget);
  });

  testWidgets('auth form shows validation errors', (WidgetTester tester) async {
    await tester.pumpWidget(_wrapAuthPage());

    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);
  });
}

Widget _wrapAuthPage() {
  return MaterialApp(home: AuthPage(authService: _FakeAuthService()));
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _FakeAuthService implements ChatAuthService {
  @override
  Session? get currentSession => null;

  @override
  User? get currentUser => null;

  @override
  Stream<AuthState> get authStateChanges => const Stream<AuthState>.empty();

  @override
  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AuthResponse> signUpWithEmail({
    required String displayName,
    required String email,
    required String password,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> sendPasswordReset(String email) {
    throw UnimplementedError();
  }

  @override
  Future<UserResponse> updatePassword(String password) {
    throw UnimplementedError();
  }

  @override
  Future<void> sendPhoneOtp(String phone) {
    throw UnimplementedError();
  }

  @override
  Future<AuthResponse> verifyPhoneOtp({
    required String phone,
    required String token,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<bool> signInWithGoogle() {
    throw UnimplementedError();
  }

  @override
  Future<void> signOut() {
    throw UnimplementedError();
  }
}
