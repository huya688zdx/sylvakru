import 'dart:async';
import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:rive_animated_icon/rive_animated_icon.dart';
import 'package:smooth_corner/smooth_corner.dart';
import 'package:sylvakru/base/app.dart';
import 'package:sylvakru/base/asset_images.dart';
import 'package:sylvakru/base/audio_handler.dart';
import 'package:sylvakru/base/data/artist_album.dart';
import 'package:sylvakru/base/services/color_manager.dart';
import 'package:sylvakru/base/services/interaction.dart';
import 'package:sylvakru/base/services/keyboard.dart';
import 'package:sylvakru/base/services/picture_service.dart';
import 'package:sylvakru/base/services/stream_client.dart';
import 'package:sylvakru/base/utils/common_utils.dart';
import 'package:sylvakru/base/utils/media_query.dart';
import 'package:sylvakru/base/utils/source_type.dart';
import 'package:sylvakru/base/widgets/cover_art_widget.dart';
import 'package:sylvakru/base/data/folder.dart';
import 'package:sylvakru/base/data/history.dart';
import 'package:sylvakru/base/data/library.dart';
import 'package:sylvakru/base/my_audio_metadata.dart';
import 'package:sylvakru/base/data/playlist.dart';
import 'package:sylvakru/base/utils/metadata_utils.dart';
import 'package:sylvakru/base/widgets/edit_metadata.dart';
import 'package:sylvakru/base/data/setting.dart';
import 'package:sylvakru/base/widgets/my_divider.dart';
import 'package:sylvakru/base/widgets/my_location.dart';
import 'package:sylvakru/base/widgets/my_sheet.dart';
import 'package:sylvakru/base/widgets/my_switch.dart';
import 'package:sylvakru/base/widgets/playlist_widgets.dart';
import 'package:sylvakru/base/widgets/selectable_song_list_page.dart';
import 'package:sylvakru/base/widgets/song_info.dart';
import 'package:sylvakru/l10n/generated/app_localizations.dart';
import 'package:sylvakru/landscape_view/title_bar.dart';
import 'package:sylvakru/layer/albums_layer.dart';
import 'package:sylvakru/layer/artists_layer.dart';
import 'package:sylvakru/layer/folders_layer.dart';
import 'package:sylvakru/layer/layers_manager.dart';
import 'package:sylvakru/layer/playlists_layer.dart';
import 'package:sylvakru/layer/ranking_layer.dart';
import 'package:sylvakru/layer/recently_layer.dart';
import 'package:sylvakru/portrait_view/custom_appbar_leading.dart';
import 'package:sylvakru/portrait_view/my_search_field.dart';
import 'package:text_scroll/text_scroll.dart';

part '../../landscape_view/panels/song_list_panel.dart';
part '../../portrait_view/pages/song_list_page.dart';

class SongList extends StatefulWidget {
  final Playlist? playlist;
  final Artist? artist;
  final Album? album;
  final Folder? folder;
  final bool isRanking;
  final bool isRecently;

  final bool isRoot;

  final String? albumRootLabel;

  const SongList({
    super.key,
    this.playlist,
    this.artist,
    this.album,
    this.folder,
    this.isRanking = false,
    this.isRecently = false,
    this.isRoot = true,

    this.albumRootLabel,
  });

  @override
  State<StatefulWidget> createState() => _SongListState();
}

class _SongListState extends State<SongList> {
  String title = '';
  List<MyAudioMetadata> songList = [];
  List<MyAudioMetadata> tmpSongList = [];

  Playlist? playlist;
  Artist? artist;
  Album? album;
  Folder? folder;

  bool isLibrary = false;
  bool isRanking = false;
  bool isRecently = false;

  bool canModify = false;

  Timer? timer;

  bool waitForSecondClick = false;
  Timer? doubleClicktimer;

  Timer? searchTimer;

  final currentSongListNotifier = ValueNotifier<List<MyAudioMetadata>>([]);

  // 专辑结构显示行：>=0 为 currentSongList 中的歌曲索引，
  // 负值 -(i+1) 表示从歌曲索引 i 开始的一段专辑的专辑头；
  // 收起的专辑不含歌曲行，行高统一 60，供定位换算使用
  List<int> albumStructureRows = [];
  // 各专辑段首曲在 currentSongList 中的索引（含收起的专辑），供分组渲染使用
  List<int> albumGroupStarts = [];
  // 专辑结构模式中被收起的专辑
  final collapsedAlbums = <String>{};

