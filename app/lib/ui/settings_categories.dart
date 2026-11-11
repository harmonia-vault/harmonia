import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'app_scope.dart';
import 'glass.dart';
import 'settings.dart';
import 'workspace_scope.dart';

class SettingsCategories extends StatelessWidget {
  const SettingsCategories({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) {
    final categories = [
      (name: '账号', icon: Icons.person_outline),
      (name: '外观', icon: Icons.brightness_6_outlined),
      (name: '通知', icon: Icons.notifications_outlined),
      (name: '安全', icon: Icons.shield_outlined),
      (name: '关于', icon: Icons.info_outline),
      if (c.prefs.developerOptions && !AppScope.isSimulated(context)) (name: '开发者选项', icon: Icons.developer_mode),
    ];
    return AppTabPage(
      title: '设置',
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Card(
          child: Column(
            children: [
              for (final (i, item) in categories.indexed) ...[
                if (i > 0) const Divider(),
                ListTile(
                  leading: Icon(item.icon),
                  title: Text(item.name),
                  selected: WorkspaceScope.maybeOf(context)?.selected[3]?.id == 'settings:${item.name}',
                  onTap: () => openWorkspaceEntry(
                    context,
                    WorkspaceEntry(
                      tab: 3,
                      id: 'settings:${item.name}',
                      title: item.name,
                      page: (_) => SettingsTab(c: c, section: item.name),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
