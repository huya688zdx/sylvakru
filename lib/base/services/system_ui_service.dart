import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:sylvakru/base/app.dart';

SystemUiMode? _appliedUiMode;
List<SystemUiOverlay>? _appliedOverlays;

// 系统 UI 模式只在目标变化时应用，不能放在 build 里每次重设：全面屏手势
// 上滑时系统临时显示系统栏 → insets 变化触发重建 → 立刻又把栏藏回去，
// 返回桌面的手势被打断（平板宽屏沉浸模式下上滑卡住回不了桌面）。
void applySystemUiMode({
  SystemUiMode? mode,
  List<SystemUiOverlay>? overlays,
  bool forceApply = false,
}) {
  if (!forceApply) {
    if (_appliedUiMode == mode && listEquals(_appliedOverlays, overlays)) {
      return;
    }
    _appliedUiMode = mode;
    _appliedOverlays = overlays;
  }

  if (_appliedUiMode == SystemUiMode.manual) {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: _appliedOverlays ?? [SystemUiOverlay.top],
    );
  } else {
    if (_appliedUiMode != null) {
      SystemChrome.setEnabledSystemUIMode(_appliedUiMode!);
    }
  }
}

// 宽布局的系统条由三个设置共同决定：沉浸模式开 → 全部隐藏；
// 沉浸模式关 → 顶/底系统条分别由两个开关控制。
void applyWideLayoutSystemUiMode() {
  if (immersiveWideLayoutNotifier.value) {
    applySystemUiMode(mode: .immersiveSticky);
  } else {
    applySystemUiMode(
      mode: .manual,
      overlays: [
        if (wideShowTopSystemBarNotifier.value) SystemUiOverlay.top,
        if (wideShowBottomSystemBarNotifier.value) SystemUiOverlay.bottom,
      ],
    );
  }
}
