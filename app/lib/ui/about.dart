// “关于”页：版本信息，以及 App 里用到的开源项目和它们的版权说明。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/updater.dart';
import 'theme.dart';
import 'widgets.dart';

class _Project {
  _Project(this.name, this.entries);
  final String name;
  final List<LicenseEntry> entries;
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});
  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<List<_Project>> _projects = _load();

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
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: FutureBuilder<List<_Project>>(
        future: _projects,
        builder: (context, snap) {
          final projects = snap.data;
          return ListView(padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xxl), children: [
            const SizedBox(height: Space.lg),
            Row(children: [
              const BrandMark(),
              const SizedBox(width: Space.md),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('和弦 Harmonia', style: Theme.of(context).textTheme.titleLarge),
                Text('版本 $appVersion', style: TextStyle(color: p.mute)),
              ]),
            ]),
            const SizedBox(height: Space.lg),
            Text(tidy('Harmonia 是开源软件，以 MIT 许可证发布。\n© 2026 Harmonia Contributors'),
                style: TextStyle(color: p.mute, height: 1.5)),
            const SizedBox(height: Space.xs),
            SelectableText('github.com/harmonia-vault/harmonia', style: TextStyle(color: p.mute, height: 1.5)),
            SectionTitle(projects == null ? '开源项目' : '开源项目（${projects.length} 个）'),
            Text(tidy('Harmonia 用到了下面这些开源项目。\n点开可以查看各自的版权说明和许可证全文。'),
                style: TextStyle(color: p.mute, height: 1.5)),
            const SizedBox(height: Space.md),
            if (snap.hasError)
              const Banner2('没能读取开源项目列表，请退出这一页后再试。', warn: true)
            else if (projects == null)
              const Padding(padding: EdgeInsets.all(Space.xl), child: Center(child: CircularProgressIndicator()))
            else
              Card(
                child: Column(children: [
                  for (final (i, project) in projects.indexed) ...[
                    if (i > 0) const Divider(),
                    ListTile(
                      title: Text(project.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => _LicensePage(project: project))),
                    ),
                  ],
                ]),
              ),
          ]);
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
    return Scaffold(
      appBar: AppBar(title: Text(project.name)),
      body: ListView(padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xxl), children: [
        for (final (i, entry) in project.entries.indexed) ...[
          if (i > 0) const Padding(padding: EdgeInsets.symmetric(vertical: Space.lg), child: Divider()),
          for (final paragraph in entry.paragraphs)
            Padding(
              padding: EdgeInsets.only(
                  left: paragraph.indent > 0 ? Space.lg * paragraph.indent : 0, bottom: Space.md),
              child: Text(paragraph.text,
                  style: style,
                  textAlign: paragraph.indent == LicenseParagraph.centeredIndent ? TextAlign.center : TextAlign.start),
            ),
        ],
      ]),
    );
  }
}
