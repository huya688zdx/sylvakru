import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/base/app.dart';
import 'package:sylvakru/base/widgets/settings_list.dart';
import 'package:sylvakru/big_picture_view/panels/big_settings_panel.dart';
import 'package:sylvakru/l10n/generated/app_localizations.dart';
import 'package:sylvakru/layer/audio_output_settings_layer.dart';

class _RouteObserver extends NavigatorObserver {
  int popCount = 0;
  int pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount++;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount++;
    super.didPop(route, previousRoute);
  }
}

Future<void> _pumpBigPictureAudioOutput(
  WidgetTester tester, {
  NavigatorObserver? observer,
  Size surfaceSize = const Size(1200, 800),
}) async {
  final previousViewMode = viewModeNotifier.value;
  viewModeNotifier.value = ViewMode.bigPicture;
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() async {
    viewModeNotifier.value = previousViewMode;
    await tester.binding.setSurfaceSize(null);
  });

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: observer == null ? const [] : [observer],
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => pushBigPictureAudioOutputSettings(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  final appSupportDirectory = Directory.systemTemp.createTempSync(
    'sylvakru_big_picture_settings_test',
  );
  appSupportDir = appSupportDirectory;
  tearDownAll(() => appSupportDirectory.deleteSync(recursive: true));

  testWidgets('大图音频输出页通过 Navigator 返回设置列表', (tester) async {
    final observer = _RouteObserver();
    await _pumpBigPictureAudioOutput(tester, observer: observer);
    await tester.tap(find.byIcon(Icons.arrow_back_ios_rounded));
    await tester.pumpAndSettle();

    expect(observer.popCount, 1);
  });

  testWidgets('窄屏大图音频输出页仍通过 Navigator 返回', (tester) async {
    final observer = _RouteObserver();
    await _pumpBigPictureAudioOutput(
      tester,
      observer: observer,
      surfaceSize: const Size(700, 1200),
    );
    await tester.tap(find.byIcon(Icons.arrow_back_ios_rounded));
    await tester.pumpAndSettle();

    expect(observer.popCount, 1);
  });

  testWidgets('大图设置面板将音频输出入口接入详情路由', (tester) async {
    final previousViewMode = viewModeNotifier.value;
    viewModeNotifier.value = ViewMode.bigPicture;
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async {
      viewModeNotifier.value = previousViewMode;
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const BigSettingsPanel(),
      ),
    );

    final settingsList = tester.widget<SettingsList>(find.byType(SettingsList));
    final onAudioOutputTap = settingsList.onAudioOutputTap;
    expect(onAudioOutputTap, isNotNull);
    if (onAudioOutputTap == null) {
      return;
    }

    onAudioOutputTap();
    await tester.pumpAndSettle();

    expect(find.byType(AudioOutputSettingsLayer), findsOneWidget);
  });

  testWidgets('大图音频输出页可以进入 DSD 模式详情', (tester) async {
    final observer = _RouteObserver();
    await _pumpBigPictureAudioOutput(tester, observer: observer);
    expect(observer.pushCount, 2);

    await tester.tap(find.text('DSD mode'));
    await tester.pumpAndSettle();

    expect(observer.pushCount, 3);
    expect(
      tester
          .widget<AudioOutputSettingsLayer>(
            find.byType(AudioOutputSettingsLayer),
          )
          .pageKind,
      AudioOutputSettingsPageKind.dsdMode,
    );
  });

  testWidgets('大图音频输出页可以进入回放增益详情', (tester) async {
    final observer = _RouteObserver();
    await _pumpBigPictureAudioOutput(tester, observer: observer);
    expect(observer.pushCount, 2);

    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ReplayGain'));
    await tester.pumpAndSettle();

    expect(observer.pushCount, 3);
    expect(
      tester
          .widget<AudioOutputSettingsLayer>(
            find.byType(AudioOutputSettingsLayer),
          )
          .pageKind,
      AudioOutputSettingsPageKind.replayGain,
    );
  });
}
