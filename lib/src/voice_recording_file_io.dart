import 'dart:io';
import 'dart:typed_data';

Future<String> createVoiceRecordingPath(String extension) async {
  final directory = await Directory.systemTemp.createTemp('chat_app_voice_');
  return '${directory.path}/voice-${DateTime.now().microsecondsSinceEpoch}.$extension';
}

Future<Uint8List> readVoiceRecordingFile(String path) {
  return File(path).readAsBytes();
}

Future<void> deleteVoiceRecordingFile(String? path) async {
  if (path == null || path.isEmpty) {
    return;
  }
  final file = File(path);
  try {
    if (await file.exists()) {
      await file.delete();
    }
    final parent = file.parent;
    if (parent.path.contains('chat_app_voice_') && await parent.exists()) {
      await parent.delete();
    }
  } catch (_) {
    // Temporary recording cleanup is best-effort.
  }
}
