// 发现新版本时的底部面板：版本、更新内容、接下来怎么做，以及一到两个操作。Android 与 iOS 共用。
import 'package:flutter/material.dart';

import 'theme.dart';
import 'glass.dart';
import 'glass_motion.dart';
import 'widgets.dart';

/// 用户在面板上的选择；直接关闭或点“以后再说”时为 null。
enum UpdateChoice { primary, secondary }

/// 更新说明里的一段：条目，或普通的一段话。
typedef _Note = ({bool bullet, String text});

/// 把更新说明拆成条目和段落。说明来自发布标签：第一行是“Harmonia 版本号”，与标题重复，去掉。
List<_Note> _parseNotes(String notes) {
  final lines = notes.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isNotEmpty && lines.first.startsWith('Harmonia ')) lines.removeAt(0);
  return [
    for (final l in lines) l.startsWith('- ') ? (bullet: true, text: l.substring(2).trim()) : (bullet: false, text: l),
  ];
}

Future<UpdateChoice?> showUpdateSheet(
  BuildContext context, {
  required String version,
  required String current,
  required String notes,
  required String hint,
  required String primary,
  String? secondary,
}) => showModalBottomSheet<UpdateChoice>(
  context: context,
  isScrollControlled: true,
  // 内容多的时候面板会很高，留出状态栏的位置。
  useSafeArea: true,
  showDragHandle: !usesGlass(context),
  backgroundColor: usesGlass(context) ? Colors.transparent : context.palette.paper,
  barrierColor: usesGlass(context) ? Colors.black.withValues(alpha: 0.24) : null,
  sheetAnimationStyle: glassSheetAnimationStyle(context),
  builder: (c) {
    final content = _UpdateSheet(
      version: version,
      current: current,
      notes: _parseNotes(notes),
      hint: hint,
      primary: primary,
      secondary: secondary,
    );
    if (!usesGlass(c)) return content;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.paddingOf(c).bottom + 12),
      child: GlassPopupTransition(
        animation: ModalRoute.of(c)!.animation!,
        beginScale: 0.94,
        verticalOffset: 0,
        alignment: Alignment.bottomCenter,
        child: AppSurface(
          color: c.palette.paper,
          radius: 36,
          tintAlpha: 0.94,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.palette.mute.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Flexible(child: content),
            ],
          ),
        ),
      ),
    );
  },
);

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({
    required this.version,
    required this.current,
    required this.notes,
    required this.hint,
    required this.primary,
    this.secondary,
  });

  final String version, current, hint, primary;
  final String? secondary;
  final List<_Note> notes;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (usesGlass(context)) return _glassContent(context);
    return SafeArea(
      top: false,
      bottom: !usesGlass(context),
      child: ConstrainedBox(
        // 更新内容再长也给标题和按钮留出位置，中间那一块自己滚动。
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const BrandMark(),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '发现新版本',
                          style: TextStyle(color: p.ink, fontSize: 20, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text('当前版本 $current', style: TextStyle(color: p.mute, fontSize: 13)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 6),
                    decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      version,
                      style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              if (notes.isNotEmpty) ...[
                const SectionTitle('更新内容'),
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                      color: p.card,
                      borderRadius: BorderRadius.circular(18),
                      border: usesGlass(context) ? null : Border.all(color: p.line, width: 1.2),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(Space.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (i, n) in notes.indexed) ...[
                            if (i > 0) const SizedBox(height: Space.md),
                            _NoteLine(n),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: Space.lg),
              Text(tidy(hint), style: TextStyle(color: p.mute, fontSize: 13, height: 1.45)),
              const SizedBox(height: Space.lg),
              FilledButton(onPressed: () => Navigator.pop(context, UpdateChoice.primary), child: Text(primary)),
              if (secondary != null) ...[
                const SizedBox(height: Space.sm),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context, UpdateChoice.secondary),
                  child: Text(secondary!),
                ),
              ],
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('以后再说')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _glassContent(BuildContext context) {
    final p = context.palette;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.72),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '发现新版本',
                        style: TextStyle(color: p.ink, fontSize: 24, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text('Harmonia $version · 当前 $current', style: TextStyle(color: p.mute, fontSize: 13)),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: '以后再说',
                  style: IconButton.styleFrom(backgroundColor: p.ink.withValues(alpha: 0.06), foregroundColor: p.mute),
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, n) in notes.indexed) ...[if (i > 0) const SizedBox(height: 14), _NoteLine(n)],
                    if (notes.isNotEmpty) const SizedBox(height: 20),
                    Text(tidy(hint), style: TextStyle(color: p.mute, fontSize: 13, height: 1.5)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: () => Navigator.pop(context, UpdateChoice.primary), child: Text(primary)),
            if (secondary != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButton(
                  onPressed: () => Navigator.pop(context, UpdateChoice.secondary),
                  child: Text(secondary!),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoteLine extends StatelessWidget {
  const _NoteLine(this.note);
  final _Note note;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Text(tidy(note.text), style: TextStyle(color: p.ink, fontSize: 15, height: 1.45));
    if (!note.bullet) return text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, right: Space.md),
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
          ),
        ),
        Expanded(child: text),
      ],
    );
  }
}
