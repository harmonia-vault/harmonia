// 新页面、弹窗或分步状态必须同步添加到这里；所有入口使用 DebugSession。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/debug_session.dart';
import '../app/updater.dart';
import '../core/account.dart';
import '../core/crypto.dart';
import 'about.dart';
import 'auth_pages.dart';
import 'devices.dart';
import 'device_review.dart';
import 'environments.dart';
import 'glass.dart';
import 'home.dart';
import 'lock.dart';
import 'pairing.dart';
import 'pin_setup.dart';
import 'recovery_actions.dart';
import 'recovery_pages.dart';
import 'scanner.dart';
import 'settings.dart';
import 'widgets.dart';

class DebugPageEntry {
  const DebugPageEntry(this.name, this.page, {this.stage = Stage.home, this.prepare});
  final String name;
  final Widget Function(DebugSession) page;
  final Stage stage;
  final Future<void> Function(DebugSession)? prepare;
}

Map<String, List<DebugPageEntry>> debugPages() => {
  '首页与管理': [
    DebugPageEntry('首页与底部导航', (s) => s.vault.paired ? HomePage(c: s.c) : SignInPage(c: s.c)),
    DebugPageEntry('设备列表', (s) => s.vault.paired ? DevicesTab(c: s.c) : SignInPage(c: s.c)),
    DebugPageEntry('设置与安全弹窗', (s) => s.vault.paired ? SettingsTab(c: s.c) : SignInPage(c: s.c)),
    DebugPageEntry('关于与开源许可', (_) => const AboutPage()),
    DebugPageEntry('环境详情与菜单', (s) => _environment(s, edit: false)),
    DebugPageEntry('添加变量', (s) => _environment(s, edit: true)),
    DebugPageEntry('编辑变量', (s) {
      if (s.vault.environments.isEmpty) return _environment(s, edit: true);
      final id = s.vault.environments.first.id;
      return VariableEditPage(c: s.c, envId: id, name: s.vault.values(id).keys.firstOrNull);
    }),
    DebugPageEntry(
      '设备详情与权限',
      (s) => s.vault.devices.isEmpty
          ? const Center(child: Text('当前没有示例设备，请切换到正常数据。'))
          : DevicePage(c: s.c, deviceId: s.vault.devices.last.id),
    ),
    DebugPageEntry('扫码添加与核对码弹窗', (s) => AddDevicePage(c: s.c)),
    DebugPageEntry(
      '批准与拒绝设备',
      (s) => s.vault.requests.isEmpty
          ? const Center(child: Text('当前没有待批准请求，请重置示例。'))
          : ReviewPairingPage(c: s.c, request: s.vault.requests.first, scanned: false),
    ),
  ],
  '账号接入': [
    DebugPageEntry('连接服务器', (s) => ConnectPage(c: s.c), stage: Stage.connect),
    DebugPageEntry('扫描服务器', (_) => const ScanServerPage()),
    DebugPageEntry('登录与注册', (s) => SignInPage(c: s.c), stage: Stage.signedOut),
    DebugPageEntry(
      '登录验证码弹窗',
      (s) => SignInPage(c: s.c),
      stage: Stage.signedOut,
      prepare: (s) async {
        s.account.requireCode = true;
      },
    ),
    DebugPageEntry(
      '验证邮箱',
      (s) => VerifyEmailPage(c: s.c),
      stage: Stage.verifyEmail,
      prepare: (s) => s.c.register('demo@example.invalid', 'preview-password'),
    ),
    DebugPageEntry(
      '设置 PIN 与生物识别',
      (s) => SetPinPage(c: s.c),
      stage: Stage.setPin,
      prepare: (s) async {
        s.prepareAccount();
      },
    ),
    DebugPageEntry('未授权手机', (s) => UnpairedPage(c: s.c), stage: Stage.unpaired),
    DebugPageEntry(
      '等待批准',
      (s) => PairingWaitPage(c: s.c),
      stage: Stage.pairing,
      prepare: (s) async {
        s.c.pendingPairing = await s.account.startPairing(
          s.c.session ??
              PasswordSession(
                'https://debug.invalid',
                'demo@example.invalid',
                'debug-token',
                'debug-account',
                true,
                'debug-root',
              ),
          '示例手机',
        );
      },
    ),
  ],
  '恢复与安全': [
    DebugPageEntry('App 锁屏', (s) => LockPage(c: s.c), stage: Stage.locked),
    DebugPageEntry(
      '首次保存恢复码',
      (s) => SetupPage(c: s.c),
      stage: Stage.setup,
      prepare: (s) async {
        s.c.setupCompleted = false;
        s.c.setupDraft = s.account.prepareSetup();
        s.prepareAccount(initialized: false);
      },
    ),
    DebugPageEntry('用恢复码恢复', (s) => RecoverPage(c: s.c, email: 'demo@example.invalid')),
    DebugPageEntry('找回密码', (s) => ForgotPasswordPage(c: s.c, email: 'demo@example.invalid')),
    DebugPageEntry('重置账号', (s) => AccountResetPage(c: s.c, email: 'demo@example.invalid')),
    DebugPageEntry('更换恢复码', (s) => RotationPage(c: s.c)),
    DebugPageEntry('强制更换恢复码', (s) => RotationPage(c: s.c, forced: true), stage: Stage.rotation),
    DebugPageEntry(
      '恢复后检查设备',
      (s) => s.vault.paired ? DeviceReviewView(c: s.c, onDone: s.c.finishRotation) : SignInPage(c: s.c),
      stage: Stage.rotation,
    ),
    DebugPageEntry(
      '恢复完成与模拟 PDF',
      stage: Stage.rotation,
      (s) => RecoveryDoneView(
        c: s.c,
        code: Uint8List(16),
        title: '恢复码已生效',
        subtitle: '示例恢复流程已经完成。',
        onDone: s.c.finishRotation,
      ),
    ),
  ],
  '弹窗与弹层': [
    DebugPageEntry(
      '新建环境弹窗',
      (s) => DebugOverlay(
        show: (c) async {
          final name = await askName(c, title: '新建环境', label: '环境名称');
          if (name != null && c.mounted) {
            await runBusy(c, () => s.c.guard(() => s.vault.createEnvironment(name)), done: '已创建示例环境');
          }
        },
      ),
    ),
    DebugPageEntry(
      '重命名弹窗',
      (s) => DebugOverlay(
        show: (c) async {
          if (s.vault.environments.isEmpty) {
            toast(c, '请先创建示例环境');
            return;
          }
          final env = s.vault.environments.first;
          final name = await askName(c, title: '重命名环境', initial: env.name);
          if (name != null && c.mounted) {
            await runBusy(c, () => s.c.guard(() => s.vault.renameEnvironment(env.id, name)), done: '已重命名');
          }
        },
      ),
    ),
    DebugPageEntry('身份验证弹窗', (_) => DebugOverlay(show: (c) => verifyIdentity(c, '验证模拟身份后继续'))),
    DebugPageEntry(
      '新 PIN 弹窗',
      (s) => DebugOverlay(
        show: (c) async {
          final pin = await askNewPin(c);
          if (pin != null) await s.c.identity.keyring.changePin(Uint8List(32), pin);
        },
      ),
    ),
    DebugPageEntry(
      '危险操作确认',
      (s) => DebugOverlay(
        show: (c) async {
          final ok = await confirmDialog(c, title: '删除示例环境？', body: '第一个示例环境及其中的变量将被删除。', ok: '删除', danger: true);
          if (ok && c.mounted && s.vault.environments.isNotEmpty) {
            final id = s.vault.environments.first.id;
            await runBusy(c, () => s.c.guard(() => s.vault.deleteEnvironment(id)), done: '已删除示例环境');
          }
        },
      ),
    ),
    DebugPageEntry(
      '更新弹层',
      (s) => DebugOverlay(show: (c) => checkForUpdate(c, manual: true, channel: s.c.updateChannel)),
    ),
  ],
};

