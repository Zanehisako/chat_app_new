import 'dart:typed_data';

import 'offline_outbox_media_store.dart';

OutboxMediaStore createOutboxMediaStore() => _MemoryOutboxMediaStore();

class _MemoryOutboxMediaStore implements OutboxMediaStore {
  final Map<String, Uint8List> _bytesByRef = {};

  @override
  Future<String> saveMedia({
    required String messageId,
    required Uint8List bytes,
    required String extension,
  }) async {
    final ref = 'memory:$messageId$extension';
    _bytesByRef[ref] = Uint8List.fromList(bytes);
    return ref;
  }

  @override
  Future<Uint8List> readMedia(String storageRef) async {
    return _bytesByRef[storageRef] ?? Uint8List(0);
  }

  @override
  Future<void> deleteMedia(String storageRef) async {
    _bytesByRef.remove(storageRef);
  }
}
