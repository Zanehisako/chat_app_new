import 'dart:convert';
import 'dart:typed_data';

/// Encrypts queued message content before it is written to the durable outbox.
///
/// This deliberately sits at the outbox boundary instead of exposing the
/// protocol implementation to Drift. Implementations must bind the protected
/// bytes to [E2eeDraftProtectionContext] and must never return plaintext.
abstract interface class E2eeDraftProtector {
  Future<Uint8List> protectDraft({
    required E2eeDraftProtectionContext context,
    required Uint8List plaintext,
  });

  Future<Uint8List> unprotectDraft({
    required E2eeDraftProtectionContext context,
    required Uint8List protectedDraft,
  });
}

/// Stable identifiers bound into an encrypted outbox draft.
///
/// A draft may only be restored for the exact account, backend, conversation,
/// and message id that created it. This prevents a valid local ciphertext from
/// being replayed into another queued-message row.
class E2eeDraftProtectionContext {
  const E2eeDraftProtectionContext({
    required this.backendOrigin,
    required this.userId,
    required this.conversationId,
    required this.draftId,
  });

  final String backendOrigin;
  final String userId;
  final String conversationId;
  final String draftId;

  Map<String, String> toJson() {
    return {
      'backend_origin': backendOrigin,
      'user_id': userId,
      'conversation_id': conversationId,
      'draft_id': draftId,
    };
  }

  /// Canonical AEAD additional data for implementations that support it.
  ///
  /// A list is used instead of a map so the byte sequence is stable across
  /// Dart runtimes and does not depend on map key ordering.
  Uint8List get additionalData => Uint8List.fromList(
    utf8.encode(
      jsonEncode([
        'chat-app.outbox-draft/v1',
        backendOrigin,
        userId,
        conversationId,
        draftId,
      ]),
    ),
  );

  bool matchesJson(Object? value) {
    if (value is! Map) {
      return false;
    }
    return value['backend_origin']?.toString() == backendOrigin &&
        value['user_id']?.toString() == userId &&
        value['conversation_id']?.toString() == conversationId &&
        value['draft_id']?.toString() == draftId;
  }
}
