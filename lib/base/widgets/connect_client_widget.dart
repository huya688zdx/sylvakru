import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:sylvakru/base/app.dart';
import 'package:sylvakru/base/data/config.dart';
import 'package:sylvakru/base/data/library.dart';
import 'package:sylvakru/base/data/loader.dart';
import 'package:sylvakru/base/services/color_manager.dart';
import 'package:sylvakru/base/services/emby_client.dart';
import 'package:sylvakru/base/services/feiniu_client.dart';
import 'package:sylvakru/base/services/fn_native_login.dart';
import 'package:sylvakru/base/services/interaction.dart';
import 'package:sylvakru/base/services/logger.dart';
import 'package:sylvakru/base/services/navidrome_client.dart';
import 'package:sylvakru/base/services/stream_client.dart';
import 'package:sylvakru/base/services/webdav_client.dart';
import 'package:sylvakru/base/utils/source_type.dart';
import 'package:sylvakru/base/widgets/custom_text_field.dart';
import 'package:sylvakru/l10n/generated/app_localizations.dart';

class ConnectClientWidget extends StatefulWidget {
  final SourceType sourceType;

  const ConnectClientWidget({super.key, required this.sourceType});

  @override
  State<StatefulWidget> createState() => _ConnectClientWidgetState();
}

