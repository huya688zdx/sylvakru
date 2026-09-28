/// fnOS 系统级加密 WebSocket 登录（官方客户端同款协议）与静默授权。
///
/// 供飞牛音源的"NAS 账号登录"与免密续登使用：
/// 1. 连接 ws(s)://<host>/websocket，`util.getSI` → `util.crypto.getRSAPub`；
///    客户端生成 AES-256-CBC key(32B)+IV(16B)，RSA-OAEP（hash=SHA-256，
///    MGF1=SHA-1）加密 key 放入信封 `rsa` 字段（带 `v:1`）。
/// 2. 敏感请求（如 `user.login`）整体放入信封；fnOS 对加密请求的响应可能是
///    明文 JSON，也可能用同一 key/IV 加密——两种都兼容。
/// 3. 免密续登 `user.tokenLogin` **不能走加密信封**（会被 token 长度判断拒绝，
///    errno 65534）：发"明文包 + HMAC-SHA256 签名"，格式为
///    `Base64(HMAC(bodyJson, secretBytes))` 前置拼接 `bodyJson`，且 body 必须
///    包含当前连接的 `si`。secret 为登录响应 `secret` 字段再用会话 key 解出的
///    16 字节。
/// 4. 拿到系统会话 token 后调 `/oauthapi/authorize` 即可直接换取目标应用的
///    登录 code（授权确认卡片只是 Web UI，API 本身静默放行）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart' show RSAPublicKey;
import 'package:pointycastle/asymmetric/oaep.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/digests/sha1.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

/// 原生 fn 登录失败。
class FnLoginException implements Exception {
  final String message;

  const FnLoginException(this.message);

  @override
  String toString() => 'FnLoginException: $message';
}

/// 账号开启两步验证；调用方可提示用户改用密码登录或处理验证码。
class FnTwoFactorRequired implements Exception {
  final String? accessToken;
  final bool bindTwofaSecret;

  const FnTwoFactorRequired({
    required this.accessToken,
    required this.bindTwofaSecret,
  });

  @override
  String toString() => 'FnTwoFactorRequired';
}

/// 系统登录成功后的会话信息。
class FnSystemSession {
  /// 本次系统会话 token，用于 /oauthapi/authorize。
  final String token;

  /// 30 天免密续登令牌。
  final String longToken;

  /// tokenLogin 明文包签名密钥（16 字节原始 secret 的 Base64）。
  final String secretBase64;

  final int uid;

  /// 本次登录使用的设备标识（应持久化以便免密续登）。
  final String did;

  const FnSystemSession({
    required this.token,
    required this.longToken,
    required this.secretBase64,
    required this.uid,
    required this.did,
  });
}

/// 已保存的免密续登凭据（按 fnOS 服务器隔离，存于系统安全存储）。
class FnSavedLogin {
  final String longToken;
  final String secretBase64;
  final String did;

  const FnSavedLogin({
    required this.longToken,
    required this.secretBase64,
    required this.did,
  });
}

/// 免密续登凭据存取（Windows DPAPI / Linux 钥匙环 / iOS 钥匙串 / Android
/// Keystore）。读取失败按无凭据处理，不阻断正常登录。
class FnSavedLoginStore {
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  static String _prefix(String serverKey) =>
      'feiniu_fn_login/${serverKey.trim().toLowerCase()}';

