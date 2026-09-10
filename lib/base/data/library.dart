import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_tags_lofty/audio_tags_lofty.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' show extension;
import 'package:sylvakru/base/app.dart';
import 'package:sylvakru/base/data/database.dart';
import 'package:sylvakru/base/extensions/metadata_extension.dart';
import 'package:sylvakru/base/services/logger.dart';
import 'package:sylvakru/base/services/picture_load_scheduler.dart';
import 'package:sylvakru/base/services/picture_service.dart';
import 'package:sylvakru/base/services/stream_client.dart';
import 'package:sylvakru/base/services/dsd_metadata.dart';
import 'package:sylvakru/base/services/replay_gain.dart';
import 'package:sylvakru/base/services/navidrome_client.dart';
import 'package:sylvakru/base/services/webdav_client.dart';
import 'package:sylvakru/base/utils/path.dart';
import 'package:sylvakru/base/data/folder.dart';
import 'package:sylvakru/layer/layers_manager.dart';
import 'package:sylvakru/base/my_audio_metadata.dart';
import 'package:pool/pool.dart';

Library library = Library();

final ValueNotifier<double> cacheSizeNotifier = ValueNotifier(0);

class ReplayGainMetadataChangedEvent {
  final String songId;

  const ReplayGainMetadataChangedEvent(this.songId);
}

class Library {
  MetadataDB? _metadataDB;
  final replayGainMetadataChangedNotifier =
      ValueNotifier<ReplayGainMetadataChangedEvent?>(null);

  Map<String, MyAudioMetadata> id2Song = {};
  List<MyAudioMetadata> songList = [];

  final changeNotifier = ValueNotifier(0);

  File? _folderIdListFile;
  List<Folder> folderList = [];
  final folderListChangeNotifier = ValueNotifier(0);

  bool canModify = false;

