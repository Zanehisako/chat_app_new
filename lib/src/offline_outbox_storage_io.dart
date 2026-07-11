import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'offline_outbox_media_store.dart';

OutboxMediaStore createOutboxMediaStore() => _FileOutboxMediaStore();

class _FileOutboxMediaStore implements OutboxMediaStore {
  @override
  Future<String> saveMedia({
    required String messageId,
    required Uint8List bytes,
    required String extension,
  }) async {
    final directory = await _outboxDirectory();
    final file = File('${directory.path}/$messageId$extension');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<Uint8List> readMedia(String storageRef) async {
    return File(storageRef).readAsBytes();
  }

  @override
  Future<void> deleteMedia(String storageRef) async {
    final file = File(storageRef);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<Directory> _outboxDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final directory = Directory('${supportDirectory.path}/outbox_media');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }
}
