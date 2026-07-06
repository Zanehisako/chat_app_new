import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_app/src/app.dart';
import 'package:chat_app/src/auth_screen.dart';
import 'package:chat_app/src/auth_service.dart';
import 'package:chat_app/src/chat_home_page.dart';
import 'package:chat_app/src/chat_models.dart';
import 'package:chat_app/src/chat_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  testWidgets('selects a GIPHY GIF, stages upload, and sends caption', (
    WidgetTester tester,
  ) async {
    final repository = _MediaChatRepository();

    await tester.pumpWidget(
      MaterialApp(home: ChatHomePage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old Peer'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GIF'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('giphy-search')), findsOneWidget);
    await tester.tap(find.byKey(const Key('giphy-result-giphy-1')));
    await tester.pump();

    expect(find.byKey(const Key('staged-media-attachment')), findsOneWidget);
    expect(find.textContaining('Uploading 42%'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.textContaining('Ready'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('message-composer')),
      'Perfect reaction',
    );
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(repository.sentBody, 'Perfect reaction');
    expect(repository.sentMedia?.mimeType, 'image/gif');
    expect(find.byKey(const Key('staged-media-attachment')), findsNothing);
  });

  testWidgets('opens media bubble in full-screen viewer', (
    WidgetTester tester,
  ) async {
    final repository = _MessagesChatRepository([
      ChatMessage(
        id: 'media-1',
        threadId: 'conversation-1',
        senderId: ChatSeed.localUserId,
        senderName: 'You',
        body: 'Local GIF',
        createdAt: DateTime.now(),
        isMine: true,
        isDelivered: true,
        isRead: false,
        messageType: ChatMessageType.gif,
        media: ChatMedia(
          bucket: ChatRepository.mediaBucket,
          path: 'conversation-1/local-preview-user/media-1.gif',
          mimeType: 'image/gif',
          sizeBytes: _transparentGif.length,
          width: 1,
          height: 1,
          originalName: 'local.gif',
          localBytes: _transparentGif,
        ),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(home: ChatHomePage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old Peer'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('media-preview-media-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('media-viewer-media-1')), findsOneWidget);
  });

  testWidgets('downloads media from the bubble and full-screen viewer', (
    WidgetTester tester,
  ) async {
    final repository = _DownloadChatRepository([
      ChatMessage(
        id: 'media-1',
        threadId: 'conversation-1',
        senderId: ChatSeed.localUserId,
        senderName: 'You',
        body: 'Local GIF',
        createdAt: DateTime.now(),
        isMine: true,
        isDelivered: true,
        isRead: false,
        messageType: ChatMessageType.gif,
        media: ChatMedia(
          bucket: ChatRepository.mediaBucket,
          path: 'conversation-1/local-preview-user/media-1.gif',
          mimeType: 'image/gif',
          sizeBytes: _transparentGif.length,
          width: 1,
          height: 1,
          originalName: 'local.gif',
          localBytes: _transparentGif,
        ),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(home: ChatHomePage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old Peer'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('media-download-media-1')));
    await tester.pumpAndSettle();

    expect(repository.saveCount, 1);
    expect(repository.savedMedia?.originalName, 'local.gif');
    expect(find.text('Media downloaded.'), findsOneWidget);
    expect(find.byKey(const Key('media-viewer-media-1')), findsNothing);

    await tester.tap(find.byKey(const Key('media-preview-media-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('media-viewer-download-media-1')));
    await tester.pumpAndSettle();

    expect(repository.saveCount, 2);
  });

  testWidgets('renders voice message waveform and downloads audio', (
    WidgetTester tester,
  ) async {
    final repository = _DownloadChatRepository([
      ChatMessage(
        id: 'voice-1',
        threadId: 'conversation-1',
        senderId: ChatSeed.localUserId,
        senderName: 'You',
        body: '',
        createdAt: DateTime.now(),
        isMine: true,
        isDelivered: true,
        isRead: false,
        messageType: ChatMessageType.voice,
        media: ChatMedia(
          bucket: ChatRepository.mediaBucket,
          path: 'conversation-1/local-preview-user/voice-1.wav',
          mimeType: 'audio/wav',
          sizeBytes: _tinyWav.length,
          duration: const Duration(seconds: 7),
          waveform: const [0.2, 0.7, 0.4, 0.9, 0.3, 0.6],
          originalName: 'voice-1.wav',
          localBytes: _tinyWav,
        ),
      ),
    ]);

    await tester.pumpWidget(
      MaterialApp(home: ChatHomePage(repository: repository)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old Peer'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('voice-preview-voice-1')), findsOneWidget);
    expect(find.text('0:07'), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice-download-voice-1')));
    await tester.pumpAndSettle();

    expect(repository.saveCount, 1);
    expect(repository.savedMedia?.mimeType, 'audio/wav');
    expect(find.text('Media downloaded.'), findsOneWidget);
  });

  testWidgets('opens profile page and updates local profile info', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());

    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();

    expect(find.text('Profile'), findsOneWidget);
    expect(find.byKey(const Key('profile-display-name')), findsOneWidget);
    expect(find.text('local-preview-user'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('profile-display-name')),
      'Mina Clarke',
    );
    await tester.enterText(
      find.byKey(const Key('profile-email')),
      'mina@example.com',
    );
    await tester.enterText(find.byKey(const Key('profile-phone')), '+15551234');
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();

    expect(find.text('Mina Clarke'), findsWidgets);
    expect(find.text('Profile updated.'), findsOneWidget);
  });

  testWidgets('refreshes peer profile when opening a conversation', (
    WidgetTester tester,
  ) async {
    final repository = _RefreshingChatRepository();

    await tester.pumpWidget(
      MaterialApp(home: ChatHomePage(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Old Peer'), findsOneWidget);
    expect(repository.profileFetchCount, 0);

    await tester.tap(find.text('Old Peer'));
    await tester.pumpAndSettle();

    expect(repository.profileFetchCount, 1);
    expect(find.text('Fresh Peer'), findsOneWidget);
  });

  testWidgets('pulls to refresh conversations', (WidgetTester tester) async {
    final repository = _RefreshingChatRepository();

    await tester.pumpWidget(
      MaterialApp(home: ChatHomePage(repository: repository)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Old Peer'), findsOneWidget);

    await tester.drag(find.byType(ListView).first, const Offset(0, 320));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(repository.threadFetchCount, 1);
    expect(find.text('Refreshed Peer'), findsOneWidget);
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

  test('parses media and legacy text message rows', () {
    final mediaMessage = ChatMessage.fromSupabase({
      'id': 'm1',
      'conversation_id': 'conversation-1',
      'sender_id': 'user-1',
      'sender_name': 'Mina',
      'body': 'A GIF',
      'created_at': DateTime.utc(2026).toIso8601String(),
      'message_type': 'gif',
      'media_bucket': ChatRepository.mediaBucket,
      'media_path': 'conversation-1/user-1/m1.gif',
      'media_mime_type': 'image/gif',
      'media_size_bytes': 42,
      'media_width': 320,
      'media_height': 180,
      'media_original_name': 'reaction.gif',
    }, localUserId: 'user-2');

    expect(mediaMessage.messageType, ChatMessageType.gif);
    expect(mediaMessage.media?.path, 'conversation-1/user-1/m1.gif');
    expect(mediaMessage.media?.aspectRatio, closeTo(16 / 9, 0.01));

    final voiceMessage = ChatMessage.fromSupabase({
      'id': 'm3',
      'conversation_id': 'conversation-1',
      'sender_id': 'user-2',
      'sender_name': 'You',
      'body': '',
      'created_at': DateTime.utc(2026).toIso8601String(),
      'message_type': 'voice',
      'media_bucket': ChatRepository.mediaBucket,
      'media_path': 'conversation-1/user-2/m3.wav',
      'media_mime_type': 'audio/wav',
      'media_size_bytes': 128,
      'media_duration_ms': 1234,
      'media_waveform': [0.1, '0.5', 2],
      'media_original_name': 'voice.wav',
    }, localUserId: 'user-2');

    expect(voiceMessage.messageType, ChatMessageType.voice);
    expect(voiceMessage.media?.isVoice, isTrue);
    expect(voiceMessage.media?.duration, const Duration(milliseconds: 1234));
    expect(voiceMessage.media?.waveform, [0.1, 0.5, 1.0]);

    final textMessage = ChatMessage.fromSupabase({
      'id': 'm2',
      'conversation_id': 'conversation-1',
      'sender_id': 'user-2',
      'sender_name': 'You',
      'body': 'Legacy text',
      'created_at': DateTime.utc(2026).toIso8601String(),
    }, localUserId: 'user-2');

    expect(textMessage.messageType, ChatMessageType.text);
    expect(textMessage.media, isNull);
    expect(textMessage.body, 'Legacy text');
  });

  test('builds Supabase media upload URL with bucket and encoded path', () {
    final uri = ChatRepository.chatMediaUploadUriForTesting(
      storageUrl: 'https://project.supabase.co/storage/v1',
      objectPath: 'conversation id/user id/message 1.png',
    );

    expect(
      uri.toString(),
      'https://project.supabase.co/storage/v1/object/chat-media/'
      'conversation%20id/user%20id/message%201.png',
    );
  });

  test(
    'multipart media upload reports progress before final success',
    () async {
      final progress = <double>[];

      final client = MockClient.streaming((request, bodyStream) async {
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/storage/v1/object/chat-media/conversation/user/m1.png',
        );
        expect(request.headers['authorization'], 'Bearer token');
        expect(request.headers['x-upsert'], 'false');
        expect(
          request.headers['content-type'],
          startsWith('multipart/form-data'),
        );

        var receivedBytes = 0;
        await for (final chunk in bodyStream) {
          receivedBytes += chunk.length;
        }

        expect(receivedBytes, greaterThan(128 * 1024));
        expect(progress.any((value) => value > 0 && value < 1), isTrue);
        expect(progress.last, lessThan(1));

        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode('{"Key":"chat-media/conversation/user/m1.png"}'),
          ),
          200,
        );
      });

      await ChatRepository.uploadBytesWithProgressForTesting(
        uri: Uri.parse(
          'https://project.supabase.co/storage/v1'
          '/object/chat-media/conversation/user/m1.png',
        ),
        headers: const {'authorization': 'Bearer token'},
        bytes: Uint8List.fromList(
          List<int>.generate(160 * 1024, (index) => index % 251),
        ),
        fileName: 'm1.png',
        mimeType: 'image/png',
        onProgress: progress.add,
        httpClient: client,
      );

      expect(progress.first, 0);
      expect(progress.where((value) => value > 0 && value < 1), isNotEmpty);
      expect(progress.last, 1);
    },
  );

  test(
    'multipart media upload failure includes status and body details',
    () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              '{"error":"new row violates row-level security policy"}',
            ),
          ),
          403,
          reasonPhrase: 'Forbidden',
        );
      });

      final call = ChatRepository.uploadBytesWithProgressForTesting(
        uri: Uri.parse(
          'https://project.supabase.co/storage/v1'
          '/object/chat-media/conversation/user/m1.png',
        ),
        headers: const {'authorization': 'Bearer token'},
        bytes: Uint8List.fromList([1, 2, 3]),
        fileName: 'm1.png',
        mimeType: 'image/png',
        onProgress: (_) {},
        httpClient: client,
      );

      await expectLater(
        call,
        throwsA(
          isA<ChatMediaUploadException>()
              .having((error) => error.statusCode, 'statusCode', 403)
              .having(
                (error) => error.details,
                'details',
                allOf(
                  contains('HTTP 403 Forbidden'),
                  contains('row-level security'),
                  contains('storage.objects RLS'),
                ),
              ),
        ),
      );
    },
  );

  test(
    'multipart upload missing authorization error gives auth hint',
    () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              '{"statusCode":"400","error":"Error",'
              '"message":"headers must have required property authorization"}',
            ),
          ),
          400,
          reasonPhrase: 'Bad Request',
        );
      });

      final call = ChatRepository.uploadBytesWithProgressForTesting(
        uri: Uri.parse(
          'https://project.supabase.co/storage/v1'
          '/object/chat-media/conversation/user/m1.png',
        ),
        headers: const {},
        bytes: Uint8List.fromList([1, 2, 3]),
        fileName: 'm1.png',
        mimeType: 'image/png',
        onProgress: (_) {},
        httpClient: client,
      );

      await expectLater(
        call,
        throwsA(
          isA<ChatMediaUploadException>().having(
            (error) => error.details,
            'details',
            allOf(
              contains('HTTP 400 Bad Request'),
              contains('authorization'),
              contains('bearer session header'),
            ),
          ),
        ),
      );
    },
  );

  test('macOS entitlements allow desktop picker file writes', () {
    for (final path in const [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      final contents = File(path).readAsStringSync();
      expect(
        contents,
        contains('com.apple.security.files.user-selected.read-write'),
      );
    }
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

final _transparentGif = Uint8List.fromList([
  0x47,
  0x49,
  0x46,
  0x38,
  0x39,
  0x61,
  0x01,
  0x00,
  0x01,
  0x00,
  0x80,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0xff,
  0xff,
  0xff,
  0x21,
  0xf9,
  0x04,
  0x01,
  0x00,
  0x00,
  0x00,
  0x00,
  0x2c,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x00,
  0x02,
  0x02,
  0x44,
  0x01,
  0x00,
  0x3b,
]);

final _tinyWav = Uint8List.fromList([
  0x52,
  0x49,
  0x46,
  0x46,
  0x24,
  0x00,
  0x00,
  0x00,
  0x57,
  0x41,
  0x56,
  0x45,
  0x66,
  0x6d,
  0x74,
  0x20,
  0x10,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x40,
  0x1f,
  0x00,
  0x00,
  0x80,
  0x3e,
  0x00,
  0x00,
  0x02,
  0x00,
  0x10,
  0x00,
  0x64,
  0x61,
  0x74,
  0x61,
  0x00,
  0x00,
  0x00,
  0x00,
]);

class _MessagesChatRepository extends _RefreshingChatRepository {
  _MessagesChatRepository(this.messages);

  final List<ChatMessage> messages;

  @override
  Stream<List<ChatMessage>> watchMessages(String conversationId) {
    return Stream.value(messages);
  }
}

class _DownloadChatRepository extends _MessagesChatRepository {
  _DownloadChatRepository(super.messages);

  int saveCount = 0;
  ChatMedia? savedMedia;

  @override
  Future<bool> saveMediaAttachment(ChatMedia media) async {
    saveCount += 1;
    savedMedia = media;
    return true;
  }
}

class _MediaChatRepository extends _MessagesChatRepository {
  _MediaChatRepository() : super(const []);

  String? sentBody;
  ChatMedia? sentMedia;

  @override
  Future<List<GiphyGif>> searchGiphyGifs(String query) async {
    return const [
      GiphyGif(
        id: 'giphy-1',
        title: 'Test GIF',
        previewUrl: 'https://example.com/preview.gif',
        originalUrl: 'https://example.com/original.gif',
        width: 1,
        height: 1,
        sizeBytes: 43,
      ),
    ];
  }

  @override
  Future<PickedChatMedia> downloadGiphyGif(GiphyGif gif) async {
    return PickedChatMedia(
      bytes: _transparentGif,
      originalName: 'giphy-${gif.id}.gif',
      mimeType: 'image/gif',
      sizeBytes: _transparentGif.length,
      width: gif.width,
      height: gif.height,
    );
  }

  @override
  Future<UploadedChatMedia> uploadMediaAttachment({
    required String conversationId,
    required PickedChatMedia pickedMedia,
    required void Function(double progress) onProgress,
  }) async {
    onProgress(0.42);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    onProgress(1);
    return UploadedChatMedia(
      messageId: 'media-message-1',
      media: ChatMedia(
        bucket: ChatRepository.mediaBucket,
        path: '$conversationId/user-1/media-message-1.gif',
        mimeType: pickedMedia.mimeType,
        sizeBytes: pickedMedia.sizeBytes,
        width: pickedMedia.width,
        height: pickedMedia.height,
        duration: pickedMedia.duration,
        waveform: pickedMedia.waveform,
        originalName: pickedMedia.originalName,
      ),
    );
  }

  @override
  Future<void> sendMediaMessage({
    required String conversationId,
    required String messageId,
    required String body,
    required ChatMedia media,
  }) async {
    sentBody = body;
    sentMedia = media;
  }
}

class _RefreshingChatRepository extends ChatRepository {
  int profileFetchCount = 0;
  int threadFetchCount = 0;

  @override
  bool get isConnected => true;

  @override
  Stream<List<ChatThread>> watchThreads() {
    return Stream.value([_testThread('Old Peer')]);
  }

  @override
  Future<List<ChatThread>> fetchThreads() async {
    threadFetchCount += 1;
    return [_testThread('Refreshed Peer')];
  }

  @override
  Future<ChatUser?> profileForUser(String userId) async {
    profileFetchCount += 1;
    return ChatUser(id: userId, displayName: 'Fresh Peer');
  }

  @override
  Stream<Map<String, UserPresence>> watchPresenceForThreads() {
    return Stream.value(const {});
  }

  @override
  Stream<TypingState> watchConversationTyping(String conversationId) {
    return Stream.value(TypingState.idle(conversationId));
  }

  @override
  Stream<List<ChatMessage>> watchMessages(String conversationId) {
    return Stream.value(const []);
  }

  @override
  Future<void> updateLastSeen() async {}

  @override
  Future<void> disposeRealtime() async {}
}

ChatThread _testThread(String title) {
  return ChatThread(
    id: 'conversation-1',
    title: title,
    subtitle: 'Latest messages are synced.',
    avatarLabel: 'OP',
    accentColor: Colors.teal,
    lastActive: 'Now',
    unreadCount: 0,
    isOnline: false,
    activityLabel: 'Offline',
    peerUserId: 'peer-1',
  );
}
