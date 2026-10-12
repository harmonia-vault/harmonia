// 只操作页面调试的内存会话，不调用系统锁屏或真实身份验证。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'glass.dart';
import 'lock.dart';

class LockDebugPage extends StatelessWidget {
  const LockDebugPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) => AppPage(
    appBar: const AppBarSurface(title: Text('锁屏与后台锁定')),
    body: (context) => Padding(
      padding: pagePadding(context, const EdgeInsets.all(16)),
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              TextButton(onPressed: () => c.onLifecycle(foreground: false), child: const Text('模拟切后台')),
              TextButton(onPressed: c.onScreenLocked, child: const Text('模拟锁屏')),
              TextButton(onPressed: () => c.onLifecycle(foreground: true), child: const Text('模拟回到前台')),
            ],
          ),
          Text('${c.foreground ? '前台' : '后台或锁屏'} · ${c.stage == Stage.locked ? 'App 已锁定' : 'App 已解锁'}'),
          const Text('锁屏立即锁定；切后台满 5 分钟锁定。示例 PIN：123456。'),
          Expanded(
            child: c.stage == Stage.locked ? LockPage(c: c) : const Center(child: Text('当前为模拟已解锁会话')),
          ),
        ],
      ),
    ),
  );
}