  final listIsScrollingNotifier = ValueNotifier(false);
  final scrollController = ScrollController();
  final textController = TextEditingController();

  String get searchValue => textController.text;

  bool isSearching = false;

  ValueNotifier<int> sortTypeNotifier = ValueNotifier(0);
  ValueNotifier<int> changeNotifier = ValueNotifier(0);

  Map<MyAudioMetadata, ValueNotifier<bool>> isSelectedNotifierMap = {};

  int continuousSelectBeginIndex = 0;

  final showPlayButtonNotifierMap = <MyAudioMetadata, ValueNotifier<bool>>{};

  final padding = const EdgeInsets.symmetric(horizontal: 30);

  ValueNotifier<bool>? rootVisibleNotifier;
  Function()? backToRoot;

  bool hideOthers = false;

  String rootLabel = '';

  bool prepareing = true;

  bool get reorderable {
    return !albumStructureActive &&
        searchValue.isEmpty &&
        sortTypeNotifier.value == 0 &&
        (playlist != null ||
            folder != null ||
            (isLibrary && isNotStreamSource));
  }

  bool get isFixed => isMobile || !reorderable;

  void updateHideOthers() {
    setState(() {
      hideOthers = rootVisibleNotifier!.value;
    });
  }

  String getTitleText(AppLocalizations l10n) {
    return isLibrary
        ? l10n.songs
        : playlist?.isFavorite == true
        ? l10n.favorites
        : isRanking
        ? l10n.ranking
        : isRecently
        ? l10n.recently
        : title;
  }

  // 歌单与所有歌曲页支持专辑结构显示，开关各自全局记忆
  bool get albumStructureSupported => playlist != null || isLibrary;

  ValueNotifier<bool> get albumStructureNotifier => playlist != null
      ? playlistManager.useAlbumStructureNotifier
      : songsUseAlbumStructureNotifier;

  bool get albumStructureActive =>
      albumStructureSupported && albumStructureNotifier.value;

  MyPicture? get mainPicture {
    MyPicture? picture = getFirstSong(songList)?.picture;
    if (isStreamSource) {
      if (artist != null) {
        picture = artist!.picture;
      } else if (album != null) {
        picture = album!.picture;
      }
    }
    return picture;
  }

  int currentRequestId = 0;
  Future<List<MyAudioMetadata>?> _fetchSongList(int offset) async {
    currentRequestId++;
    int tmp = currentRequestId;
    final result = await streamClient?.searchSongs(searchValue, 100, offset);
    if (!mounted) {
      return null;
    }
    if (tmp == currentRequestId) {
      return result;
    }
    return null;
  }

  void resetSelectedAndUpdateSongList() {
    continuousSelectBeginIndex = 0;
    for (final tmp in isSelectedNotifierMap.values) {
      tmp.value = false;
    }
    updateSongList();
  }

  void updateSongList() {
    prepareing = false;

    final currentSongList = List<MyAudioMetadata>.from(
      searchValue.isEmpty ? songList : tmpSongList,
    );

    showPlayButtonNotifierMap.clear();
    for (var e in currentSongList) {
      showPlayButtonNotifierMap[e] = ValueNotifier(false);
      isSelectedNotifierMap.putIfAbsent(e, () => ValueNotifier(false));
    }

    if (playlist != null) {
      canModify = playlist!.canModify;
    } else if (folder != null) {
      canModify = folder!.canModify;
    } else if (isLibrary) {
      canModify = library.canModify;
    }
    sortSongList(
      albumStructureActive ? 5 : sortTypeNotifier.value,
      currentSongList,
    );
    albumStructureRows = [];
    albumGroupStarts = [];
    if (albumStructureActive) {
      String? lastAlbum;
      for (int i = 0; i < currentSongList.length; i++) {
        final album = getAlbum(currentSongList[i]);
        if (album != lastAlbum) {
          lastAlbum = album;
          albumGroupStarts.add(i);
          albumStructureRows.add(-i - 1);
        }
        if (!collapsedAlbums.contains(album)) albumStructureRows.add(i);
      }
    }
    currentSongListNotifier.value = currentSongList;
  }

