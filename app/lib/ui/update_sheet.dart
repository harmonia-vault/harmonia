// 发现新版本时的底部面板：版本、更新内容、接下来怎么做，以及一到两个操作。Android 与 iOS 共用。
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'theme.dart';
import 'glass.dart';
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
}) {
  final contentKey = GlobalKey();
  return showModalBottomSheet<UpdateChoice>(
    context: context,
    isScrollControlled: true,
    // 内容多的时候面板会很高，留出状态栏的位置。
    useSafeArea: true,
    showDragHandle: !usesGlass(context),
    backgroundColor: usesGlass(context) ? Colors.transparent : context.palette.paper,
    barrierColor: usesGlass(context) ? Colors.black54 : null,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context) ? AnimationStyle.noAnimation : null,
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
      return GlassMaterializeTransition(
        animation: ModalRoute.of(c)!.animation!,
        // 面板已由系统路由滑入，不再叠加缩放；材质与内容同步渐显。
        scaleFrom: 1,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.paddingOf(c).bottom + 12),
          child: GlassCard(
            useOwnLayer: true,
            quality: glassQuality(c),
            settings: glassSettings(c, readable: true),
            shape: const LiquidRoundedSuperellipse(borderRadius: 36),
            padding: EdgeInsets.zero,
            child: RepaintBoundary(
              key: contentKey,
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
        ),
      );
    },
  );
}

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
    final glass = usesGlass(context);
    final notesBody = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, n) in notes.indexed) ...[if (i > 0) SizedBox(height: glass ? 14 : Space.md), _NoteLine(n)],
      ],
    );
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '发现新版本',
          style: TextStyle(color: p.ink, fontSize: glass ? 24 : 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text('Harmonia $version · 当前 $current', style: TextStyle(color: glass ? p.ink : p.mute, fontSize: 13)),
      ],
    );
    final header = Row(
      children: [
        if (!glass) ...[const BrandMark(), const SizedBox(width: Space.md)],
        Expanded(child: heading),
        if (glass)
          IconButton.filledTonal(
            tooltip: '以后再说',
            style: IconButton.styleFrom(backgroundColor: p.ink.withValues(alpha: 0.06), foregroundColor: p.ink),
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
      ],
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (notes.isNotEmpty) ...[
          if (!glass) const SectionTitle('更新内容'),
          glass
              ? notesBody
              : Container(
                  decoration: BoxDecoration(
                    color: p.card,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: p.line, width: 1.2),
                  ),
                  padding: const EdgeInsets.all(Space.lg),
                  child: notesBody,
                ),
          const SizedBox(height: 20),
        ],
        Text(tidy(hint), style: TextStyle(color: glass ? p.ink : p.mute, fontSize: 13, height: 1.5)),
      ],
    );
    final actions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Space.lg),
        FilledButton(onPressed: () => Navigator.pop(context, UpdateChoice.primary), child: Text(primary)),
        if (secondary != null) ...[
          const SizedBox(height: Space.sm),
          if (glass)
            TextButton(onPressed: () => Navigator.pop(context, UpdateChoice.secondary), child: Text(secondary!))
          else
            OutlinedButton(onPressed: () => Navigator.pop(context, UpdateChoice.secondary), child: Text(secondary!)),
        ],
        if (!glass) TextButton(onPressed: () => Navigator.pop(context), child: const Text('以后再说')),
      ],
    );
    return SafeArea(
      top: false,
      bottom: !glass,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * (glass ? 0.72 : 0.8)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, glass ? 4 : 0, 24, glass ? 24 : Space.lg),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 常规屏固定操作区；短屏和大字号让整个面板滚动，不能把正文挤成零高。
              final scrollWhole = constraints.maxHeight < 440 || MediaQuery.textScalerOf(context).scale(14) > 20;
              return scrollWhole
                  ? SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [header, const SizedBox(height: 24), body, actions],
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        header,
                        const SizedBox(height: 24),
                        Flexible(child: SingleChildScrollView(child: body)),
                        actions,
                      ],
                    );
            },
          ),
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
