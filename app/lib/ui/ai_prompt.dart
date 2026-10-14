// 复制交给 AI 助手的安装提示词（docs/rewrite-plan.md 5.13）：只带服务器地址，或者再带上邮箱和新生成的配对码。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../core/ai_prompt.dart';
import '../core/models.dart';
import 'app_scope.dart';
import 'glass.dart';
import 'glass_controls.dart';
import 'glass_overlays.dart';
import 'pairing_code.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> showAiPrompt(BuildContext context, AppController c) => showAppDialog<void>(
  context: context,
  useRootNavigator: false,
  builder: (_) => _AiPromptDialog(c: c),
);

class _AiPromptDialog extends StatefulWidget {
  const _AiPromptDialog({required this.c});
  final AppController c;
  @override
  State<_AiPromptDialog> createState() => _AiPromptDialogState();
}

class _AiPromptDialogState extends State<_AiPromptDialog> {
  bool _withCode = false;
  int _minutes = 10;
  PairingCode? _code;
  Timer? _tick;
  final _scroll = ScrollController();

  AppController get c => widget.c;

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  bool get _hasValidCode => _code != null && _code!.expiresAt.isAfter(DateTime.now());

  /// 选择“含邮箱和配对码”后先选有效期，点“生成”才生成配对码。
  Future<void> _generate() async {
    PairingCode? fresh;
    final ok = await runBusy(
      context,
      () async => fresh = await c.guard(() => c.vault.createPairingCode(minutes: _minutes)),
    );
    if (!ok || fresh == null || !mounted) return;
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    setState(() => _code = fresh);
  }

  String get _prompt {
    final cfg = c.vault.config!;
    return _withCode
        ? aiInstallPrompt(cfg.server, email: cfg.email, code: _code!.formatted)
        : aiInstallPrompt(cfg.server);
  }

  void _copy() {
    if (!AppScope.isSimulated(context)) Clipboard.setData(ClipboardData(text: _prompt));
    toast(context, '已复制');
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glass = usesGlass(context);
    // 选了“含邮箱和配对码”但还没有有效的配对码时，先选有效期再生成，不显示提示词。
    final needsCode = _withCode && !_hasValidCode;
    // 提示词框约显示 5 行，超出部分在框内滚动。
    final lineHeight = MediaQuery.textScalerOf(context).scale(14) * 1.5;
    return AppAlertDialog(
      title: const Text('让 AI 助手安装'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSegmented<bool>(
            options: const [(value: false, label: '仅服务器'), (value: true, label: '含邮箱和配对码')],
            value: _withCode,
            onChanged: (v) => setState(() => _withCode = v),
          ),
          const SizedBox(height: Space.md),
          if (needsCode) ...[
            if (_code != null) ...[
              Text('配对码已过期', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: Space.sm),
            ],
            PairingExpiryRow(minutes: _minutes, onChanged: (m) => setState(() => _minutes = m)),
          ] else
            Container(
              constraints: BoxConstraints(maxHeight: lineHeight * 5 + Space.md * 2),
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(glass ? 18 : 12),
                border: Border.all(color: glass ? p.mute : p.ink, width: glass ? 1 : 1.4),
              ),
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(Space.md),
                  child: SelectableText(_prompt, style: TextStyle(color: p.ink, fontSize: 14, height: 1.5)),
                ),
              ),
            ),
          if (_withCode && !needsCode) ...[
            const SizedBox(height: Space.sm),
            Text('配对码 ${_code!.formatted} · ${formatLeft(_code!.expiresAt)} 后过期', style: TextStyle(color: p.mute)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        if (needsCode)
          FilledButton(onPressed: _generate, child: Text(_code == null ? '生成' : '重新生成'))
        else
          FilledButton(onPressed: _copy, child: const Text('复制')),
      ],
    );
  }
}
