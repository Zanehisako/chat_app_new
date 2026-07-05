import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

abstract interface class ChatAuthService {
  Session? get currentSession;

  User? get currentUser;

  Stream<AuthState> get authStateChanges;

  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  });

  Future<AuthResponse> signUpWithEmail({
    required String displayName,
    required String email,
    required String password,
  });

  Future<void> sendPasswordReset(String email);

  Future<UserResponse> updatePassword(String password);

  Future<void> sendPhoneOtp(String phone);

  Future<AuthResponse> verifyPhoneOtp({
    required String phone,
    required String token,
  });

  Future<bool> signInWithGoogle();

  Future<void> signOut();
}

class SupabaseAuthService implements ChatAuthService {
  const SupabaseAuthService({required this.client});

  final SupabaseClient client;

  @override
  Session? get currentSession => client.auth.currentSession;

  @override
  User? get currentUser => client.auth.currentUser;

  @override
  Stream<AuthState> get authStateChanges => client.auth.onAuthStateChange;

  @override
  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) {
    return client.auth.signInWithPassword(
      email: _normalizeEmail(email),
      password: password,
    );
  }

  @override
  Future<AuthResponse> signUpWithEmail({
    required String displayName,
    required String email,
    required String password,
  }) {
    return client.auth.signUp(
      email: _normalizeEmail(email),
      password: password,
      emailRedirectTo: SupabaseConfig.authRedirectUrl,
      data: {'display_name': displayName.trim()},
    );
  }

  @override
  Future<void> sendPasswordReset(String email) {
    return client.auth.resetPasswordForEmail(
      _normalizeEmail(email),
      redirectTo: SupabaseConfig.authRedirectUrl,
    );
  }

  @override
  Future<UserResponse> updatePassword(String password) {
    return client.auth.updateUser(UserAttributes(password: password));
  }

  @override
  Future<void> sendPhoneOtp(String phone) {
    return client.auth.signInWithOtp(
      phone: _normalizePhone(phone),
      shouldCreateUser: true,
    );
  }

  @override
  Future<AuthResponse> verifyPhoneOtp({
    required String phone,
    required String token,
  }) {
    return client.auth.verifyOTP(
      phone: _normalizePhone(phone),
      token: token.trim(),
      type: OtpType.sms,
    );
  }

  @override
  Future<bool> signInWithGoogle() {
    return client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: SupabaseConfig.authRedirectUrl,
    );
  }

  @override
  Future<void> signOut() {
    return client.auth.signOut();
  }
}

String _normalizeEmail(String email) => email.trim().toLowerCase();

String _normalizePhone(String phone) {
  return phone.trim().replaceAll(RegExp(r'[\s()-]'), '');
}
