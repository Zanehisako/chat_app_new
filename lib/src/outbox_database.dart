import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'outbox_database.g.dart';

class OutboxEntries extends Table {
  TextColumn get id => text()();
  TextColumn get backendOrigin => text()();
  TextColumn get ownerUserId => text()();
  TextColumn get conversationId => text()();
  TextColumn get senderId => text()();
  TextColumn get senderName => text()();
  TextColumn get body => text()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get status => text()();
  IntColumn get attemptCount => integer()();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
  TextColumn get mediaMimeType => text().nullable()();
  IntColumn get mediaSizeBytes => integer().nullable()();
  TextColumn get remoteBucket => text().nullable()();
  TextColumn get remotePath => text().nullable()();
  IntColumn get mediaWidth => integer().nullable()();
  IntColumn get mediaHeight => integer().nullable()();
  IntColumn get mediaDurationMs => integer().nullable()();
  TextColumn get mediaWaveform => text().nullable()();
  TextColumn get mediaOriginalName => text().nullable()();
  BlobColumn get localMediaBytes => blob().nullable()();
  TextColumn get replyToMessageId => text().nullable()();
  TextColumn get replySenderName => text().nullable()();
  TextColumn get replyPreview => text().nullable()();
  TextColumn get replyMessageType => text().nullable()();
  BoolColumn get replyIsDeleted =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isForwarded => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id, backendOrigin, ownerUserId};
}

@DriftDatabase(tables: [OutboxEntries])
class OutboxDatabase extends _$OutboxDatabase {
  OutboxDatabase([QueryExecutor? executor])
    : super(executor ?? _openConnection());

  OutboxDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await _createIndexes();
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await customStatement(
          'DROP INDEX IF EXISTS outbox_entries_scope_due_idx',
        );
        await customStatement(
          'ALTER TABLE outbox_entries RENAME TO outbox_entries_v1',
        );
        await migrator.createTable(outboxEntries);
        await customStatement('''
          INSERT INTO outbox_entries (
            id, backend_origin, owner_user_id, conversation_id, sender_id,
            sender_name, body, created_at, status, attempt_count,
            next_attempt_at, last_error, media_mime_type, media_size_bytes,
            remote_bucket, remote_path, media_width, media_height,
            media_duration_ms, media_waveform, media_original_name,
            local_media_bytes, updated_at
          )
          SELECT
            id, backend_origin, owner_user_id, conversation_id, sender_id,
            sender_name, body, created_at, status, attempt_count,
            next_attempt_at, last_error, media_mime_type, media_size_bytes,
            remote_bucket, remote_path, media_width, media_height,
            media_duration_ms, media_waveform, media_original_name,
            local_media_bytes, updated_at
          FROM outbox_entries_v1
        ''');
        await customStatement('DROP TABLE outbox_entries_v1');
        await _createIndexes();
      } else if (from < 3) {
        await migrator.addColumn(outboxEntries, outboxEntries.replyToMessageId);
        await migrator.addColumn(outboxEntries, outboxEntries.replySenderName);
        await migrator.addColumn(outboxEntries, outboxEntries.replyPreview);
        await migrator.addColumn(outboxEntries, outboxEntries.replyMessageType);
        await migrator.addColumn(outboxEntries, outboxEntries.replyIsDeleted);
        await migrator.addColumn(outboxEntries, outboxEntries.isForwarded);
      }
    },
  );

  Future<void> _createIndexes() {
    return customStatement(
      'CREATE INDEX IF NOT EXISTS outbox_entries_scope_due_idx '
      'ON outbox_entries (backend_origin, owner_user_id, status, '
      'next_attempt_at, created_at)',
    );
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'chat_app_outbox',
      native: DriftNativeOptions(
        databaseDirectory: () => getApplicationSupportDirectory(),
        shareAcrossIsolates: true,
      ),
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    );
  }
}