Widget _environment(DebugSession s, {required bool edit}) {
  if (s.vault.environments.isEmpty) return const Center(child: Text('当前没有示例环境，请先在首页创建环境。'));
  final id = s.vault.environments.first.id;
  return edit ? VariableEditPage(c: s.c, envId: id) : EnvironmentPage(c: s.c, envId: id);
}

class DebugCatalog extends StatelessWidget {
  const DebugCatalog({super.key, required this.session, required this.onOpen, required this.options, this.error});
  final DebugSession session;
  final ValueChanged<DebugPageEntry> onOpen;
  final List<Widget> options;
  final String? error;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Banner2('这里全部是模拟数据，退出后丢弃；初始 PIN 为 123456，密码为 preview-password，邮箱验证码为 12345678。'),
      if (error != null) Banner2(error!, warn: true),
      ExpansionTile(title: const Text('显示与数据场景'), children: options),
      if (session.vault.requests.isNotEmpty) ...[
        const SectionTitle('示例核对码'),
        CodeBox(
          pairingCode(
            pairingFingerprint(
              session.vault.requests.first.id,
              session.vault.requests.first.signPub,
              session.vault.requests.first.boxPub,
              session.vault.requests.first.rootPub,
            ),
          ),
        ),
      ],
      for (final group in debugPages().entries) ...[
        SectionTitle(group.key),
        Card(
          child: Column(
            children: [
              for (final entry in group.value)
                ListTile(
                  title: Text(entry.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => onOpen(entry),
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 24),
    ],
  );
}

class DebugOverlay extends StatefulWidget {
  const DebugOverlay({super.key, required this.show});
  final Future<dynamic> Function(BuildContext) show;
  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.show(context);
    });
  }

  @override
  Widget build(BuildContext context) => AppPage(
    appBar: const AppBarSurface(title: Text('弹窗预览')),
    body: (c) => Center(
      child: FilledButton(onPressed: () => widget.show(c), child: const Text('重新打开弹窗')),
    ),
  );
}
