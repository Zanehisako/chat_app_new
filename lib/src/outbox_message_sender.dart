import 'chat_models.dart';

abstract interface class OutboxMessageSender {
  bool get isOutboxReady;

  Future<bool> messageExists(String messageId);

  Future<UploadedChatMedia> uploadMediaAttachment({
    required String conversationId,
    required PickedChatMedia pickedMedia,
    required void Function(double progress) onProgress,
    String? messageId,
    bool upsert = false,
  });

  Future<void> sendMessage({
    required String conversationId,
    required String body,
    String? messageId,
    String? replyToMessageId,
    bool isForwarded = false,
  });

  Future<void> sendMediaMessage({
    required String conversationId,
    required String messageId,
    required String body,
    required ChatMedia media,
    String? replyToMessageId,
    bool isForwarded = false,
  });
}

abstract interface class OutboxScopeProvider {
  String? get outboxUserId;

  String? get outboxBackendOrigin;
}
