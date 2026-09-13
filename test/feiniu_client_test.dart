import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/base/app.dart' as app;
import 'package:sylvakru/base/data/library.dart' deferred as library_data;
import 'package:sylvakru/base/services/feiniu_client.dart';
import 'package:sylvakru/base/services/logger.dart';
import 'package:sylvakru/base/services/lyric.dart';

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
  late Directory appSupportDirectory;

  setUpAll(() async {
    appSupportDirectory = await Directory.systemTemp.createTemp(
      'sylvakru_feiniu_test',
    );
    app.appSupportDir = appSupportDirectory;
    app.sourceType = app.SourceType.feiniu;
    app.isStreamSource = true;
    app.isNotStreamSource = false;
    await logger.init();
    await library_data.loadLibrary();
  });

  setUp(() => library_data.library.id2Song.clear());
  tearDownAll(() => appSupportDirectory.delete(recursive: true));

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
        'album': {'guid': 'album-a', 'name': '测试专辑'},
      },
    );
    final requestedPages = <int>[];
    var loginCount = 0;
    var meCount = 0;
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
          expect(size, 2);
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
                {'guid': 'other', 'content': '其他歌词'},
                {'guid': 'chosen', 'content': '[00:01.00]测试歌词'},
              ],
              'preferred': 'chosen',
            },
          });
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
    expect(songs.first.artistId, 'artist-a');
    expect(songs.first.albumId, 'album-a');
    final searched = await client.searchSongs('测试', 2, 2);
    expect(searched?.map((song) => song.id), ['song-2', 'song-3']);
    final parsedLyrics = ParsedLyrics();
    applyLrcParsing(
      parsedLyrics,
      (await client.getLyricsById('song-3')).split('\n'),
      noLyricsMessage: '',
      parseFailedMessage: '',
    );
    expect(parsedLyrics.lines.single.start, const Duration(seconds: 1));
    expect(parsedLyrics.lines.single.text, '测试歌词');
    final streamUri = Uri.parse(client.getStreamUrl('song-3'));
    expect(streamUri.path, '/music/api/v1/track/stream');
    expect(streamUri.queryParameters, {'guid': 'song-3'});
    expect(client.headers['Cookie'], 'music-token=token-1');
    expect(loginCount, 1);
    expect(meCount, 1);
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
}
