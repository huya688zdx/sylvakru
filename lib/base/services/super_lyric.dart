import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sylvakru/base/services/lyric.dart';

/// 状态栏“超级歌词”桥接：按播放位置把当前歌词行推送给外部歌词插件。
/// 合并了原先的行定位与通道发送两层，去掉多余的中间封装。
class SuperLyric {
  static const _channel = MethodChannel('com.afalphy.sylvakru/super_lyric');
  static final bool _isAndroid = Platform.isAndroid;

  List<LyricLine> _lines = const [];
  int? _lastPublishedIndex;
  String? _lastSent;
  bool _hasSentStop = false;

  void updateLines(List<LyricLine> lines) {
    _lines = lines;
    reset();
  }

  void reset() {
    _lastPublishedIndex = null;
  }

  Future<void> publishAt(Duration position) async {
    if (position < Duration.zero) {
      return;
    }
    final index = _currentIndexAt(position);
    if (index == _lastPublishedIndex) {
      return;
    }
    _lastPublishedIndex = index;
    if (index >= 0 && index < _lines.length) {
      await _sendLine(_lines[index]);
    } else {
      await sendStop();
    }
  }

  Future<void> sendStop() async {
    if (_hasSentStop) {
      return;
    }
    _lastSent = null;
    _hasSentStop = true;
    if (_isAndroid) {
      await _invoke('sendStop', null);
    }
  }

  Future<void> _sendLine(LyricLine line) async {
    final text = line.text.trim();
    if (_shouldStop(text)) {
      await sendStop();
      return;
    }

    final arguments = _lineToArguments(line, text);
    final key = arguments.toString();
    if (key == _lastSent) {
      return;
    }
    _lastSent = key;
    _hasSentStop = false;
    if (_isAndroid) {
      await _invoke('sendLyric', arguments);
    }
  }

  Future<void> _invoke(String method, Object? arguments) async {
    try {
      if (await _channel.invokeMethod<bool>(method, arguments) == true) {
        return;
      }
    } on PlatformException {
      // 通道暂时不可用，留给下一次播放位置更新重试。
    } on MissingPluginException {
      // 原生通道尚未就绪，不能把当前行记为已发送。
    }
    // 原生端返回 false 也表示未送出；同时清除两层去重和停止状态。
    _lastPublishedIndex = null;
    _lastSent = null;
    _hasSentStop = false;
  }

  int _currentIndexAt(Duration position) {
    var current = -1;
    for (var i = 0; i < _lines.length; i++) {
      if (position < _lines[i].start) {
        break;
      }
      if (current == -1 || _lines[i].start > _lines[current].start) {
        current = i;
      }
    }
    return current;
  }

  bool _shouldStop(String lyric) {
    return lyric.isEmpty ||
        lyric == 'There are no lyrics' ||
        lyric == 'Lyrics parsing failed';
  }

  Map<String, Object?> _lineToArguments(LyricLine line, String text) {
    return {
      'lyric': text,
      'startTime': line.start.inMilliseconds,
      'endTime': line.tokens.isEmpty
          ? null
          : line.tokens.last.end?.inMilliseconds,
      'tokens': line.tokens
          .where((token) => token.text.isNotEmpty && token.end != null)
          .map(
            (token) => {
              'text': token.text,
              'startTime': token.start.inMilliseconds,
              'endTime': token.end!.inMilliseconds,
            },
          )
          .toList(growable: false),
    };
  }
}
