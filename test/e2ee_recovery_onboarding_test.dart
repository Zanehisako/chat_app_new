import 'dart:typed_data';

import 'package:chat_app/src/chat_home_page.dart';
import 'package:chat_app/src/chat_repository.dart';
import 'package:chat_app/src/e2ee_crypto_service.dart';
import 'package:chat_app/src/e2ee_draft_protector.dart';
import 'package:chat_app/src/outbox_database.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'requires recovery phrase re-entry before creating the authenticated outbox',
    (tester) async {
      final repository = _RecoveryOnboardingRepository();
      final database = OutboxDatabase.forTesting(NativeDatabase.memory());

      await tester.pumpWidget(
        MaterialApp(
          home: ChatHomePage(repository: repository, outboxDatabase: database),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Save your recovery phrase'), findsOneWidget);
      expect(repository.draftProtectorRequests, 0);

      await tester.enterText(
        find.byKey(const Key('e2ee-recovery-phrase-confirmation')),
        repository.phrase,
      );
      final savedPhrase = find.byType(Checkbox);
      await tester.ensureVisible(savedPhrase);
      await tester.tap(savedPhrase);
      await tester.pump();
      final confirm = find.text('Confirm and continue');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(repository.confirmedPhrase, repository.phrase);
      expect(repository.draftProtectorRequests, 1);
      expect(find.text('Save your recovery phrase'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await database.close();
    },
  );

  testWidgets('restores a missing local encryption identity from the phrase', (
    tester,
  ) async {
    final repository = _RecoveryOnboardingRepository(requiresRestore: true);
    final database = OutboxDatabase.forTesting(NativeDatabase.memory());

    await tester.pumpWidget(
      MaterialApp(
        home: ChatHomePage(repository: repository, outboxDatabase: database),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Restore encrypted messages'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('e2ee-recovery-phrase-restore')),
      repository.phrase,
    );
    await tester.pump();
    final restore = find.text('Restore and continue');
    await tester.ensureVisible(restore);
    await tester.tap(restore);
    await tester.pumpAndSettle();

    expect(repository.restoredPhrase, repository.phrase);
    expect(repository.draftProtectorRequests, 1);
    expect(find.text('Restore encrypted messages'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await database.close();
  });

  testWidgets('removes the recovery dialog immediately when chat is disposed', (
    tester,
  ) async {
    final repository = _RecoveryOnboardingRepository();
    final database = OutboxDatabase.forTesting(NativeDatabase.memory());
    final showChat = ValueNotifier<bool>(true);
    addTearDown(showChat.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: showChat,
          builder: (context, visible, child) {
            if (!visible) return const Text('Signed out');
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: ChatHomePage(
                repository: repository,
                outboxDatabase: database,
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Save your recovery phrase'), findsOneWidget);

    showChat.value = false;
    await tester.pump();
    await tester.pump();

    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text('Save your recovery phrase'), findsNothing);

    await tester.pumpAndSettle();
    await database.close();
  });
}

class _RecoveryOnboardingRepository extends ChatRepository {
  _RecoveryOnboardingRepository({this.requiresRestore = false});

  static const _phrase =
      'alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima '
      'mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray';

  String get phrase => _phrase;

  bool _confirmed = false;
  final bool requiresRestore;
  String? confirmedPhrase;
  String? restoredPhrase;
  int draftProtectorRequests = 0;

  @override
  bool get isConnected => true;

  @override
  String? get outboxUserId => 'recovery-test-user';

  @override
  String? get outboxBackendOrigin => 'https://project.supabase.co';

  @override
  Future<E2eeReadyState> e2eeReadyState() async {
    if (!_confirmed) {
      return E2eeReadyState(
        requiresRecoveryPhraseConfirmation: !requiresRestore,
        requiresRecoveryPhraseRestore: requiresRestore,
      );
    }
    return const E2eeReadyState(
      account: E2eeAccount(
        userId: 'recovery-test-user',
        recoveryPublicKey: 'recovery-key',
        signingPublicKey: 'account-signing-key',
      ),
      device: E2eeDevice(
        id: 'recovery-test-device',
        userId: 'recovery-test-user',
        encryptionPublicKey: 'device-encryption-key',
        signingPublicKey: 'device-signing-key',
        certificate: 'device-certificate',
      ),
    );
  }

  @override
  Future<String?> recoveryPhrase() async => phrase;

  @override
  Future<void> confirmRecoveryPhrase(String value) async {
    if (value != phrase) {
      throw StateError('Unexpected phrase');
    }
    confirmedPhrase = value;
    _confirmed = true;
  }

  @override
  Future<void> restoreE2eeRecoveryPhrase(String value) async {
    if (value != phrase) {
      throw StateError('Unexpected phrase');
    }
    restoredPhrase = value;
    _confirmed = true;
  }

  @override
  Future<E2eeDraftProtector> e2eeDraftProtector() async {
    if (!_confirmed) {
      throw StateError('Recovery phrase must be confirmed first.');
    }
    draftProtectorRequests += 1;
    return const _NoopDraftProtector();
  }

  @override
  Future<void> updateLastSeen() async {}

  @override
  Future<void> disposeRealtime() async {}
}

class _NoopDraftProtector implements E2eeDraftProtector {
  const _NoopDraftProtector();

  @override
  Future<Uint8List> protectDraft({
    required E2eeDraftProtectionContext context,
    required Uint8List plaintext,
  }) async => Uint8List.fromList(plaintext);

  @override
  Future<Uint8List> unprotectDraft({
    required E2eeDraftProtectionContext context,
    required Uint8List protectedDraft,
  }) async => Uint8List.fromList(protectedDraft);
}
