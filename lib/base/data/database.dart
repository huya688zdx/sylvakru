import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

class MetadataItems extends Table {
  TextColumn get id => text()();

  IntColumn get modified => integer().nullable()();

  TextColumn get format => text().nullable()();

  TextColumn get title => text().nullable()();
  TextColumn get artist => text().nullable()();
  TextColumn get album => text().nullable()();
  TextColumn get albumArtist => text().nullable()();
  TextColumn get genre => text().nullable()();

  IntColumn get year => integer().nullable()();
  IntColumn get track => integer().nullable()();
  IntColumn get disc => integer().nullable()();

  IntColumn get bitrate => integer().nullable()();
  IntColumn get samplerate => integer().nullable()();
  IntColumn get duration => integer().nullable()();

  RealColumn get replayGainTrackGainDb => real().nullable()();
  RealColumn get replayGainTrackPeak => real().nullable()();
  RealColumn get replayGainAlbumGainDb => real().nullable()();
  RealColumn get replayGainAlbumPeak => real().nullable()();

  TextColumn get lyrics => text().nullable()();

  IntColumn get playCount => integer().withDefault(const Constant(0))();

  IntColumn get lastPlayed => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [MetadataItems])
class MetadataDB extends _$MetadataDB {
  MetadataDB(super.executor);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from < 2) {
          await m.addColumn(metadataItems, metadataItems.albumArtist);
        }

        if (from < 4) {
          // 两个分支的版本 3 结构不同，按现有列迁移并保留音量标签。
          final columns = (await customSelect(
            'PRAGMA table_info(metadata_items)',
          ).get()).map((row) => row.read<String>('name')).toSet();
          for (final column in [
            metadataItems.replayGainTrackGainDb,
            metadataItems.replayGainTrackPeak,
            metadataItems.replayGainAlbumGainDb,
            metadataItems.replayGainAlbumPeak,
          ]) {
            if (!columns.contains(column.$name)) {
              await m.addColumn(metadataItems, column);
            }
          }
          if (columns.contains('source_type')) {
            await m.dropColumn(metadataItems, 'source_type');
          }
        }
      },
    );
  }
}

LazyDatabase openMetadataDB(String name) {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();

    final file = File(p.join(dir.path, name));

    return NativeDatabase.createInBackground(file);
  });
}