class _ConnectClientWidgetState extends State<ConnectClientWidget> {
  final baseUrlTmp = TextEditingController();
  final usernameTmp = TextEditingController();
  final passwordTmp = TextEditingController();
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    if (widget.sourceType == .webdav) {
      baseUrlTmp.text = webdavClient?.baseUrl ?? '';
      usernameTmp.text = webdavClient?.username ?? '';
      passwordTmp.text = webdavClient?.password ?? '';
    } else if (widget.sourceType == .navidrome) {
      baseUrlTmp.text = config.navidromeBaseUrl ?? '';
      usernameTmp.text = config.navidromeUsername ?? '';
      passwordTmp.text = config.navidromePassword ?? '';
    } else if (widget.sourceType == .emby) {
      baseUrlTmp.text = config.embyBaseUrl ?? '';
      usernameTmp.text = config.embyUsername ?? '';
      passwordTmp.text = config.embyPassword ?? '';
    } else if (widget.sourceType == .feiniu) {
      baseUrlTmp.text = config.feiniuBaseUrl ?? '';
      usernameTmp.text = config.feiniuUsername ?? '';
      passwordTmp.text = config.feiniuPassword ?? '';
    }
  }

  @override
  void dispose() {
    baseUrlTmp.dispose();
    usernameTmp.dispose();
    passwordTmp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final urlLabel = widget.sourceType == .feiniu
        ? l10n.feiniuServerAddress
        : 'Url';

    return SizedBox(
      width: 300,
      child: Padding(
        padding: .fromLTRB(20, 15, 20, 15),
        child: Column(
          mainAxisAlignment: .center,
          mainAxisSize: .min,
          children: [
            if (!firstLaunch)
              SizedBox(
                child: Text(
                  getSourceTypeDisplayName(l10n, widget.sourceType),
                  style: .new(fontWeight: .bold, fontSize: 18),
                ),
              ),

            SizedBox(height: 10),
            isTV
                ? fakeTextField(urlLabel, baseUrlTmp)
                : CustomTextField(urlLabel, baseUrlTmp, compact: false),

            SizedBox(height: 10),
            isTV
                ? fakeTextField(l10n.username, usernameTmp)
                : CustomTextField(l10n.username, usernameTmp, compact: false),

            SizedBox(height: 10),
            isTV
                ? fakeTextField(l10n.password, passwordTmp)
                : CustomTextField(
                    l10n.password,
                    passwordTmp,
                    needObscure: true,
                    compact: false,
                  ),

            SizedBox(height: isMobile ? 10 : 25),

            if (widget.sourceType == .feiniu)
              TextButton(
                onPressed: _connecting ? null : () => onSave(nasLogin: true),
                style: TextButton.styleFrom(foregroundColor: textColor.value),
                child: Text(l10n.feiniuNasLogin),
              ),

            buttons(),
          ],
        ),
      ),
    );
  }

  Widget fakeTextField(String title, TextEditingController textController) {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text('$title:', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        InkWell(
          onTap: () async {
            textController.text = await getInputTextDialog(
              context,
              title,
              needConfirm: false,
            );
            setState(() {});
          },
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              border: Border.all(color: textColor.value),
            ),
            child: Text(textController.text, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
  }

  Widget buttons() {
    return ValueListenableBuilder(
      valueListenable: buttonColor.valueNotifier,
      builder: (context, value, child) {
        final l10n = AppLocalizations.of(context);

        return Row(
          children: [
            Spacer(),

            if (!firstLaunch)
              ElevatedButton(
                onPressed: _connecting ? null : () => onDelete(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: firstLaunch ? null : value,
                ),
                child: Text(l10n.delete),
              ),

            if (!firstLaunch) SizedBox(width: 20),

            firstLaunch
                ? Card(
                    clipBehavior: .antiAlias,
                    child: InkWell(
                      mouseCursor: SystemMouseCursors.click,
                      onTap: _connecting ? null : onSave,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 8,
                        ),
                        child: Text(l10n.save),
                      ),
                    ),
                  )
                : ElevatedButton(
                    onPressed: _connecting ? null : () => onSave(),
                    style: ElevatedButton.styleFrom(backgroundColor: value),
                    child: Text(l10n.save),
                  ),
            Spacer(),
          ],
        );
      },
    );
  }

  void onDelete() async {
    if (!await showConfirmDialog(
      context,
      AppLocalizations.of(context).delete,
    )) {
      return;
    }
    if (widget.sourceType == .webdav) {
      await library.updateFolders([]);
      webdavClient = null;
    } else if (widget.sourceType == .navidrome) {
      config.navidromeBaseUrl = null;
      config.navidromeUsername = null;
      config.navidromePassword = null;
      if (sourceType == widget.sourceType) {
        streamClient = null;
      }
    } else if (widget.sourceType == .emby) {
      config.embyBaseUrl = null;
      config.embyUsername = null;
      config.embyPassword = null;
      if (sourceType == widget.sourceType) {
        streamClient = null;
      }
    } else if (widget.sourceType == .feiniu) {
      config.feiniuBaseUrl = null;
      config.feiniuUsername = null;
      config.feiniuPassword = null;
      config.feiniuToken = null;
      await FeiniuClient.clearSavedNasLogin(baseUrlTmp.text);
      if (sourceType == widget.sourceType) {
        streamClient = null;
      }
    }
    if (mounted) {
      Navigator.pop(context);
    }

    await config.save();
    if (widget.sourceType == sourceType) {
      await Loader.sync();
    } else {
      Directory dir = Directory(
        '${appSupportDir.path}/${widget.sourceType.name}',
      );
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }

  void onSave({bool nasLogin = false}) async {
    if (_connecting) return;
    final l10n = AppLocalizations.of(context);
    if (widget.sourceType == .feiniu) setState(() => _connecting = true);
    try {
      if (widget.sourceType == .webdav) {
        final tmp = webdavClient;
        webdavClient = WebDavClient(
          baseUrl: baseUrlTmp.text,
          username: usernameTmp.text,
          password: passwordTmp.text,
        );
        if (!await webdavClient!.ping()) {
          showCenterMessage('Can not connect to WebDAV');
          webdavClient = tmp;
          return;
        }
      } else if (widget.sourceType == .navidrome) {
        final tmp = streamClient;
        final navidromeClient = NavidromeClient(
          baseUrl: baseUrlTmp.text,
          username: usernameTmp.text,
          password: passwordTmp.text,
        );
        if (!await navidromeClient.ping()) {
          showCenterMessage('Can not connect to Navidrome');
          streamClient = tmp;
          return;
        }
        if (widget.sourceType == sourceType) {
          streamClient = navidromeClient;
        }
        config.navidromeBaseUrl = baseUrlTmp.text;
        config.navidromeUsername = usernameTmp.text;
        config.navidromePassword = passwordTmp.text;
      } else if (widget.sourceType == .emby) {
        final tmp = streamClient;
        final embyClient = EmbyClient(
          baseUrl: baseUrlTmp.text,
          username: usernameTmp.text,
          password: passwordTmp.text,
        );

        if (!await embyClient.ping()) {
          showCenterMessage('Can not connect to Emby');
          streamClient = tmp;
          return;
        }
        if (widget.sourceType == sourceType) {
          streamClient = embyClient;
        }
        config.embyBaseUrl = baseUrlTmp.text;
        config.embyUsername = usernameTmp.text;
        config.embyPassword = passwordTmp.text;
      } else if (widget.sourceType == .feiniu) {
        if (nasLogin &&
            (usernameTmp.text.trim().isEmpty || passwordTmp.text.isEmpty)) {
          if (mounted) {
            showCenterMessage(l10n.feiniuNasLoginFailed);
          }
          return;
        }
        var chosenBaseUrl = baseUrlTmp.text.trim();
        if (nasLogin) {
          final fnId = FeiniuClient.extractFnId(chosenBaseUrl);
          if (fnId != null && mounted) {
            // 查询 FN Connect 连接候选（局域网/公网/DDNS/中继），让用户
            // 自行选择连接方式（与官方客户端的连接信息一致）。
            List<FnConnectCandidate> candidates;
            try {
              candidates = await FnNativeSystemLogin.discoverCandidates(
                fnId: fnId,
              );
            } catch (_) {
              candidates = const <FnConnectCandidate>[];
            }
            if (!mounted) return;
            if (candidates.isNotEmpty) {
              final choice = await showConnectChooserDialog(
                context,
                candidates,
              );
              if (!mounted || choice == null) return;
              if (choice.auto) {
                // 自动：直连优先，逐个探测可达性，全失败回退官方中继。
                String? reachable;
                for (final candidate in candidates) {
                  if (await FeiniuClient.probeCandidate(candidate)) {
                    reachable = candidate.baseUrl;
                    break;
                  }
                }
                if (!mounted) return;
                chosenBaseUrl = reachable ?? 'https://$fnId.fnos.net';
              } else {
                chosenBaseUrl = choice.candidate!.baseUrl;
              }
            }
          }
        }
        final feiniuClient = FeiniuClient(
          baseUrl: chosenBaseUrl,
          username: usernameTmp.text,
          password: passwordTmp.text,
          token:
              chosenBaseUrl == config.feiniuBaseUrl &&
                  usernameTmp.text == config.feiniuUsername &&
                  passwordTmp.text == config.feiniuPassword
              ? config.feiniuToken
              : null,
        );
        // 已能复用有效 token 时跳过系统登录（过期后由免密续登自动接管）。
        if (nasLogin &&
            feiniuClient.token == null &&
            !await feiniuClient.loginWithNasAccount(
              account: usernameTmp.text.trim(),
              password: passwordTmp.text,
            )) {
          if (mounted) showCenterMessage(l10n.feiniuNasLoginFailed);
          return;
        }
        if (!mounted) return;
        if (!await feiniuClient.ping()) {
          showCenterMessage(
            nasLogin ? l10n.feiniuNasLoginFailed : l10n.feiniuConnectionFailed,
          );
          return;
        }
        if (!mounted) return;
        if (widget.sourceType == sourceType) {
          streamClient = feiniuClient;
        }
        config.feiniuBaseUrl = feiniuClient.baseUrl;
        config.feiniuUsername = feiniuClient.username;
        config.feiniuPassword = feiniuClient.password;
        config.feiniuToken =
            nasLogin || config.feiniuToken == feiniuClient.token
            ? feiniuClient.token
            : null;
      }
    } catch (e) {
      if (context.mounted) {
        showCenterMessage(
          widget.sourceType == .feiniu
              ? (nasLogin
                    ? l10n.feiniuNasLoginFailed
                    : l10n.feiniuConnectionFailed)
              : e.toString(),
          duration: 5000,
        );
      }
      logger.output(
        widget.sourceType == .feiniu
            ? '[FeiniuClient] Connection failed: ${e.runtimeType}'
            : e.toString(),
      );
      return;
    } finally {
      if (mounted && _connecting) setState(() => _connecting = false);
    }

    if (!firstLaunch && mounted) {
      Navigator.pop(context);
    }
    showCenterMessage(l10n.savedSuccessfully);
    await config.save();

    if (!firstLaunch &&
        widget.sourceType != .webdav &&
        widget.sourceType == sourceType) {
      if (sourceType == .feiniu) {
        await Loader.reload();
      } else {
        await Loader.sync();
      }
    }
  }
}

