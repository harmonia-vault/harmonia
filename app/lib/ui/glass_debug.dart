// 纯绘制对照，不读取账号、存储或网络；所有设置随调试会话丢弃。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../app/controller.dart';
import 'glass.dart';
import 'glass_transparency.dart';
import 'theme.dart';

class GlassDebugOptions extends StatelessWidget {
  const GlassDebugOptions({super.key, required this.quality, required this.onChanged});
  final GlassQuality? quality;
  final ValueChanged<GlassQuality?> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        title: const Text('当前设备的玻璃渲染能力'),
        subtitle: Text(
          '${GlassResources.supportsRefraction ? '支持 Shader Filter，可使用完整折射' : '不支持 Shader Filter，使用轻量效果'}\n'
          '底部安全区：${MediaQuery.viewPaddingOf(context).bottom.toStringAsFixed(1)} 逻辑像素\n'
          '此能力不能区分 Vulkan 与 OpenGL ES；实际后端需查看 Flutter 启动日志。',
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: DropdownButtonFormField<String>(
          initialValue: quality?.name ?? 'auto',
          decoration: const InputDecoration(labelText: '玻璃渲染对比（仅本次调试）'),
          items: const [
            DropdownMenuItem(value: 'auto', child: Text('按设备能力选择')),
            DropdownMenuItem(value: 'premium', child: Text('请求完整折射（premium）')),
            DropdownMenuItem(value: 'standard', child: Text('轻量效果（standard）')),
          ],
          onChanged: (value) => onChanged(switch (value) {
            'premium' => GlassQuality.premium,
            'standard' => GlassQuality.standard,
            _ => null,
          }),
        ),
      ),
    ],
  );
}

class GlassDebugPage extends StatelessWidget {
  const GlassDebugPage({super.key, required this.c});
  final AppController c;

  @override
  Widget build(BuildContext context) => AppPage(
    appBar: const AppBarSurface(title: Text('玻璃透明度与折射对照')),
    body: (context) => Stack(
      children: [
        ListView.builder(
          padding: pagePadding(context, const EdgeInsets.all(16)),
          itemCount: 48,
          itemBuilder: (_, index) => Container(
            height: 72,
            color: [Colors.indigo, Colors.orange, Colors.teal, Colors.pink][index % 4],
            alignment: Alignment.center,
            child: Text('合成背景 ${index + 1} ━━━', style: const TextStyle(color: Colors.white, fontSize: 24)),
          ),
        ),
        Center(
          child: IgnorePointer(
            child: AppSurface(
              radius: 32,
              color: context.palette.card,
              child: const SizedBox(width: 240, height: 120, child: Center(child: Text('上下滑动，观察背景折射'))),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            child: Card(
              margin: const EdgeInsets.all(16),
              child: GlassTransparencyControl(
                value: c.appearance.glassOpacity,
                onChanged: c.setGlassOpacity,
                onPreview: c.previewGlassOpacity,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
