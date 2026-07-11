import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'offline_outbox_media_store.dart';

OutboxMediaStore createOutboxMediaStore() => _WebOutboxMediaStore();

class _WebOutboxMediaStore implements OutboxMediaStore {
  static const _prefix = 'chat_app.outbox.media.';

  @override
  Future<String> saveMedia({
    required String messageId,
    required Uint8List bytes,
    required String extension,
  }) async {
    final ref = 'web:$messageId$extension';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$ref', base64Encode(bytes));
    return ref;
  }

  @override
  Future<Uint8List> readMedia(String storageRef) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString('$_prefix$storageRef');
    return encoded == null ? Uint8List(0) : base64Decode(encoded);
  }

  @override
  Future<void> deleteMedia(String storageRef) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$storageRef');
  }
}