  Library() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    if (isNotStreamSource) {
      _metadataDB = MetadataDB(
        openMetadataDB('${sourceType.name}/metadata.db'),
      );
      _folderIdListFile = File(
        "${getFolderConfigPath(sourceType)}/folder_id_list.json",
      );
      initFile(_folderIdListFile!, true);
    }
  }

  Future<bool> updateFolders(List<String> idList) async {
    bool needUpdate = false;
    if (idList.length == folderList.length) {
      for (int i = 0; i < idList.length; i++) {
        if (idList[i] != folderList[i].id) {
          needUpdate = true;
          break;
        }
      }
    } else {
      needUpdate = true;
    }

    if (!needUpdate) {
      return false;
    }

    List<Folder> newFolderList = [];
    for (int i = 0; i < idList.length; i++) {
      String id = idList[i];
      bool exist = false;
      for (final folder in folderList) {
        if (id == folder.id) {
          newFolderList.add(folder);
          exist = true;
          break;
        }
      }
      if (!exist) {
        newFolderList.add(await Folder.create(id, sourceType == .webdav));
      }
    }

    for (final folder in folderList) {
      if (newFolderList.contains(folder)) {
        continue;
      }
      folder.delete();
      layersManager.removeLayerIfNeed(folder);
    }

    folderList = newFolderList;
    await _folderIdListFile!.writeAsString(
      jsonEncode(folderList.map((e) => e.id).toList()),
    );

    folderListChangeNotifier.value++;
    return true;
  }

  Folder? getFolderById(String id) {
    for (final folder in folderList) {
      if (folder.id == id) {
        return folder;
      }
    }

    return null;
  }

  Future<void> initFolders() async {
    // must execute before loading metadata(set ios path)
    for (final id in await readJsonListFile(_folderIdListFile!)) {
      final folder = await Folder.from(id, sourceType == .webdav);
      folderList.add(folder);
    }
  }

  Future<void> load() async {
    if (isNotStreamSource) {
      await initFolders();

      List<MetadataItem> rows = [];
      int offset = 0;

      do {
        rows = await (_metadataDB!.select(
          _metadataDB!.metadataItems,
        )..limit(10000, offset: offset)).get();

        if (rows.isEmpty) {
          break;
        }

        for (final row in rows) {
          final song = row.toMetadata();
          id2Song.putIfAbsent(row.id, () => song);
          songList.add(song);
        }

        changeNotifier.value++;
        layersManager.updateBackground();
        offset += rows.length;
      } while (true);

      canModify = true;
      changeNotifier.value++;

      for (final folder in folderList) {
        await folder.load();
      }
    }

    await _accumulateCache();
  }

  Future<void> _accumulateCache() async {
    cacheSizeNotifier.value = 0;
    Directory cacheDir = Directory(getCachesPath(sourceType));
    if (!await cacheDir.exists()) {
      return;
    }
    int total = 0;
    await for (final file in cacheDir.list()) {
      if (file is File) {
        total += await file.length();
      }
    }
    cacheSizeNotifier.value += total / (1024 * 1024);
  }

  final Map<String, Future<void>> _cacheDownloads = {};
  final Map<String, CancelToken> _cacheDownloadCancelTokens = {};
  final Set<String> _replayGainApiChecked = {};
  final Map<String, Future<void>> _replayGainApiRefreshes = {};
  final Set<String> _replayGainCacheChecked = {};

  Future<void> supplementReplayGainForPlayback(MyAudioMetadata song) async {
    unawaited(_supplementReplayGainForPlayback(song));
  }

  Future<void> _supplementReplayGainForPlayback(MyAudioMetadata song) async {
    final client = streamClient is NavidromeClient
        ? streamClient as NavidromeClient
        : null;
    final apiKey = '${sourceType.name}:${song.id}';
    final metadataComplete =
        song.replayGainTrackGainDb != null &&
        song.replayGainTrackPeak != null &&
        song.replayGainAlbumGainDb != null &&
        song.replayGainAlbumPeak != null;
    if (client != null && !metadataComplete) {
      final inFlight = _replayGainApiRefreshes[apiKey];
      if (inFlight != null) {
        await inFlight;
      } else if (!_replayGainApiChecked.contains(apiKey)) {
        final refresh = _supplementReplayGainFromApi(
          song,
          client,
          apiKey,
        ).whenComplete(() => _replayGainApiRefreshes.remove(apiKey));
        _replayGainApiRefreshes[apiKey] = refresh;
        await refresh;
      }
    }
    if (song.cacheExist && song.cachePath != null) {
      await _supplementCachedReplayGain(song, song.cachePath!);
    }
  }

  Future<void> _supplementReplayGainFromApi(
    MyAudioMetadata song,
    NavidromeClient client,
    String apiKey,
  ) async {
    try {
      final songMap = await client
          .getSong(song.id)
          .timeout(const Duration(milliseconds: 1500));
      if (songMap == null) {
        return;
      }
      _replayGainApiChecked.add(apiKey);
      final values = songMap['replayGain'] as Map? ?? const {};
      double? gain(String key) => double.tryParse(
        values[key]
            .toString()
            .replaceAll(RegExp(r'\s*dB\s*$', caseSensitive: false), '')
            .trim(),
      );
      if (!supplementReplayGainValues(
        song,
        trackGain: gain('trackGain'),
        trackPeak: gain('trackPeak'),
        albumGain: gain('albumGain'),
        albumPeak: gain('albumPeak'),
      )) {
        return;
      }
      await updateMetadata(song);
      replayGainMetadataChangedNotifier.value = ReplayGainMetadataChangedEvent(
        song.id,
      );
    } on TimeoutException {
      logger.output('OpenSubsonic ReplayGain request timed out: ${song.id}');
    } catch (e) {
      logger.output('OpenSubsonic ReplayGain refresh failed: $e');
    }
  }

  Future<void> tryAddCache(MyAudioMetadata song) {
    if (sourceType == .local) {
      return Future.value();
    }
    if (song.cacheExist) {
      final savePath = song.cachePath;
      return savePath == null
          ? Future.value()
          : _supplementCachedReplayGain(song, savePath);
    }
    final savePath = song.cachePath!;
    final inFlight = _cacheDownloads[savePath];
    if (inFlight != null) {
      if (_cacheDownloadCancelTokens[savePath]?.isCancelled == true) {
        return inFlight.whenComplete(() => tryAddCache(song));
      }
      return inFlight;
    }
    final cancelToken = CancelToken();
    final download = _downloadCache(song, savePath, cancelToken).whenComplete(
      () {
        _cacheDownloads.remove(savePath);
        _cacheDownloadCancelTokens.remove(savePath);
      },
    );
    _cacheDownloads[savePath] = download;
    _cacheDownloadCancelTokens[savePath] = cancelToken;
    return download;
  }

  void cancelCacheDownload(MyAudioMetadata song) {
    final savePath = song.cachePath;
    if (savePath != null) {
      _cacheDownloadCancelTokens[savePath]?.cancel();
    }
  }

  Future<void> _downloadCache(
    MyAudioMetadata song,
    String savePath,
    CancelToken cancelToken,
  ) async {
    final downloadSource = sourceType;
    final client = streamClient;
    final webdav = webdavClient;
    final partPath = '$savePath.part';
    final stale = File(partPath);
    if (await stale.exists()) {
      await stale.delete();
    }
    while (!cancelToken.isCancelled) {
      // 重试时从 .part 已有长度断点续传，不从头重下：正在流式独占读这个
      // .part 的引擎不必等重新下载追回播放位置，已下载流量也不浪费
      final resumeFrom = (await File(partPath).exists())
          ? await File(partPath).length()
          : 0;
      final completed = switch (downloadSource) {
        .webdav => await webdav!.download(
          remotePath: song.path!,
          localPath: partPath,
          cancelToken: cancelToken,
          resumeFrom: resumeFrom,
        ),
        .navidrome || .emby => await client!.downloadSong(
          song.id,
          partPath,
          cancelToken: cancelToken,
          resumeFrom: resumeFrom,
        ),
        .local => false,
      };
      final part = File(partPath);
      if (completed && await part.exists()) {
        await part.rename(savePath);
        song.cacheExist = true;
        cacheSizeNotifier.value +=
            await File(savePath).length() / (1024 * 1024);
        await _supplementCachedReplayGain(song, savePath);
        return;
      }
      if (!cancelToken.isCancelled) {
        logger.output('cache download retry:${song.title}');
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _supplementCachedReplayGain(
    MyAudioMetadata song,
    String savePath,
  ) async {
    if (!_replayGainCacheChecked.add(savePath)) {
      return;
    }
    if (song.replayGainTrackGainDb != null &&
        song.replayGainTrackPeak != null &&
        song.replayGainAlbumGainDb != null &&
        song.replayGainAlbumPeak != null) {
      return;
    }
    try {
      final metadata = song.isDsd
          ? await readDsdMetadata(savePath)
          : await readMetadataAsync(savePath, false);
      if (metadata == null) {
        return;
      }
      if (!supplementReplayGainMetadata(song, metadata)) {
        return;
      }
      await updateMetadata(song);
      replayGainMetadataChangedNotifier.value = ReplayGainMetadataChangedEvent(
        song.id,
      );
    } catch (e) {
      try {
        logger.output('cache ReplayGain metadata read failed: $e');
      } catch (_) {}
    }
  }

  Future<void> cancelDownloads() async {
    for (final token in _cacheDownloadCancelTokens.values) {
      token.cancel();
    }
    await Future.wait(_cacheDownloads.values.toList());
  }

  Future<void> clearCache() async {
    await cancelDownloads();
    Directory cacheDir = Directory(getCachesPath(sourceType));
    if (await cacheDir.exists()) {
      await for (final file in cacheDir.list()) {
        if (file is File) {
          await file.delete();
        }
      }
    }

    cacheSizeNotifier.value = 0;
    for (final song in library.id2Song.values) {
      song.cacheExist = false;
    }
    _replayGainCacheChecked.clear();
  }

  Future<void> clearPicture() async {
    Directory pictureDir = Directory(getPicturesPath(sourceType));
    if (await pictureDir.exists()) {
      await for (final file in pictureDir.list()) {
        await file.delete();
      }
    }
    pictureLoadScheduler.clear();
    for (final picture in globalPictureList) {
      picture.reset();
    }

    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  Future<void> _saveMetadata() async {
    final db = _metadataDB!;
    await db.transaction(() async {
      await db.delete(db.metadataItems).go();

      await db.batch((batch) {
        batch.insertAll(
          db.metadataItems,
          songList.map((e) => e.toCompanion()).toList(),
        );
      });
    });
  }

  Future<void> updatePlayCount(MyAudioMetadata song) async {
    final db = _metadataDB;
    if (db == null) return;
    await (db.update(
      db.metadataItems,
    )..where((t) => t.id.equals(song.id))).write(
      MetadataItemsCompanion(
        playCount: Value(song.playCount),
        lastPlayed: Value(song.lastPlayed!.millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> updateDuration(MyAudioMetadata song, Duration duration) async {
    final db = _metadataDB;
    if (db == null) return;
    await (db.update(
      db.metadataItems,
    )..where((t) => t.id.equals(song.id))).write(
      MetadataItemsCompanion(duration: Value(duration.inMilliseconds)),
    );
    song.duration = duration;
    song.updateNotifier.value++;
  }

  Future<void> updateMetadata(MyAudioMetadata song) async {
    final db = _metadataDB;
    if (db == null) return;
    await (db.update(
      db.metadataItems,
    )..where((t) => t.id.equals(song.id))).write(
      MetadataItemsCompanion(
        title: Value(song.title),
        artist: Value(song.artist),
        album: Value(song.album),
        genre: Value(song.genre),
        lyrics: Value(song.lyrics),
        year: Value(song.year),
        track: Value(song.track),
        disc: Value(song.disc),
        replayGainTrackGainDb: Value(song.replayGainTrackGainDb),
        replayGainTrackPeak: Value(song.replayGainTrackPeak),
        replayGainAlbumGainDb: Value(song.replayGainAlbumGainDb),
        replayGainAlbumPeak: Value(song.replayGainAlbumPeak),
      ),
    );
  }

  void shuffle() {
    songList.shuffle();
    update();
  }

  void update() {
    changeNotifier.value++;
    layersManager.updateBackground();
    if (isNotStreamSource) {
      _saveMetadata();
    }
  }

  void _syncNotify() {
    changeNotifier.value++;
    layersManager.updateBackground();
  }

  Future<MyAudioMetadata?> _parseMetadataIfNeed(
    String id,
    String path,
    DateTime modified,
  ) async {
    MyAudioMetadata? song = library.id2Song[id];

    if ((song?.modified?.difference(modified).inSeconds.abs() ?? 2) > 1) {
      String readPath = path;
      Map<String, String>? headers;
      bool isWebdav = path.startsWith('http://') || path.startsWith('https://');
      if (isWebdav) {
        final tmpPath = await covertToRedirectPathIfNeed(path);
        if (tmpPath == null) {
          headers = webdavClient?.headers;
        } else {
          readPath = tmpPath;
        }
      }
      AudioMetadata? tmp;
      try {
        final ext = extension(
          isWebdav ? Uri.parse(path).path : readPath,
        ).toLowerCase();
        if (ext == '.dsf' || ext == '.dff') {
          tmp = isWebdav
              ? await readRemoteDsdMetadata(readPath, headers: headers)
              : await readDsdMetadata(readPath);
        } else {
          tmp = await readMetadataAsync(readPath, false, headers: headers);
        }
      } catch (e) {
        logger.output("$path: $e");
      }

      if (tmp != null) {
        song = MyAudioMetadata(tmp, id: id, path: path, modified: modified);
      } else {
        song = null;
      }
    }
    if (song != null) {
      library.id2Song[id] = song;
    } else {
      library.id2Song.remove(id);
    }
    return song;
  }

  Future<void> sync() async {
    // 扫描 DSD 文件需要所有文件访问权限，沿用现有授权时机。
    if (Platform.isAndroid && sourceType == .local && folderList.isNotEmpty) {
      await Permission.manageExternalStorage.request();
    }
    canModify = false;

    switch (sourceType) {
      case .local:
      case .webdav:
        Map<String, DateTime> pathAndModified = {};

        final updateCount = sourceType == .local ? 1000 : 25;

        for (final folder in folderList) {
          folder.songList.clear();
          folder.changeNotifier.value++;
          await folder.setFileAndModified();
          pathAndModified.addAll(folder.pathAndModified);
        }

        final pool = Pool(6);

        final tasks = <Future>[];

        Set<String> validId = {};

        Future<void> syncOne(String id, String path, DateTime modified) async {
          final song = await _parseMetadataIfNeed(id, path, modified);
          if (song != null) {
            validId.add(id);
            songList.add(song);
            if (validId.length % updateCount == 0) {
              _syncNotify();
            }
          }
        }

        final songIdList = songList.map((e) => e.id).toList();
        songList.clear();

        changeNotifier.value++;

        for (final id in songIdList) {
          String path = id;

          DateTime? modified;
          if (sourceType == .local) {
            if (Platform.isIOS) {
              path = revertIOSPath(path);
            }
            modified = pathAndModified.remove(path);
          } else {
            if (webdavClient != null) {
              modified = pathAndModified.remove(
                path.substring(webdavClient!.cleanBaseUrl.length),
              );
            }
          }

          if (modified != null) {
            tasks.add(
              pool.withResource(() async {
                await syncOne(id, path, modified!);
              }),
            );
          }
        }

        await Future.wait(tasks);

        for (final entry in pathAndModified.entries) {
          String path = entry.key;
          String id = path;
          if (sourceType == .webdav) {
            path = webdavClient!.cleanBaseUrl + path;
            id = path;
          } else if (Platform.isIOS) {
            id = convertIOSPath(path);
          }
          tasks.add(pool.withResource(() => syncOne(id, path, entry.value)));
        }

        await Future.wait(tasks);

        await pool.close();

        id2Song.removeWhere((id, song) => !validId.contains(id));

        for (final folder in folderList) {
          await folder.sync();
          folder.clearPathAndModified();
        }

        await _saveMetadata();
      default:
        id2Song = {};
        songList = [];
    }

    canModify = true;
    _syncNotify();
  }
}
