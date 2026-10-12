// 操作反馈的合成场景，与真实页面共用通知与下载进度组件。
import 'package:flutter/material.dart';

import '../app/debug_update.dart';
import 'glass.dart';
import 'theme.dart';
import 'widgets.dart';

class FeedbackDebugPage extends StatelessWidget {
  const FeedbackDebugPage({super.key});

  @override
  Widget build(BuildContext context) => AppPage(
    appBar: const AppBarSurface(title: Text('通知与下载进度')),
    body: (context) => ListView(
      padding: pagePadding(context, const EdgeInsets.all(20)),
      children: [
        const Banner2('这里不会联网或保存文件。可在目录调整玻璃透明度、明暗、大字号、高对比度和减少动态效果，检查通知与弹层动画。'),
        const SectionTitle('气泡通知'),
        OutlinedButton(onPressed: () => toast(context, '已复制'), child: const Text('短通知')),
        OutlinedButton(
          onPressed: () => toast(context, '已复制。为了安全，1 分钟后会自动清空剪贴板。此处是合成通知，没有复制真实内容。'),
          child: const Text('长通知与换行'),
        ),
        OutlinedButton(onPressed: () => toast(context, '模拟操作未完成，请检查网络后重试。'), child: const Text('错误通知')),
        const SectionTitle('下载进度'),
        OutlinedButton(onPressed: () => simulateUpdateDownload(context), child: const Text('模拟下载与校验')),
        OutlinedButton(onPressed: () => simulateUpdateDownload(context, fail: true), child: const Text('模拟下载中断')),
        const SizedBox(height: 24),
        for (var i = 0; i < 8; i++)
          Container(
            height: 72,
            color: i.isEven ? context.palette.sage : context.palette.yellow,
            alignment: Alignment.center,
            child: Text('合成背景 ${i + 1}，可滚动查看通知折射', style: TextStyle(color: Palette.light.ink)),
          ),
      ],
    ),
  );
}