  static Future<FnSavedLogin?> read(String serverKey) async {
    if (serverKey.trim().isEmpty) return null;
    try {
      final token = await _storage.read(key: '${_prefix(serverKey)}/longToken');
      if (token == null || token.isEmpty) return null;
      final secret =
          await _storage.read(key: '${_prefix(serverKey)}/secret');
      final did = await _storage.read(key: '${_prefix(serverKey)}/did');
      return FnSavedLogin(
        longToken: token,
        secretBase64: secret ?? '',
        did: did ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(
    String serverKey, {
    required String longToken,
    required String secretBase64,
    required String did,
  }) async {
    if (serverKey.trim().isEmpty || longToken.isEmpty) return;
    try {
      await _storage.write(
          key: '${_prefix(serverKey)}/longToken', value: longToken);
      if (secretBase64.isNotEmpty) {
        await _storage.write(
            key: '${_prefix(serverKey)}/secret', value: secretBase64);
      }
      if (did.isNotEmpty) {
        await _storage.write(key: '${_prefix(serverKey)}/did', value: did);
      }
    } catch (_) {
      // 安全存储不可用时静默放弃，下次登录重新输入密码即可。
    }
  }

  static Future<void> clear(String serverKey) async {
    if (serverKey.trim().isEmpty) return;
    try {
      await _storage.delete(key: '${_prefix(serverKey)}/longToken');
      await _storage.delete(key: '${_prefix(serverKey)}/secret');
      await _storage.delete(key: '${_prefix(serverKey)}/did');
    } catch (_) {}
  }
}

/// fnOS 系统加密 WebSocket 登录与静默授权的纯原生实现。
class FnNativeSystemLogin {
  static const String _deviceType = 'pc';
  static const String _deviceName = 'Sylvakru';

  /// 推导系统 WebSocket 地址（https→wss，http→ws，路径固定 /websocket）。
  static String webSocketUrlOf(String baseUrl) {
    final uri = Uri.parse(normalizeFnBaseUrl(baseUrl));
    return uri.replace(
      scheme: uri.scheme.toLowerCase() == 'https' ? 'wss' : 'ws',
      path: '/websocket',
    ).toString();
  }

  static bool isRelayHost(String baseUrl) {
    final host = Uri.parse(normalizeFnBaseUrl(baseUrl)).host.toLowerCase();
    return host == 'fnos.net' ||
        host.endsWith('.fnos.net') ||
        host == '5ddd.com' ||
        host.endsWith('.5ddd.com');
  }

  /// 账号密码登录系统。
  ///
  /// [did] 传调用方持久化的设备标识；缺省时生成随机 UUID（调用方应保存
  /// [FnSystemSession.did]）。
  static Future<FnSystemSession> login({
    required String baseUrl,
    required String userName,
    required String password,
    String? did,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _runEncryptedSession(
      baseUrl: baseUrl,
      timeout: timeout,
      action: (channel, si) async {
        final data = await channel.sendEncrypted(<String, dynamic>{
          'req': 'user.login',
          'user': userName,
          'password': password,
          'stay': 2,
          'deviceType': _deviceType,
          'deviceName': _deviceName,
          'did': did ?? generateDeviceId(),
          'si': si,
        });
        return _sessionFromResponse(data, did: did);
      },
    );
  }

  /// 使用已保存的 longToken 免密续登（全程不接触密码）。
  static Future<FnSystemSession> loginWithLongToken({
    required String baseUrl,
    required String longToken,
    required Uint8List secretBytes,
    String? did,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (secretBytes.isEmpty) {
      throw const FnLoginException('saved login requires the session secret');
    }
    final channel = await _openChannel(baseUrl, timeout);
    try {
      final si = await channel.getSystemIdentifier();
      final body = jsonEncode(<String, dynamic>{
        'req': 'user.tokenLogin',
        'token': longToken,
        'deviceType': _deviceType,
        'deviceName': _deviceName,
        'did': did ?? generateDeviceId(),
        'si': si,
      });
      final hmac = Hmac(sha256, secretBytes);
      final signed =
          base64Encode(hmac.convert(utf8.encode(body)).bytes) + body;
      return _sessionFromResponse(await channel.sendPlain(signed), did: did);
    } on FnTwoFactorRequired {
      rethrow;
    } on FnLoginException {
      rethrow;
    } catch (error) {
      throw FnLoginException('token login failed: $error');
    } finally {
      // longToken 续登要求原会话已结束，等待连接真正关闭。
      await channel.close();
    }
  }

  /// 用系统会话 token 静默换取目标应用（音乐/影视等）的登录 code。
  ///
  /// [redirectPath] 为目标应用注册的 OAuth 回调路径（如音乐为
  /// `/music/oauth/result`）；[relay] 为 true 时附带 mode=relay cookie。
  static Future<String> requestAuthorizeCode({
    required String baseUrl,
    required String systemToken,
    required String clientId,
    required String redirectPath,
    bool relay = false,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final normalized = normalizeFnBaseUrl(baseUrl);
    final dio = Dio()
      ..options.baseUrl = normalized
      ..options.connectTimeout = timeout
      ..options.receiveTimeout = timeout;
    final body = <String, dynamic>{
      'token': systemToken,
      'client_id': clientId,
      'redirect_uri': '$normalized$redirectPath',
      'state': '',
      'response_type': 'code',
    };
    final response = await dio.post(
      '/oauthapi/authorize',
      data: body,
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          if (relay) 'Cookie': 'mode=relay',
        },
      ),
    );
    final payload = response.data;
    if (payload is! Map) {
      throw const FnLoginException('invalid authorize response format');
    }
    if (payload['code'] != 0) {
      throw FnLoginException(
        'authorize failed: ${payload['msg'] ?? payload['message'] ?? payload['code']}',
      );
    }
    final data = payload['data'];
    final code =
        data is Map ? (data['code'] ?? '').toString().trim() : '';
    if (code.isEmpty) {
      throw const FnLoginException('authorize response missing code');
    }
    return code;
  }

  /// 生成可持久化的设备标识（UUID v4）。
  static String generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static FnSystemSession _sessionFromResponse(
    Map<String, dynamic> data, {
    String? did,
  }) {
    if (data['isTwofaEnforced'] == true) {
      throw FnTwoFactorRequired(
        accessToken: (data['accessToken'] ?? '').toString(),
        bindTwofaSecret: data['isBindTwofaSecret'] == true,
      );
    }
    if (data['result'] != 'succ') {
      final errno = data['errno'];
      throw FnLoginException(
        'system login failed: ${data['msg'] ?? data['result'] ?? 'fail'}'
        '${errno == null ? '' : ' (errno=$errno)'}',
      );
    }
    final token = (data['token'] ?? '').toString();
    if (token.isEmpty) {
      throw const FnLoginException('system login response missing token');
    }
    return FnSystemSession(
      token: token,
      longToken: (data['longToken'] ?? '').toString(),
      secretBase64: (data['secret'] ?? '').toString(),
      uid: data['uid'] is num ? (data['uid'] as num).toInt() : 0,
      did: (data['did'] ?? did ?? '').toString(),
    );
  }

  static Future<FnSystemSession> _runEncryptedSession({
    required String baseUrl,
    required Duration timeout,
    required Future<FnSystemSession> Function(
            _EncryptedWebSocket channel, String si)
        action,
  }) async {
    final channel = await _openChannel(baseUrl, timeout);
    try {
      final si = await channel.getSystemIdentifier();
      await channel.establishEncryption(si);
      return await action(channel, si).timeout(timeout);
    } on FnTwoFactorRequired {
      rethrow;
    } on FnLoginException {
      rethrow;
    } catch (error) {
      throw FnLoginException('system login failed: $error');
    } finally {
      // longToken 续登要求原会话已结束，等待连接真正关闭。
      await channel.close();
    }
  }

  static Future<_EncryptedWebSocket> _openChannel(
    String baseUrl,
    Duration timeout,
  ) {
    final url = webSocketUrlOf(baseUrl);
    final headers = <String, String>{
      if (isRelayHost(baseUrl)) 'Cookie': 'mode=relay',
    };
    return _EncryptedWebSocket.connect(
      url: url,
      headers: headers,
      timeout: timeout,
    );
  }
}

/// 单次 WebSocket 会话：getSI → getRSAPub → 信封加密请求 / 明文签名请求。
class _EncryptedWebSocket {
  final WebSocketChannel _channel;
  final Duration _timeout;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final List<Map<String, dynamic>> _unsolicited = [];
  Uint8List? _key;
  Uint8List? _iv;
  Uint8List? _rsaEnvelope;
  int _reqId = 0;
  bool _closed = false;

  _EncryptedWebSocket._(this._channel, this._timeout) {
    _channel.stream.listen(_onData, onError: _failAll, onDone: _failClosed);
  }

  static Future<_EncryptedWebSocket> connect({
    required String url,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final channel =
        IOWebSocketChannel.connect(Uri.parse(url), headers: headers);
    await channel.ready.timeout(timeout);
    return _EncryptedWebSocket._(channel, timeout);
  }

  Future<String> getSystemIdentifier() async {
    final reply = await _request({'req': 'util.getSI'});
    final si = (reply['si'] ?? '').toString();
    if (si.isEmpty) {
      throw const FnLoginException('system handshake missing si');
    }
    return si;
  }

  Future<void> establishEncryption(String si) async {
    final reply = await _request({'req': 'util.crypto.getRSAPub', 'si': si});
    final pubPem = (reply['pub'] ?? '').toString();
    if (!pubPem.contains('BEGIN PUBLIC KEY')) {
      throw const FnLoginException('system handshake missing RSA public key');
    }
    final random = Random.secure();
    _key = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)));
    _iv =
        Uint8List.fromList(List<int>.generate(16, (_) => random.nextInt(256)));
    _rsaEnvelope = _encryptRsaOaep(parseSpkiPem(pubPem), _key!);
  }

  /// 发送加密信封请求并解密响应（响应可能是明文，两种都兼容）。
  Future<Map<String, dynamic>> sendEncrypted(
    Map<String, dynamic> innerRequest,
  ) async {
    final key = _key;
    final iv = _iv;
    final rsaEnvelope = _rsaEnvelope;
    if (key == null || iv == null || rsaEnvelope == null) {
      throw StateError('encryption not established');
    }
    final reply = await _request(<String, dynamic>{
      'req': 'encrypted',
      'iv': base64Encode(iv),
      'rsa': base64Encode(rsaEnvelope),
      'aes': base64Encode(encryptAesCbcPkcs7(
        key: key,
        iv: iv,
        input: utf8.encode(jsonEncode(innerRequest)),
      )),
      'si': innerRequest['si'] ?? '',
      'v': 1,
    });
    final aes = (reply['aes'] ?? '').toString();
    final decrypted = aes.isEmpty
        ? reply
        : decryptAesCbcPkcs7(key: key, iv: iv, input: base64Decode(aes));
    // 登录响应的 secret 是"再加密一层"的字符串（同一 key/IV），解出 16 字节
    // 原始 secret 转存为 Base64，供 tokenLogin 明文签名包使用。
    final secretField = (decrypted['secret'] ?? '').toString();
    if (secretField.isNotEmpty) {
      try {
        decrypted['secret'] = base64Encode(decryptAesCbcPkcs7Bytes(
          key: key,
          iv: iv,
          input: base64Decode(secretField),
        ));
      } catch (_) {
        // 解不出原始 secret 时保留原值，免密续登将不可用。
      }
    }
    return decrypted;
  }

  /// 发送"HMAC 签名前置 + JSON body"的明文包（user.tokenLogin）。
  Future<Map<String, dynamic>> sendPlain(String payload) {
    if (_closed) {
      return Future.error(const SocketClosedBeforeReply());
    }
    if (_unsolicited.isNotEmpty) {
      return Future.value(_unsolicited.removeAt(0));
    }
    _reqId += 1;
    final tag = 'plain-$_reqId';
    final completer = Completer<Map<String, dynamic>>();
    _pending[tag] = completer;
    _channel.sink.add(payload);
    return completer.future.timeout(_timeout, onTimeout: () {
      _pending.remove(tag);
      throw TimeoutException('fn system websocket request timeout');
    });
  }

  void _onData(dynamic frame) {
    Map<String, dynamic>? message;
    try {
      final text = frame is String
          ? frame
          : frame is List<int>
              ? utf8.decode(frame)
              : null;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) message = decoded;
    } catch (_) {
      return;
    }
    if (message == null) return;
    // 加密信封/明文签名包的响应可能不回显 reqid：优先精确匹配，否则按序
    // 交付给最早的待响应请求（连接内请求是串行的）。
    final reqId = (message['reqid'] ?? '').toString();
    if (reqId.isNotEmpty) {
      final completer = _pending.remove(reqId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message);
        return;
      }
    }
    if (_pending.isNotEmpty) {
      final key = _pending.keys.first;
      final completer = _pending.remove(key);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message);
        return;
      }
    }
    _unsolicited.add(message);
  }

  void _failAll(Object error) {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  void _failClosed() => _failAll(const SocketClosedBeforeReply());

  Future<Map<String, dynamic>> _request(Map<String, dynamic> request) {
    if (_closed) {
      return Future.error(const SocketClosedBeforeReply());
    }
    if (_unsolicited.isNotEmpty) {
      return Future.value(_unsolicited.removeAt(0));
    }
    _reqId += 1;
    final reqId = _reqId.toString();
    final completer = Completer<Map<String, dynamic>>();
    _pending[reqId] = completer;
    _channel.sink.add(jsonEncode({...request, 'reqid': reqId}));
    return completer.future.timeout(_timeout, onTimeout: () {
      _pending.remove(reqId);
      throw TimeoutException('fn system websocket request timeout');
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.sink.close(ws_status.normalClosure);
    } catch (_) {
      // 连接可能已被对端断开。
    }
  }
}

class SocketClosedBeforeReply implements Exception {
  const SocketClosedBeforeReply();

  @override
  String toString() => 'fn system websocket closed before reply';
}

Uint8List encryptAesCbcPkcs7({
  required Uint8List key,
  required Uint8List iv,
  required List<int> input,
}) {
  final cipher = _paddedCipher(key, iv);
  return cipher.process(Uint8List.fromList(input));
}

Map<String, dynamic> decryptAesCbcPkcs7({
  required Uint8List key,
  required Uint8List iv,
  required List<int> input,
}) {
  final plain = decryptAesCbcPkcs7Bytes(key: key, iv: iv, input: input);
  final decoded = jsonDecode(utf8.decode(plain));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('decrypted envelope payload is not an object');
  }
  return decoded;
}

