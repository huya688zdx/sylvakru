import 'dart:io';

import 'package:audio_tags_lofty/audio_tags_lofty.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/base/app.dart' as app;
import 'package:sylvakru/base/data/database.dart';
import 'package:sylvakru/base/extensions/metadata_extension.dart';
import 'package:sylvakru/base/my_audio_metadata.dart';

void main() {
  late Directory appSupportDirectory;

  setUpAll(() async {
    appSupportDirectory = await Directory.systemTemp.createTemp(
      'metadata_database_test',
    );
    app.appSupportDir = appSupportDirectory;
  });

  tearDownAll(() async {
    await appSupportDirectory.delete(recursive: true);
  });

  test('本地版本 3 升级后保留歌曲与四项 ReplayGain', () async {
    final file = File('${appSupportDirectory.path}/local_v3.db');
    var database = MetadataDB(NativeDatabase(file));
    addTearDown(() => database.close());
    final metadata = MyAudioMetadata(
      AudioMetadata(
        title: 'ReplayGain test',
        replayGainTrackGainDb: -7.25,
        replayGainTrackPeak: 0.987654321,
        replayGainAlbumGainDb: -5.75,
        replayGainAlbumPeak: 1.012345678,
      ),
      id: 'replaygain-values',
      path: 'replaygain-values',
    );

    await database.into(database.metadataItems).insert(metadata.toCompanion());
    await database.customStatement(
      "ALTER TABLE metadata_items ADD COLUMN source_type TEXT NOT NULL DEFAULT 'local'",
    );
    await database.customStatement('PRAGMA user_version = 3');
    await database.close();
    database = MetadataDB(NativeDatabase(file));
    final restored = (await database.select(database.metadataItems).getSingle())
        .toMetadata();

    expect(restored.title, 'ReplayGain test');
    final columns = await database
        .customSelect('PRAGMA table_info(metadata_items)')
        .get();
    expect(
      columns.map((row) => row.read<String>('name')),
      isNot(contains('source_type')),
    );
    expect(restored.replayGainTrackGainDb, -7.25);
    expect(restored.replayGainTrackPeak, 0.987654321);
    expect(restored.replayGainAlbumGainDb, -5.75);
    expect(restored.replayGainAlbumPeak, 1.012345678);
  });

  test('作者版本 3 升级后补齐 ReplayGain 列并保留歌曲', () async {
    final file = File('${appSupportDirectory.path}/upstream_v3.db');
    var database = MetadataDB(NativeDatabase(file));
    addTearDown(() => database.close());
    final metadata = MyAudioMetadata(
      AudioMetadata(title: 'ReplayGain null test'),
      id: 'replaygain-null',
      path: 'replaygain-null',
    );

    await database.into(database.metadataItems).insert(metadata.toCompanion());
    for (final name in [
      'track_gain_db',
      'track_peak',
      'album_gain_db',
      'album_peak',
    ]) {
      await database.customStatement(
        'ALTER TABLE metadata_items DROP COLUMN replay_gain_$name',
      );
    }
    await database.customStatement('PRAGMA user_version = 3');
    await database.close();
    database = MetadataDB(NativeDatabase(file));
    final restored = (await database.select(database.metadataItems).getSingle())
        .toMetadata();

    expect(restored.title, 'ReplayGain null test');
    expect(restored.replayGainTrackGainDb, isNull);
    expect(restored.replayGainTrackPeak, isNull);
    expect(restored.replayGainAlbumGainDb, isNull);
    expect(restored.replayGainAlbumPeak, isNull);
  });
}