  void startNewSearchIfNeed() {
    if (prepareing) {
      return;
    }
    searchTimer?.cancel();
    searchTimer = Timer(Duration(milliseconds: 300), () async {
      if (searchValue.isNotEmpty) {
        tmpSongList.clear();
        if (isLibrary && sourceType == .navidrome) {
          tmpSongList = await _fetchSongList(0) ?? [];
          if (!mounted) {
            return;
          }
        } else {
          tmpSongList = filterSongList(songList, searchValue);
        }
      }
      _reachEnd = false;
      resetSelectedAndUpdateSongList();
    });
  }

  bool _isLoadingMoreData = false;
  bool _reachEnd = false;
  void _onScroll() async {
    if (prepareing | _isLoadingMoreData | _reachEnd) {
      return;
    }
    _isLoadingMoreData = true;

    if (scrollController.position.pixels >=
        scrollController.position.maxScrollExtent) {
      if (searchValue.isEmpty) {
        final fetchedSongList = await streamClient?.getSongs(
          100,
          songList.length,
        );
        if (!mounted) {
          return;
        }
        if (fetchedSongList == null) {
          _isLoadingMoreData = false;
          return;
        }
        _reachEnd = fetchedSongList.isEmpty;
        songList.addAll(fetchedSongList);
      } else {
        final fetchedSongList = await _fetchSongList(tmpSongList.length);
        if (!mounted) {
          return;
        }
        if (fetchedSongList == null) {
          _isLoadingMoreData = false;
          return;
        }
        _reachEnd = fetchedSongList.isEmpty;
        tmpSongList.addAll(fetchedSongList);
      }
      updateSongList();
    }
    _isLoadingMoreData = false;
  }

  @override
  void initState() {
    super.initState();

    playlist = widget.playlist;
    artist = widget.artist;
    album = widget.album;
    folder = widget.folder;
    isRanking = widget.isRanking;
    isRecently = widget.isRecently;

    if (playlist != null) {
      title = playlist!.name;
      songList = playlist!.songList;
      sortTypeNotifier = playlist!.sortTypeNotifier;
      changeNotifier = playlist!.changeNotifier;
      if (!widget.isRoot) {
        rootVisibleNotifier = playlistsVisibleNotifier;
        backToRoot = () {
          layersManager.popDetail('playlists');
        };
        rootLabel = 'playlists';
      }
    } else if (artist != null) {
      title = artist!.name;
      songList = artist!.songList;
      rootVisibleNotifier = artistsVisibleNotifier;
      backToRoot = () {
        layersManager.popDetail('artists');
      };
      rootLabel = 'artists';
      changeNotifier = artist!.changeNotifier;
    } else if (album != null) {
      title = album!.name;
      songList = album!.songList;
      rootLabel = widget.albumRootLabel!;
      if (rootLabel == 'albums') {
        rootVisibleNotifier = albumsVisibleNotifier;
      } else if (rootLabel == 'ranking') {
        rootVisibleNotifier = rankingVisibleNotifier;
      } else {
        rootVisibleNotifier = recentlyVisibleNotifier;
      }
      backToRoot = () {
        layersManager.popDetail(widget.albumRootLabel!);
      };
    } else if (folder != null) {
      title = folder!.id;
      songList = folder!.songList;
      sortTypeNotifier = folder!.sortTypeNotifier;
      changeNotifier = folder!.changeNotifier;
      rootVisibleNotifier = foldersVisibleNotifier;
      backToRoot = () {
        layersManager.popDetail('folders');
      };
      rootLabel = 'folders';
    } else if (isRanking) {
      songList = history.rankingSongList;
      history.rankingChangeNotifier.addListener(updateSongList);
    } else if (isRecently) {
      songList = history.recentlySongList;
      history.recentlyChangeNotifier.addListener(updateSongList);
    } else {
      isLibrary = true;
      songList = library.songList;
      library.changeNotifier.addListener(updateSongList);
      if (isStreamSource) {
        scrollController.addListener(_onScroll);
      }
    }

    rootVisibleNotifier?.addListener(updateHideOthers);

    if (albumStructureSupported) {
      albumStructureNotifier.addListener(updateSongList);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (isStreamSource) {
        if (songList.isEmpty) {
          if (isLibrary) {
            final songs = await streamClient?.getSongs(100, 0) ?? [];

            if (!mounted) {
              return;
            }
            songList.addAll(songs);
            layersManager.updateBackground();
          } else if (artist != null) {
            await artist!.load();
            if (!mounted) {
              return;
            }
          } else if (album != null) {
            await album!.load();
            if (!mounted) {
              return;
            }
          }
        }
      }
      updateSongList();
    });

