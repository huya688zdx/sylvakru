import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/base/app.dart' as app;
import 'package:sylvakru/base/data/library.dart' deferred as library_data;
import 'package:sylvakru/base/services/feiniu_client.dart';
import 'package:sylvakru/base/services/logger.dart';
import 'package:sylvakru/base/services/lyric.dart';
import 'package:sylvakru/base/services/stream_client.dart';

Future<void> _reply(
  HttpRequest request,
  Map<String, dynamic> body, {
  int status = HttpStatus.ok,
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory appSupportDirectory;

  setUpAll(() async {
    appSupportDirectory = await Directory.systemTemp.createTemp(
      'sylvakru_feiniu_test',
    );
    app.appSupportDir = appSupportDirectory;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => appSupportDirectory.path,
        );
    app.sourceType = app.SourceType.feiniu;
    app.isStreamSource = true;
    app.isNotStreamSource = false;
    await logger.init();
    await library_data.loadLibrary();
  });

  setUp(() {
    library_data.library.id2Song.clear();
    library_data.library.songList.clear();
  });
  tearDownAll(() async {
    await library_data.library.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await appSupportDirectory.delete(recursive: true);
  });

  test('飞牛登录与曲库分页沿用真实协议并映射音频和歌词数据', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final rows = List.generate(
      5,
      (index) => {
        'guid': 'song-$index',
        'title': '测试歌曲 $index',
        'duration': 123456,
        'audioSpec': {
          'format': 'flac',
          'bitrate': 1411200,
          'sampleRate': 44100,
        },
        'artists': [
          {'guid': 'artist-a', 'name': '测试艺术家'},
        ],
        'album': {'guid': 'album-a', 'name': '测试专辑', 'coverId': 'album-cover'},
      },
    );
    final requestedPages = <int>[];
    final requestedCoverIds = <String>[];
    rows[4]['coverId'] = 'song-cover';
    var expectedPageSize = 2;
    var loginCount = 0;
    var meCount = 0;
    var preferLyrics = true;
    int? failedPage;
    server.listen((request) async {
      if (request.uri.path == '/music/api/v1/user/password-login') {
        loginCount++;
        expect(request.method, 'POST');
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body['username'], 'user');
        // 已知摘要包含密码首尾空格，防止登录时误删有效密码字符。
        expect(
          body['password'],
          'c7f4e2c8526410c789cfe3a2ccd1c52cffd81e930ec64ada9322a0f685787be7',
        );
        expect(body['deviceId'], isNotEmpty);
        await _reply(request, {
          'code': 0,
          'data': {'userToken': 'token-1'},
        });
        return;
      }
      expect(
        request.headers.value(HttpHeaders.cookieHeader),
        'music-token=token-1',
      );
      switch (request.uri.path) {
        case '/music/api/v1/user/me':
          meCount++;
          await _reply(request, {
            'code': 0,
            'data': {'username': 'user'},
          });
        case '/music/api/v1/track/list':
          final page = int.parse(request.uri.queryParameters['page']!);
          final size = int.parse(request.uri.queryParameters['size']!);
          requestedPages.add(page);
          expect(size, expectedPageSize);
          if (page == failedPage) {
            await _reply(request, {'code': 10004});
            return;
          }
          await _reply(request, {
            'code': 0,
            'data': {
              'list': rows.skip((page - 1) * size).take(size).toList(),
              'total': rows.length,
            },
          });
        case '/music/api/v1/search/track':
          expect(request.uri.queryParameters['q'], '测试');
          // 当前搜索接口忽略分页参数，返回完整匹配结果。
          await _reply(request, {
            'code': 0,
            'data': {'list': rows},
          });
        case '/music/api/v1/lyric/list':
          expect(request.uri.queryParameters['trackGUID'], 'song-3');
          await _reply(request, {
            'code': 0,
            'data': {
              'list': [
                {'guid': 'source-3', 'source': 3, 'content': '[00:03.00]来源三'},
                {'guid': 'source-4', 'source': 4, 'content': '[00:04.00]手工歌词'},
                {'guid': 'chosen', 'source': 99, 'content': '[00:01.00]测试歌词'},
              ],
              'preferred': preferLyrics ? 'chosen' : 'missing',
            },
          });
        case '/music/api/v1/static/cover':
          requestedCoverIds.add(request.uri.queryParameters['coverId']!);
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add([1, 2, 3]);
          await request.response.close();
        default:
          await _reply(request, {'code': 404}, status: HttpStatus.notFound);
      }
    });
    final client = FeiniuClient(
      baseUrl: 'http://${server.address.address}:${server.port}/music/',
      username: 'user',
      password: ' password ',
    );

    expect(await client.ping(), isTrue);
    final songs = await client.getSongs(2, 3);
    expect(songs?.map((song) => song.id), ['song-3', 'song-4']);
    expect(requestedPages, [2, 3]);
    expect(songs!.first.duration, const Duration(milliseconds: 123456));
    expect(songs.first.bitrate, 1411);
    expect(songs.first.samplerate, 44100);
    expect(songs.first.format, 'flac');
    expect(songs.first.artist, '测试艺术家');
    expect(songs.first.album, '测试专辑');
    expect(songs.first.coverId, 'album-cover');
    final parsedLyrics = ParsedLyrics();
    applyLrcParsing(
      parsedLyrics,
      (await client.getLyricsById('song-3')).split('\n'),
      noLyricsMessage: '',
      parseFailedMessage: '',
    );
    expect(parsedLyrics.lines.single.start, const Duration(seconds: 1));
    expect(parsedLyrics.lines.single.text, '测试歌词');
    preferLyrics = false;
    final defaultLyrics = ParsedLyrics();
    applyLrcParsing(
      defaultLyrics,
      (await client.getLyricsById('song-3')).split('\n'),
      noLyricsMessage: '',
      parseFailedMessage: '',
    );
    expect(defaultLyrics.lines.single.start, const Duration(seconds: 4));
    expect(defaultLyrics.lines.single.text, '手工歌词');
    expect(await client.getPictureBytes(songs.first.coverId!), [1, 2, 3]);
    expect(requestedCoverIds, ['album-cover']);
    final streamUri = Uri.parse(client.getStreamUrl('song-3'));
    expect(streamUri.path, '/music/api/v1/track/stream');
    expect(streamUri.queryParameters, {'guid': 'song-3'});
    expect(client.headers['Cookie'], 'music-token=token-1');
    expect(loginCount, 1);
    expect(meCount, 1);

    // 全量曲库必须跨过单页 500 首限制，不能停在页面首批歌曲。
    rows.addAll(
      List.generate(
        496,
        (index) => {...rows.first, 'guid': 'song-${index + 5}'},
      ),
    );
    expectedPageSize = 500;
    requestedPages.clear();
    final allSongs = await client.getAllSongs();
    expect(requestedPages, [1, 2]);
    expect(allSongs?.length, 501);
    expect(allSongs?.map((song) => song.id).toSet().length, 501);
    expect(allSongs?.last.id, 'song-500');
    rows[4].remove('coverId');
    final refreshedSongs = await client.getAllSongs();
    expect(await client.getPictureBytes(refreshedSongs![4].coverId!), [
      1,
      2,
      3,
    ]);
    expect(requestedCoverIds, ['album-cover', 'album-cover']);

    streamClient = client;
    await library_data.library.sync();
    final oldSong = library_data.library.id2Song['song-0']!;
    rows[0] = {
      ...rows[0],
      'title': '同步后的标题',
      'audioSpec': {
        ...rows[0]['audioSpec'] as Map<String, dynamic>,
        'sampleRate': 96000,
      },
    };
    await library_data.library.sync();
    final refreshed = library_data.library.id2Song['song-0']!;
    expect(refreshed.title, '同步后的标题');
    expect(refreshed.samplerate, 96000);
    expect(identical(refreshed, oldSong), isFalse);
    expect(identical(library_data.library.songList.first, refreshed), isTrue);

    final songsBeforeFailure = List.of(library_data.library.songList);
    final mapBeforeFailure = Map.of(library_data.library.id2Song);
    failedPage = 2;
    rows[0] = {...rows[0], 'title': '不应发布的标题'};
    await library_data.library.sync();
    expect(library_data.library.songList, orderedEquals(songsBeforeFailure));
    expect(library_data.library.id2Song, mapBeforeFailure);
    expect(library_data.library.id2Song['song-0']?.title, '同步后的标题');
  });

  test('飞牛认证失效仅重登一次且续传 JSON 错误不污染已有缓存', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final partFile = File('${appSupportDirectory.path}/failed-song.part');
    await partFile.writeAsBytes([1, 2, 3]);
    var loginCount = 0;
    var meCount = 0;
    var streamCount = 0;
    final streamCookies = <String?>[];
    server.listen((request) async {
      switch (request.uri.path) {
        case '/music/api/v1/user/password-login':
          await request.drain<void>();
          loginCount++;
          await _reply(request, {
            'code': 0,
            'data': {'userToken': 'token-$loginCount'},
          });
        case '/music/api/v1/user/me':
          meCount++;
          await _reply(request, {
            'code': 99999,
          }, status: meCount == 1 ? HttpStatus.ok : HttpStatus.unauthorized);
        case '/music/api/v1/track/stream':
          streamCount++;
          streamCookies.add(request.headers.value(HttpHeaders.cookieHeader));
          expect(request.uri.queryParameters['guid'], 'song-a');
          expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=3-');
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 3-5/6',
          );
          await _reply(request, {
            'code': streamCount == 1 ? 99999 : 10004,
            'msg': 'rejected',
          }, status: HttpStatus.partialContent);
        default:
          await _reply(request, {'code': 404}, status: HttpStatus.notFound);
      }
    });
    final client = FeiniuClient(
      baseUrl: 'http://${server.address.address}:${server.port}',
      username: 'user',
      password: 'password',
    );

    expect(await client.ping(), isFalse);
    expect(meCount, 2);
    expect(loginCount, 2);
    final downloadClient = FeiniuClient(
      baseUrl: 'http://${server.address.address}:${server.port}',
      username: 'user',
      password: 'password',
    );
    expect(
      await downloadClient.downloadSong('song-a', partFile.path, resumeFrom: 3),
      isFalse,
    );
    expect(streamCount, 2);
    expect(loginCount, 4);
    expect(streamCookies, ['music-token=token-3', 'music-token=token-4']);
    expect(await partFile.readAsBytes(), [1, 2, 3]);
  });

  test('NAS 授权码换取音乐令牌并沿用 FN ID 中继请求头', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      var data = <String, dynamic>{};
      switch (request.uri.path) {
        case '/music/api/v1/sys/config':
          data = {
            'nasOAuth': {'clientId': 'music-client'},
          };
        case '/music/api/v1/user/auth-login':
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          expect(body['code'], 'authorization-code');
          expect(body['deviceId'], matches(RegExp(r'^[a-f0-9]{32}$')));
          expect(body.containsKey('password'), isFalse);
          data = {'userToken': 'music-token-value'};
        case '/music/api/v1/user/me':
          expect(
            request.headers.value('cookie'),
            'music-token=music-token-value',
          );
        default:
          fail('Unexpected request: ${request.uri.path}');
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'code': 0, 'data': data}));
      await request.response.close();
    });
    final client = FeiniuClient(baseUrl: baseUrl, username: '', password: '');
    final callback = Uri.parse('$baseUrl/music/oauth/result');
    final url = await client.getNasLoginUrl(state: 'login-state');
    expect(url?.path, '/signin');
    expect(url?.queryParameters['client_id'], 'music-client');
    expect(url?.queryParameters['redirect_uri'], callback.toString());
    expect(url?.queryParameters['state'], 'login-state');
    expect(await client.loginWithCode('authorization-code'), isTrue);
    expect(await client.ping(), isTrue);

    final restored = FeiniuClient(
      baseUrl: 'sample-nas',
      username: '',
      password: '',
      token: client.token,
    );
    expect(
      restored.getStreamUrl('song'),
      'https://sample-nas.fnos.net/music/api/v1/track/stream?guid=song',
    );
    expect(
      restored.headers['Cookie'],
      'mode=relay; music-token=music-token-value',
    );
  });

  test('NAS 令牌过期后不使用音乐密码重复登录', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      expect(request.uri.path, '/music/api/v1/user/me');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'code': 120001}));
      await request.response.close();
    });
    final client = FeiniuClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      username: '',
      password: '',
      token: 'expired-token',
    );
    expect(await client.ping(), isFalse);
    expect(await client.ping(), isFalse);
    expect(client.token, isNull);
    expect(requests, 1);
  });
}
