// “关于”页：版本信息，以及 App 里用到的开源项目和它们的版权说明。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/api.dart' show appVersion;
import 'app_icon.dart';
import 'theme.dart';
import 'glass.dart';
import 'widgets.dart';

class _Project {
  _Project(this.name, this.entries);
  final String name;
  final List<LicenseEntry> entries;
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.c});
  final AppController c;
  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<List<_Project>> _projects = _load();
  int _versionTaps = 0;
  DateTime? _lastVersionTap;

  /// 连点版本号 5 次打开开发者选项；两次点击间隔超过 2 秒重新计数。
  Future<void> _tapVersion() async {
    final c = widget.c;
    if (c.prefs.developerOptions) return toast(context, '开发者选项已经打开，在设置页最底部。');
    final now = DateTime.now();
    if (_lastVersionTap == null || now.difference(_lastVersionTap!) > const Duration(seconds: 2)) _versionTaps = 0;
    _lastVersionTap = now;
    _versionTaps++;
    if (_versionTaps < 5) {
      if (_versionTaps >= 3) toast(context, '再点 ${5 - _versionTaps} 次打开开发者选项');
      return;
    }
    _versionTaps = 0;
    try {
      await c.setDeveloperOptions(true);
      if (mounted) toast(context, '已打开开发者选项，在设置页最底部。');
    } catch (_) {
      if (mounted) toast(context, '开发者选项未能打开，请重试。');
    }
  }

  /// 把登记的许可证按项目名归并，按名称排序。
  static Future<List<_Project>> _load() async {
    final byName = <String, List<LicenseEntry>>{};
    await for (final entry in LicenseRegistry.licenses) {
      // 个别包的许可证文件格式不规范，会多出一个空的项目名，这里忽略。
      for (final name in entry.packages.where((n) => n.trim().isNotEmpty)) {
        (byName[name] ??= []).add(entry);
      }
    }
    final names = byName.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [for (final name in names) _Project(name, byName[name]!)];
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AppPage(
      appBar: AppBarSurface(title: const Text('关于')),
      body: (context) => FutureBuilder<List<_Project>>(
        future: _projects,
        builder: (context, snap) {
          final projects = snap.data;
          return ListView(
            padding: pagePadding(context, const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xxl)),
            children: [
              const SizedBox(height: Space.lg),
              Row(
                children: [
                  const AppIcon(),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('和弦 Harmonia', style: Theme.of(context).textTheme.titleLarge),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _tapVersion,
                          child: Text('版本 $appVersion', style: TextStyle(color: p.mute)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.lg),
              Text(
                tidy('Harmonia 是开源软件，以 MIT 许可证发布。\n© 2026 Harmonia Contributors'),
                style: TextStyle(color: p.mute, height: 1.5),
              ),
              const SizedBox(height: Space.xs),
              SelectableText('github.com/harmonia-vault/harmonia', style: TextStyle(color: p.mute, height: 1.5)),
              SectionTitle(projects == null ? '开源项目' : '开源项目（${projects.length} 个）'),
              Text(tidy('Harmonia 用到了下面这些开源项目。\n点开可以查看各自的版权说明和许可证全文。'), style: TextStyle(color: p.mute, height: 1.5)),
              const SizedBox(height: Space.md),
              if (snap.hasError)
                const Banner2('没能读取开源项目列表，请退出这一页后再试。', warn: true)
              else if (projects == null)
                const Padding(
                  padding: EdgeInsets.all(Space.xl),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Card(
                  child: Column(
                    children: [
                      for (final (i, project) in projects.indexed) ...[
                        if (i > 0) const Divider(),
                        ListTile(
                          title: Text(project.name),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => _LicensePage(project: project)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 一个项目的版权说明和许可证全文（原文，不翻译）。
class _LicensePage extends StatelessWidget {
  const _LicensePage({required this.project});
  final _Project project;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 13, height: 1.5, color: context.palette.ink);
    return AppPage(
      appBar: AppBarSurface(title: Text(project.name)),
      body: (context) => ListView(
        padding: pagePadding(context, const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xxl)),
        children: [
          for (final (i, entry) in project.entries.indexed) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Space.lg),
                child: Divider(),
              ),
            for (final paragraph in entry.paragraphs)
              Padding(
                padding: EdgeInsets.only(
                  left: paragraph.indent > 0 ? Space.lg * paragraph.indent : 0,
                  bottom: Space.md,
                ),
                child: Text(
                  paragraph.text,
                  style: style,
                  textAlign: paragraph.indent == LicenseParagraph.centeredIndent ? TextAlign.center : TextAlign.start,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