/// 连接方式选择结果：auto = 直连优先自动挑选；否则使用指定候选。
class ConnectChoice {
  final bool auto;
  final FnConnectCandidate? candidate;

  const ConnectChoice.auto() : auto = true, candidate = null;

  const ConnectChoice.pick(FnConnectCandidate this.candidate) : auto = false;
}

/// 选择 NAS 连接方式（与官方客户端的连接信息一致）：
/// 自动（直连优先，失败回中继）或手动指定局域网/公网/DDNS/中继地址。
Future<ConnectChoice?> showConnectChooserDialog(
  BuildContext context,
  List<FnConnectCandidate> candidates,
) {
  return showDialog<ConnectChoice>(
    context: context,
    builder: (context) => _ConnectChooserDialog(candidates: candidates),
  );
}

class _ConnectChooserDialog extends StatefulWidget {
  final List<FnConnectCandidate> candidates;

  const _ConnectChooserDialog({required this.candidates});

  @override
  State<_ConnectChooserDialog> createState() => _ConnectChooserDialogState();
}

class _ConnectChooserDialogState extends State<_ConnectChooserDialog> {
  int _selected = -1; // -1 = 自动

  @override
  Widget build(BuildContext context) {
    final options = <Widget>[
      RadioListTile<int>(
        value: -1,
        groupValue: _selected,
        onChanged: (value) => setState(() => _selected = value ?? -1),
        title: const Text('自动选择'),
        subtitle: const Text('直连优先，失败回退官方中继'),
      ),
      for (var i = 0; i < widget.candidates.length; i++)
        RadioListTile<int>(
          value: i,
          groupValue: _selected,
          onChanged: (value) => setState(() => _selected = value ?? -1),
          title: Text(widget.candidates[i].label),
          subtitle: Text(
            widget.candidates[i].baseUrl.replaceAll(RegExp(r'^https?://'), ''),
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];

    return AlertDialog(
      title: const Text('选择连接方式'),
      content: SizedBox(
        width: 420,
        child: ListView(shrinkWrap: true, children: options),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            _selected < 0
                ? const ConnectChoice.auto()
                : ConnectChoice.pick(widget.candidates[_selected]),
          ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
