// 八种几何场景共用同一个模拟会话和导航器，切换姿态不重建页面。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app/controller.dart';
import 'app_scope.dart';
import 'glass.dart';
import 'window_layout.dart';
import 'workspace.dart';
import 'workspace_scope.dart';
import 'vaults.dart';

typedef _Pose = ({String name, WindowLayout layout});

final _poses = <_Pose>[
  (
    name: '内屏横向',
    layout: WindowLayout(width: 951, height: 669, regularWidth: true, insets: (left: 0, top: 0, right: 84, bottom: 0)),
  ),
  (
    name: '内屏竖向',
    layout: WindowLayout(width: 669, height: 951, regularWidth: true, insets: (left: 0, top: 62, right: 0, bottom: 34)),
  ),
  (name: '外屏竖向', layout: WindowLayout(width: 466, height: 678, insets: (left: 0, top: 62, right: 0, bottom: 34))),
  (
    name: '外屏横向',
    layout: WindowLayout(
      width: 678,
      height: 466,
      insets: (left: 0, top: 0, right: 84, bottom: 0),
      occlusions: [layoutRect(630, 210, 48, 46)],
    ),
  ),
  (
    name: '书本式半折叠',
    layout: WindowLayout(
      width: 951,
      height: 669,
      regularWidth: true,
      insets: (left: 0, top: 0, right: 84, bottom: 0),
      fold: layoutRect(470, 0, 18, 669),
    ),
  ),
  (
    name: '桌面式半折叠',
    layout: WindowLayout(
      width: 669,
      height: 951,
      regularWidth: true,
      insets: (left: 0, top: 62, right: 0, bottom: 34),
      fold: layoutRect(0, 470, 669, 18),
    ),
  ),
  (
    name: '左侧分屏',
    layout: WindowLayout(
      width: 476,
      height: 669,
      navigation: NavigationEdge.left,
      insets: (left: 84, top: 62, right: 0, bottom: 34),
    ),
  ),
  (
    name: '右侧分屏',
    layout: WindowLayout(
      width: 476,
      height: 669,
      navigation: NavigationEdge.right,
      insets: (left: 0, top: 62, right: 84, bottom: 34),
    ),
  ),
];

class FoldPreviewPage extends StatefulWidget {
  const FoldPreviewPage({super.key, required this.c});
  final AppController c;
  @override
  State<FoldPreviewPage> createState() => _FoldPreviewPageState();
}

class _FoldPreviewPageState extends State<FoldPreviewPage> {
  final _navigator = GlobalKey<NavigatorState>();
  int _pose = 0;

  @override
  Widget build(BuildContext context) {
    final layout = _poses[_pose].layout;
    final vault = widget.c.vault.vaults.firstOrNull;
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: DropdownButtonFormField<int>(
              initialValue: _pose,
              decoration: const InputDecoration(labelText: '窗口姿态'),
              items: [for (var i = 0; i < _poses.length; i++) DropdownMenuItem(value: i, child: Text(_poses[i].name))],
              onChanged: (value) => setState(() => _pose = value!),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: FittedBox(
                child: SizedBox(
                  width: layout.width,
                  height: layout.height,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: MaterialApp(
                      navigatorKey: _navigator,
                      debugShowCheckedModeBanner: false,
                      theme: Theme.of(context),
                      locale: const Locale('zh', 'CN'),
                      supportedLocales: const [Locale('zh', 'CN')],
                      localizationsDelegates: const [
                        GlobalMaterialLocalizations.delegate,
                        GlobalWidgetsLocalizations.delegate,
                        GlobalCupertinoLocalizations.delegate,
                      ],
                      builder: (context, child) {
                        final media = MediaQuery.of(context);
                        final padding = EdgeInsets.fromLTRB(
                          layout.insets.left,
                          layout.insets.top,
                          layout.insets.right,
                          layout.insets.bottom,
                        );
                        final keyboard = media.viewInsets.bottom;
                        final current = WindowLayout(
                          width: layout.width,
                          height: layout.height,
                          insets: layout.insets,
                          keyboard: keyboard,
                          navigation: layout.navigation,
                          regularWidth: layout.regularWidth,
                          fold: layout.fold,
                          occlusions: layout.occlusions,
                        );
                        return AppScope(
                          identity: widget.c.identity,
                          simulated: true,
                          child: MediaQuery(
                            data: media.copyWith(
                              size: Size(layout.width, layout.height),
                              padding: padding,
                              viewPadding: padding,
                              displayFeatures: [],
                            ),
                            child: WindowLayoutScope(
                              layout: current,
                              navigator: _navigator,
                              child: GlassOpacityPreview(
                                preview: widget.c.glassOpacityPreview,
                                child: LiquidGlassWidgets.wrap(
                                  brightnessResolver: Theme.maybeBrightnessOf,
                                  child: child!,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                      home: Workspace(
                        c: widget.c,
                        initialEntry: vault != null
                            ? WorkspaceEntry(
                                tab: 0,
                                id: 'vault:${vault.id}',

                                page: (_) => VaultPage(c: widget.c, vaultId: vault.id),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