Uint8List decryptAesCbcPkcs7Bytes({
  required Uint8List key,
  required Uint8List iv,
  required List<int> input,
}) {
  final cipher = _paddedCipher(key, iv, forEncryption: false);
  return cipher.process(Uint8List.fromList(input));
}

PaddedBlockCipher _paddedCipher(
  Uint8List key,
  Uint8List iv, {
  bool forEncryption = true,
}) {
  return PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
      forEncryption,
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      ),
    );
}

Uint8List _encryptRsaOaep(RSAPublicKey publicKey, Uint8List input) {
  // 与 fnOS Web 客户端一致：OAEP hash=SHA-256，MGF1=SHA-1。
  final cipher = OAEPEncoding.withSHA256(RSAEngine())
    ..mgf1Hash = SHA1Digest()
    ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
  return cipher.process(input);
}

class _DerTlv {
  final int tag;
  final Uint8List content;
  final int next;

  const _DerTlv({
    required this.tag,
    required this.content,
    required this.next,
  });
}

_DerTlv _readTlv(Uint8List bytes, int pos) {
  if (pos + 2 > bytes.length) {
    throw const FormatException('truncated DER structure');
  }
  final tag = bytes[pos];
  var length = bytes[pos + 1] & 0x7f;
  var headerSize = 2;
  if ((bytes[pos + 1] & 0x80) != 0) {
    final byteCount = length;
    if (byteCount == 0 || pos + 2 + byteCount > bytes.length) {
      throw const FormatException('invalid DER length header');
    }
    length = 0;
    for (var i = 0; i < byteCount; i++) {
      length = (length << 8) | bytes[pos + 2 + i];
    }
    headerSize = 2 + byteCount;
  }
  if (pos + headerSize + length > bytes.length) {
    throw const FormatException('DER content exceeds buffer');
  }
  return _DerTlv(
    tag: tag,
    content: Uint8List.sublistView(
        bytes, pos + headerSize, pos + headerSize + length),
    next: pos + headerSize + length,
  );
}

