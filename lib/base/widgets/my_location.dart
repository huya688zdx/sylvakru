import 'package:material_ui/material_ui.dart';
import 'package:sylvakru/base/audio_handler.dart';
import 'package:sylvakru/base/asset_images.dart';
import 'package:sylvakru/base/my_audio_metadata.dart';

class MyLocation extends StatelessWidget {
  final ScrollController scrollController;
  final ValueNotifier<bool> listIsScrollingNotifier;
  final ValueNotifier<List<MyAudioMetadata>> currentSongListNotifier;
  final double offset;
  // 歌曲索引到列表显示行的映射（如歌单专辑结构模式插入了专辑头行）
  final int Function(int index)? displayIndexOf;
  const MyLocation({
    super.key,
    required this.scrollController,
    required this.listIsScrollingNotifier,
    required this.currentSongListNotifier,
    required this.offset,
    this.displayIndexOf,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        currentSongNotifier,
        currentSongListNotifier,
        listIsScrollingNotifier,
      ]),
      builder: (_, _) {
        if (currentSongNotifier.value == null ||
            !listIsScrollingNotifier.value) {
          return SizedBox.shrink();
        }
        final index = currentSongListNotifier.value.indexOf(
          currentSongNotifier.value!,
        );
        if (index == -1) {
          return SizedBox.shrink();
        }

        return IconButton(
          onPressed: () {
            final position = scrollController.position;
            final maxScrollExtent = position.maxScrollExtent;
            final minScrollExtent = position.minScrollExtent;
            final displayIndex = displayIndexOf?.call(index) ?? index;
            scrollController.animateTo(
              (60 * displayIndex + offset).clamp(
                minScrollExtent,
                maxScrollExtent,
              ),
              duration: Duration(milliseconds: 300),
              curve: Curves.linear,
            );
          },
          icon: ImageIcon(locationImage),
        );
      },
    );
  }
}
