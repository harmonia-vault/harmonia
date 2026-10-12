// 各页面共用的小组件与操作反馈。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/phrases.dart';
import '../core/vault.dart';
import 'theme.dart';
import 'app_scope.dart';
import 'glass_overlays.dart';
import 'glass.dart';
import 'glass_motion.dart';

/// 把异常转成给用户看的一句话。
String errorText(Object e) {
  if (e is ApiException || e is VaultException) return e.toString();
  final s = e.toString();
  if (s.startsWith('Exception: ')) return s.substring(11);
  return '操作没有完成，请稍后重试。';
}

void toast(BuildContext context, String msg) {
  final glass = usesGlass(context);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      glass
          ? GlassSnackBar(
              content: AppSurface(
                color: context.palette.card,
                radius: 24,
                tintAlpha: 0.76,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: Text(tidy(msg), style: TextStyle(color: context.palette.ink, height: 1.45)),
                ),
              ),
            )
          : SnackBar(content: Text(msg)),
      snackBarAnimationStyle: notificationAnimationStyle(context),
    );
}

/// 执行一个异步操作：期间显示进度，失败时提示原因。返回是否成功。
Future<bool> runBusy(
  BuildContext context,
  Future<void> Function() fn, {
  String? done,
  WidgetBuilder? progressBuilder,
}) async {
  final nav = Navigator.of(context);
  // 只移除这个进度弹窗本身：操作期间页面栈可能因阶段切换而被清空。
  final route = AppDialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: progressBuilder?.call(context) ?? const Center(child: CircularProgressIndicator()),
    ),
  );
  nav.push(route);
  Future<void> close() async {
    if (!route.isActive) return;
    if (route.isCurrent) {
      nav.pop();
      await route.completed;
    } else {
      nav.removeRoute(route);
    }
  }

  try {
    await fn();
    await close();
    if (done != null && context.mounted) toast(context, done);
    return true;
  } catch (e) {
    await close();
    if (context.mounted) toast(context, errorText(e));
    return false;
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  String ok = '确认',
  bool danger = false,
}) async {
  final r = await showAppDialog<bool>(
    context: context,
    useRootNavigator: false,
    builder: (c) => AppAlertDialog(
      title: Text(title),
      content: Text(tidy(body)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(c).colorScheme.error,
                  foregroundColor: Theme.of(c).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// 中文分词，由 main() 在启动时从资源里加载；没加载时文字按系统默认方式折行。
PhraseBreaker? phraseBreaker;

/// 界面上成段的中文都经过这里：折行只落在词与词之间，行尾不会只剩一两个字。
String tidy(String text) => phraseBreaker?.glue(text) ?? text;

/// 账号相关页面的统一外框：品牌标题 + 可滚动表单。
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({super.key, required this.title, this.subtitle, required this.children, this.onBack});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 系统返回键与左上角返回按钮一致；没有返回按钮的页面交给系统处理（退到桌面）。
    return PopScope(
      canPop: onBack == null || Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onBack?.call();
      },
      child: _scaffold(context, p),
    );
  }

  Widget _scaffold(BuildContext context, Palette p) {
    return AppPage(
      appBar: onBack == null
          ? null
          : AppBarSurface(
              leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack),
            ),
      body: (context) => SafeArea(
        top: !usesGlass(context) || onBack == null,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                Space.xl,
                Space.xl + (usesGlass(context) && onBack != null ? MediaQuery.paddingOf(context).top : 0),
                Space.xl,
                Space.xxl,
              ),
              children: [
                if (onBack == null) ...[
                  Row(
                    children: [
                      const BrandMark(),
                      const SizedBox(width: Space.md),
                      Text('和弦', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(width: Space.sm),
                      Text('Harmonia', style: TextStyle(color: p.mute)),
                    ],
                  ),
                  const SizedBox(height: Space.xxl),
                ],
                Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                // 副标题里每个换行是一段，段与段之间不留额外间距。
                if (subtitle != null) ...[
                  const SizedBox(height: Space.sm),
                  Text(tidy(subtitle!), style: TextStyle(color: p.mute, height: 1.5)),
                ],
                const SizedBox(height: Space.xl),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 品牌标记：黄底上的声波图形。
class BrandMark extends StatelessWidget {
  const BrandMark({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: p.yellow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.ink, width: 1.4),
      ),
      child: Icon(Icons.graphic_eq_rounded, color: p.ink),
    );
  }
}

/// 提示条：info 为普通说明，warn 为需要注意的事项。
class Banner2 extends StatelessWidget {
  const Banner2(this.text, {super.key, this.warn = false, this.icon});
  final String text;
  final bool warn;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: warn ? p.warnBox : p.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: warn ? p.warnBox : p.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon ?? (warn ? Icons.warning_amber_rounded : Icons.info_outline),
            size: 20,
            color: warn ? p.onWarnBox : p.mute,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(tidy(text), style: TextStyle(color: warn ? p.onWarnBox : p.ink, height: 1.45)),
          ),
        ],
      ),
    );
  }
}

/// 等宽显示的码（恢复码、核对码），可复制。
class CodeBox extends StatelessWidget {
  const CodeBox(this.code, {super.key, this.copyable = true, this.big = false});
  final String code;
  final bool copyable;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.lg),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.ink, width: 1.4),
      ),
      child: Row(
        children: [
          Expanded(
            // 按组换行，不在一组中间断开。
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                for (final g in code.split('-'))
                  Text(
                    g,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: big ? 26 : 20,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
              ],
            ),
          ),
          if (copyable)
            IconButton(
              tooltip: '复制',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () {
                if (!AppScope.isSimulated(context)) Clipboard.setData(ClipboardData(text: code));
                toast(context, '已复制');
              },
            ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.xs, Space.lg, Space.xs, Space.sm),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: context.palette.mute, fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// 空状态。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action});
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.xxl, horizontal: Space.xl),
    child: Column(
      children: [
        Icon(icon, size: 48, color: context.palette.mute),
        const SizedBox(height: Space.md),
        Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        if (body != null) ...[
          const SizedBox(height: Space.sm),
          Text(
            tidy(body!),
            style: TextStyle(color: context.palette.mute, height: 1.5),
            textAlign: TextAlign.center,
          ),
        ],
        if (action != null) ...[const SizedBox(height: Space.lg), action!],
      ],
    ),
  );
}

const roleNames = {'ro': '只读', 'rw': '读写', 'admin': '管理'};

String formatTime(int ms) {
  if (ms == 0) return '—';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

String formatExpiry(int ms) {
  if (ms == 0) return '长期有效';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  if (t.isBefore(DateTime.now())) return '已到期';
  return '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} 到期';
}

String? validatePassword(String? v) {
  if (v == null || v.length < 8) return '密码至少 8 位';
  return null;
}

String? validateEmail(String? v) {
  if (v == null || !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())) return '请输入有效的邮箱地址';
  return null;
}