BigInt _derIntegerToBigInt(Uint8List content) {
  if (content.isEmpty) return BigInt.zero;
  final hex = content
      .map((b) => '${(b >> 4).toRadixString(16)}${(b & 0x0f).toRadixString(16)}')
      .join();
  return BigInt.parse(hex, radix: 16);
}

/// 解析 `-----BEGIN PUBLIC KEY-----`（SPKI DER）中的 RSA 公钥。
RSAPublicKey parseSpkiPem(String pem) {
  final base64Body = pem
      .split(RegExp(r'-----[A-Z ]+-----'))
      .map((part) => part.replaceAll(RegExp(r'\s'), ''))
      .where((part) => part.isNotEmpty)
      .join();
  final bytes = Uint8List.fromList(base64Decode(base64Body));

  final spki = _readTlv(bytes, 0);
  if (spki.tag != 0x30) {
    throw const FormatException('expected SPKI SEQUENCE');
  }
  final algorithm = _readTlv(spki.content, 0);
  final bitStringTlv = _readTlv(spki.content, algorithm.next);
  if (bitStringTlv.tag != 0x03) {
    throw const FormatException('expected BIT STRING for subjectPublicKey');
  }
  final bitString = bitStringTlv.content;
  if (bitString.isEmpty || bitString[0] != 0) {
    throw const FormatException('unsupported BIT STRING padding');
  }
  final keySeqBytes = Uint8List.sublistView(bitString, 1);
  final keySeq = _readTlv(keySeqBytes, 0);
  if (keySeq.tag != 0x30) {
    throw const FormatException('expected RSA key SEQUENCE');
  }
  final modulusTlv = _readTlv(keySeq.content, 0);
  final exponentTlv = _readTlv(keySeq.content, modulusTlv.next);
  return RSAPublicKey(
    _derIntegerToBigInt(modulusTlv.content),
    _derIntegerToBigInt(exponentTlv.content),
  );
}

String normalizeFnBaseUrl(String raw) {
  var url = raw.trim();
  if (url.isEmpty) return url;
  if (!url.contains('://')) url = 'https://$url';
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}
