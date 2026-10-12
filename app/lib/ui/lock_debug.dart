// 只操作页面调试的内存会话，不调用系统锁定或真实身份验证。
import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'glass.dart';
import 'lock.dart';

class LockDebugPage extends StatelessWidget {
  const LockDebugPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) => AppPage(
    appBar: const AppBarSurface(title: Text('后台计时与 App 锁定')),
    body: (context) => SingleChildScrollView(
      padding: pagePadding(context, const EdgeInsets.all(16)),
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              TextButton(onPressed: () => c.onLifecycle(foreground: false), child: const Text('模拟切后台')),
              TextButton(onPressed: c.lockNow, child: const Text('模拟手动锁定')),
              TextButton(onPressed: () => c.onLifecycle(foreground: true), child: const Text('模拟回到前台')),
            ],
          ),
          Text('${c.foreground ? '前台' : '后台'} · ${c.stage == Stage.locked ? 'App 已锁定' : 'App 已解锁'}'),
          const Text('切后台满 5 分钟锁定；短暂离开保留会话。示例 PIN：123456。'),
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: c.stage == Stage.locked ? LockPage(c: c) : const Center(child: Text('当前为模拟已解锁会话')),
          ),
        ],
      ),
    ),
  );
}