    sortTypeNotifier.addListener(resetSelectedAndUpdateSongList);
    changeNotifier.addListener(updateSongList);
    textController.addListener(startNewSearchIfNeed);
  }

  // 收起/展开专辑段
  void toggleAlbumCollapsed(String album) {
    if (!collapsedAlbums.remove(album)) {
      collapsedAlbums.add(album);
    }
    updateSongList();
  }

  // 是否已全部收起（显示行中不再有歌曲行）
  bool get allAlbumsCollapsed =>
      albumStructureRows.isNotEmpty &&
      albumStructureRows.every((row) => row < 0);

  // 一键全部收起/展开
  void setAllAlbumsCollapsed(bool collapsed) {
    collapsedAlbums.clear();
    if (collapsed) {
      for (final song in currentSongListNotifier.value) {
        collapsedAlbums.add(getAlbum(song));
      }
    }
    updateSongList();
  }

  // 歌曲在专辑结构列表中的显示行；被收起时退回其专辑头所在行
  int albumStructureDisplayIndex(int index) {
    final display = albumStructureRows.indexOf(index);
    if (display != -1) {
      return display;
    }
    final list = currentSongListNotifier.value;
    final album = getAlbum(list[index]);
    for (int i = 0; i < albumStructureRows.length; i++) {
      final row = albumStructureRows[i];
      if (row < 0 && getAlbum(list[-row - 1]) == album) {
        return i;
      }
    }
    return 0;
  }

  // 专辑头对应专辑段的歌曲数（start 为该段首曲在 currentSongList 中的索引）
  int albumStructureGroupCount(int start) {
    final list = currentSongListNotifier.value;
    final album = getAlbum(list[start]);
    int end = start + 1;
    while (end < list.length && getAlbum(list[end]) == album) {
      end++;
    }
    return end - start;
  }

  @override
  void dispose() {
    rootVisibleNotifier?.removeListener(updateHideOthers);

    if (albumStructureSupported) {
      albumStructureNotifier.removeListener(updateSongList);
    }
    sortTypeNotifier.removeListener(resetSelectedAndUpdateSongList);
    changeNotifier.removeListener(updateSongList);
    textController.removeListener(startNewSearchIfNeed);
    scrollController.dispose();
    timer?.cancel();
    doubleClicktimer?.cancel();
    searchTimer?.cancel();
    super.dispose();
  }

  Widget mainCover(double size) {
    return ValueListenableBuilder(
      valueListenable: currentSongListNotifier,
      builder: (_, _, _) {
        MyPicture? picture = mainPicture;
        return ListenableBuilder(
          listenable: Listenable.merge([picture?.changeNotifier]),
          builder: (_, _) {
            return ValueListenableBuilder(
              valueListenable: mainPageThemeNotifier,
              builder: (_, _, _) {
                final coverArt = CoverArtWidget(
                  size: size,
                  borderRadius: size / 10,
                  picture: picture,
                  elevation: 5,
                  color: colorManager.getSpecificMainPageCoverArtBaseColorForm(
                    picture,
                  ), // keep stable color
                );

                return widget.isRoot
                    ? coverArt
                    : Hero(
                        tag:
                            (picture?.id ?? '') +
                            (album != null ? rootLabel : '') +
                            getTitleText(AppLocalizations.of(context)),
                        transitionOnUserGestures: true,
                        flightShuttleBuilder:
                            (
                              flightContext,
                              animation,
                              flightDirection,
                              fromHeroContext,
                              toHeroContext,
                            ) => FittedBox(child: toHeroContext.widget),
                        child: coverArt,
                      );
              },
            );
          },
        );
      },
    );
  }

  void moveToTop(int index) {
    final item = songList.removeAt(index);
    songList.insert(0, item);

    if (isLibrary) {
      library.update();
    } else if (folder != null) {
      folder!.update();
    } else {
      playlist!.update();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isTooNarrow(context)) {
      return pageView(context);
    }
    return panelView(context);
  }
}
