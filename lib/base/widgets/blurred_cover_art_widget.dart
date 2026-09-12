import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:sylvakru/base/services/picture_service.dart';

// 预模糊结果缓存：重开页面或来回切歌时直接复用，避免重复解码和模糊
final _blurredCoverCache = <String, ui.Image>{};
final _blurredCoverCacheKeys = <String>[];
const _blurredCoverCacheLimit = 12;

/// vivid 背景专用的预模糊封面。
///
/// 原实现是全屏 CoverArtWidget 叠 BackdropFilter，Impeller 下只要产出新帧
/// （进度条 tick、歌词滚动、跑马灯等）就要整屏重算一次高斯模糊，是播放页
/// 掉帧的大头。这里改为换歌时把封面按屏幕裁剪缩成小图、一次性模糊后缓存，
/// 之后每帧只画一张小纹理。sigmaX/sigmaY 与原 BackdropFilter 的屏幕空间
/// sigma 含义一致，内部按画布缩放比例换算，视觉效果与原来基本等价。
class BlurredCoverArtWidget extends StatefulWidget {
  final MyPicture? picture;
  final Color color;
  final double sigmaX;
  final double sigmaY;

  const BlurredCoverArtWidget({
    super.key,
    required this.picture,
    required this.color,
    required this.sigmaX,
    required this.sigmaY,
  });

  @override
  State<BlurredCoverArtWidget> createState() => _BlurredCoverArtWidgetState();
}

class _BlurredCoverArtWidgetState extends State<BlurredCoverArtWidget> {
  // 展示用的克隆句柄，生命周期独立于缓存，缓存淘汰不影响正在显示的图
  ui.Image? _image;
  String? _renderedKey;
  String? _pendingKey;

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final picture = widget.picture;
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (picture == null || width <= 0 || height <= 0) {
          _pendingKey = null;
          return Container(color: widget.color);
        }

        // 重模糊后没有高频细节，画布短边压到 270 足够，sigma 按同比例换算
        final scale = min(1.0, 270 / min(width, height));
        final canvasWidth = max(1, (width * scale).round());
        final canvasHeight = max(1, (height * scale).round());
        final sigmaX = widget.sigmaX * scale;
        final sigmaY = widget.sigmaY * scale;

        final key =
            '${picture.path}|${picture.changeNotifier.value}'
            '|${canvasWidth}x$canvasHeight'
            '|${sigmaX.toStringAsFixed(1)}|${sigmaY.toStringAsFixed(1)}'
            '|${widget.color.toARGB32()}';
        if (key == _renderedKey) {
          // 切回已显示的封面时，丢弃中途切歌留下的异步结果。
          _pendingKey = null;
        } else if (key != _pendingKey) {
          _pendingKey = key;
          final color = widget.color;
          // 微任务里再取图，避免在 build 期间同步 setState
          Future.microtask(
            () => _prepare(
              key,
              picture,
              color,
              canvasWidth,
              canvasHeight,
              sigmaX,
              sigmaY,
            ),
          );
        }

        if (_image == null) {
          return Container(color: widget.color);
        }
        // 换歌时保留旧图直到新图就绪，对齐原 Image 的 gaplessPlayback 行为
        return RawImage(image: _image, fit: BoxFit.fill);
      },
    );
  }

  Future<void> _prepare(
    String key,
    MyPicture picture,
    Color color,
    int canvasWidth,
    int canvasHeight,
    double sigmaX,
    double sigmaY,
  ) async {
    try {
      var cached = _blurredCoverCache[key];
      if (cached == null) {
        await loadPictureSafe(picture);
        if (!picture.isExist) {
          _setImage(null, key);
          return;
        }
        cached = await _renderBlurred(
          picture.path,
          color,
          canvasWidth,
          canvasHeight,
          sigmaX,
          sigmaY,
        );
        _blurredCoverCache[key] = cached;
        _blurredCoverCacheKeys.add(key);
        if (_blurredCoverCacheKeys.length > _blurredCoverCacheLimit) {
          _blurredCoverCache
              .remove(_blurredCoverCacheKeys.removeAt(0))
              ?.dispose();
        }
      } else {
        _blurredCoverCacheKeys.remove(key);
        _blurredCoverCacheKeys.add(key);
      }
      _setImage(cached.clone(), key);
    } catch (_) {
      _setImage(null, key);
    }
  }

  void _setImage(ui.Image? image, String key) {
    if (!mounted || key != _pendingKey) {
      image?.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
      _renderedKey = key;
      _pendingKey = null;
    });
  }

  Future<ui.Image> _renderBlurred(
    String path,
    Color color,
    int canvasWidth,
    int canvasHeight,
    double sigmaX,
    double sigmaY,
  ) async {
    final bytes = await File(path).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      // 只解码到画布所需分辨率，避免整幅解码大图
      final decodeScale = max(
        canvasWidth / descriptor.width,
        canvasHeight / descriptor.height,
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: max(1, (descriptor.width * decodeScale).ceil()),
        targetHeight: max(1, (descriptor.height * decodeScale).ceil()),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      final cover = frame.image;
      try {
        final rect = Rect.fromLTWH(
          0,
          0,
          canvasWidth.toDouble(),
          canvasHeight.toDouble(),
        );
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, rect);
        // 底色与原 CoverArtWidget 的 Material 底色一致
        canvas.drawRect(rect, Paint()..color = color);
        canvas.saveLayer(
          rect,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: sigmaX,
              sigmaY: sigmaY,
              tileMode: TileMode.clamp,
            ),
        );
        // 与原全屏 BoxFit.cover 相同的居中裁剪
        final coverWidth = cover.width.toDouble();
        final coverHeight = cover.height.toDouble();
        final srcScale = min(
          coverWidth / canvasWidth,
          coverHeight / canvasHeight,
        );
        final srcWidth = canvasWidth * srcScale;
        final srcHeight = canvasHeight * srcScale;
        final src = Rect.fromLTWH(
          (coverWidth - srcWidth) / 2,
          (coverHeight - srcHeight) / 2,
          srcWidth,
          srcHeight,
        );
        canvas.drawImageRect(
          cover,
          src,
          rect,
          Paint()..filterQuality = FilterQuality.medium,
        );
        canvas.restore();
        final picture = recorder.endRecording();
        final image = await picture.toImage(canvasWidth, canvasHeight);
        picture.dispose();
        return image;
      } finally {
        cover.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
