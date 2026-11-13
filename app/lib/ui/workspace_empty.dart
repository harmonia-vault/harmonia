import 'package:flutter/cupertino.dart';

import 'glass.dart';
import 'widgets.dart';

class WorkspaceEmpty extends StatelessWidget {
  const WorkspaceEmpty({super.key, required this.tab});
  final int tab;

  @override
  Widget build(BuildContext context) {
    const states = [
      (icon: CupertinoIcons.archivebox, title: '还没有变量库', body: '在左侧新建变量库后，在这里查看和编辑变量。'),
      (icon: CupertinoIcons.square_stack_3d_up, title: '还没有环境', body: '在左侧新建环境后，在这里查看变量与设备授权。'),
      (icon: CupertinoIcons.device_laptop, title: '还没有设备', body: '在左侧添加设备后，在这里管理环境访问权限。'),
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
