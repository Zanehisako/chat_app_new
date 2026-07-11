import 'dart:typed_data';

abstract class OutboxMediaStore {
  Future<String> saveMedia({
    required String messageId,
    required Uint8List bytes,
    required String extension,
  });

  Future<Uint8List> readMedia(String storageRef);

  Future<void> deleteMedia(String storageRef);
}
