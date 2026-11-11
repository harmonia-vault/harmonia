import 'package:flutter/cupertino.dart';

import 'glass.dart';
import 'widgets.dart';

class WorkspaceEmpty extends StatelessWidget {
  const WorkspaceEmpty({super.key, required this.tab});
  final int tab;

  @override
  Widget build(BuildContext context) {
    const states = [
      (icon: CupertinoIcons.archivebox, title: '未选择变量库', body: '在左侧选择或新建变量库，在这里查看和编辑变量。'),
      (icon: CupertinoIcons.square_stack_3d_up, title: '未选择环境', body: '在左侧选择或新建环境，在这里查看变量与设备授权。'),
      (icon: CupertinoIcons.device_laptop, title: '未选择设备', body: '在左侧选择或添加设备，在这里管理环境访问权限。'),
      (icon: CupertinoIcons.gear_alt, title: '未选择设置分组', body: '在左侧选择一个分组，调整账号、外观和安全设置。'),
    ];
    final state = states[tab];
    return AppPage(
      body: (context) => Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: EmptyState(icon: state.icon, title: state.title, body: state.body),
          ),
        ),
      ),
    );
  }
}
