// 新页面、弹窗或分步状态必须同步添加到这里；所有入口使用 DebugSession。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/debug_session.dart';
import '../app/updater.dart';
import '../core/crypto.dart';
import '../core/debug_account.dart';
import 'about.dart';
import 'ai_prompt.dart';
import 'auth_pages.dart';
import 'devices.dart';
import 'device_review.dart';
import 'environments.dart';
import 'feedback_debug.dart';
import 'glass.dart';
import 'glass_debug.dart';
import 'home.dart';
import 'lock.dart';
import 'lock_debug.dart';
import 'pairing.dart';
import 'pairing_code.dart';
import 'pin_setup.dart';
import 'recovery_actions.dart';
import 'recovery_pages.dart';
import 'scanner.dart';
import 'settings.dart';
import 'widgets.dart';
import 'theme.dart';

class DebugPageEntry {
  const DebugPageEntry(this.name, this.page, {this.stage = Stage.home, this.prepare, this.followStage = true});
  final String name;
  final Widget Function(DebugSession) page;
  final Stage stage;
  final Future<void> Function(DebugSession)? prepare;
  final bool followStage;
}

Map<String, List<DebugPageEntry>> debugPages() => {
  '首页与管理': [
    DebugPageEntry('首页、底栏交互动效与系统间距', (s) => s.vault.paired ? HomePage(c: s.c) : SignInPage(c: s.c)),
    DebugPageEntry('玻璃透明度与折射对照', (s) => GlassDebugPage(c: s.c)),
    DebugPageEntry('通知默认动效与下载进度', (_) => const FeedbackDebugPage()),
    DebugPageEntry('环境列表与行尾间距', (s) => EnvironmentsTab(c: s.c)),
    DebugPageEntry('设备列表、添加设备菜单与行尾间距', (s) => s.vault.paired ? DevicesTab(c: s.c) : SignInPage(c: s.c)),
    DebugPageEntry('设置、白色滑块与输入弹窗', (s) => s.vault.paired ? SettingsTab(c: s.c) : SignInPage(c: s.c)),
    DebugPageEntry('关于、连点版本号与开源许可', (s) => AboutPage(c: s.c)),
    DebugPageEntry('环境详情、复制间距与菜单', (s) => _environment(s, edit: false)),
    DebugPageEntry('添加变量', (s) => _environment(s, edit: true)),
    DebugPageEntry('编辑变量', (s) {
      if (s.vault.environments.isEmpty) return _environment(s, edit: true);
      final id = s.vault.environments.first.id;
      return VariableEditPage(c: s.c, envId: id, name: s.vault.entries(id).keys.firstOrNull);
    }),
    DebugPageEntry('无法解密的变量（删除或重新填写）', (s) {
      if (s.vault.environments.isEmpty) return _environment(s, edit: true);
      final id = s.vault.environments.first.id;
      return VariableEditPage(c: s.c, envId: id, name: s.vault.brokenVariables(id).firstOrNull);
    }),
    DebugPageEntry(
      '设备详情与权限',
      (s) => s.vault.devices.isEmpty
          ? const Center(child: Text('当前没有示例设备，请切换到正常数据。'))
          : DevicePage(c: s.c, deviceId: s.vault.devices.last.id),
    ),
    DebugPageEntry('扫码添加与核对码弹窗', (s) => AddDevicePage(c: s.c)),
    DebugPageEntry('生成配对码与剩余时间', (s) => DebugOverlay(show: (c) => showPairingCode(c, s.c))),
    DebugPageEntry('复制 AI 安装提示词（仅服务器或含邮箱和配对码）', (s) => DebugOverlay(show: (c) => showAiPrompt(c, s.c))),
    DebugPageEntry(
      '批准与拒绝设备（用配对码发起）',
      (s) => s.vault.requests.isEmpty
          ? const Center(child: Text('当前没有待批准请求，请重置示例。'))
          : ReviewPairingPage(c: s.c, request: s.vault.requests.first, scanned: false),
    ),
  ],
  '账号接入': [
    DebugPageEntry('连接服务器', (s) => ConnectPage(c: s.c), stage: Stage.connect),
    DebugPageEntry('扫描服务器', (_) => const ScanServerPage()),
    DebugPageEntry('输入邮箱、注册与重新设置确认', (s) => SignInPage(c: s.c), stage: Stage.signedOut),
    DebugPageEntry(
      '验证邮箱',
      (s) => VerifyEmailPage(c: s.c),
      stage: Stage.verifyEmail,
      prepare: (s) => s.c.register('new@example.invalid'),
    ),
    DebugPageEntry(
      '设置 PIN 与生物识别',
      (s) => SetPinPage(c: s.c),
      stage: Stage.setPin,
      prepare: (s) async {
        s.prepareAccount();
      },
    ),
    DebugPageEntry(
      '未授权手机',
      (s) => UnpairedPage(c: s.c),
      stage: Stage.unpaired,
      prepare: (s) async => s.prepareAccount(),
    ),
    DebugPageEntry(
      '接入这台手机：输入配对码',
      (s) => DebugOverlay(
        background: UnpairedPage(c: s.c),
        show: askPairingCode,
      ),
      stage: Stage.unpaired,
      prepare: (s) async => s.prepareAccount(),
    ),
    DebugPageEntry(
      '等待批准（扫码）',
      (s) => PairingWaitPage(c: s.c),
      stage: Stage.pairing,
      prepare: (s) => _waiting(s),
    ),
    DebugPageEntry(
      '等待批准（用配对码发起）',
      (s) => PairingWaitPage(c: s.c),
      stage: Stage.pairing,
      prepare: (s) => _waiting(s, code: DebugAccount.pairingCode),
    ),
  ],
  '恢复与安全': [
    DebugPageEntry('后台计时与 App 锁定', (s) => LockDebugPage(c: s.c), followStage: false),
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
    DebugPageEntry('重置账号', (s) => AccountResetPage(c: s.c, email: 'demo@example.invalid')),
    DebugPageEntry('更换恢复码', (s) => s.vault.paired ? RotationPage(c: s.c) : SignInPage(c: s.c)),
    DebugPageEntry(
      '强制更换恢复码',
      (s) => s.vault.paired ? RotationPage(c: s.c, forced: true) : SignInPage(c: s.c),
      stage: Stage.rotation,
    ),
    DebugPageEntry(
      '恢复后检查设备',
      (s) => s.vault.paired ? DeviceReviewView(c: s.c, onDone: s.c.finishRotation) : SignInPage(c: s.c),
      stage: Stage.rotation,
    ),
    DebugPageEntry(
      '恢复完成与模拟 PDF',
      stage: Stage.rotation,
      (s) => !s.vault.paired
          ? SignInPage(c: s.c)
          : RecoveryDoneView(
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
      '首页新建环境、遮罩与键盘弹出避让',
      (s) => DebugOverlay(
        background: HomePage(c: s.c),
        show: (c) => askName(c, title: '新建环境', label: '环境名称'),
      ),
    ),
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
    DebugPageEntry('身份验证与 PIN 错误提示', (_) => DebugOverlay(show: (c) => verifyIdentity(c, '验证模拟身份后继续'))),
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
      '检查更新、长说明与下载页',
      (s) => DebugOverlay(show: (c) => checkForUpdate(c, manual: true, channel: s.c.updateChannel)),
    ),
  ],
};

Future<void> _waiting(DebugSession s, {String? code}) async {
  s.prepareAccount();
  s.c.pendingPairing = await s.account.startPairing(s.c.session!, '示例手机', code: code);
}

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
      const Banner2(
        '这里全部是模拟数据，退出后丢弃；初始 PIN 为 123456，邮箱验证码为 12345678，配对码为 7K3M-9Q2P。\n'
        '输入邮箱页：demo@example.invalid 是已设置的账号，setup@example.invalid 是未完成设置的账号，其他邮箱按未注册处理。',
      ),
      if (error != null) Banner2(error!, warn: true),
      ExpansionTile(title: const Text('显示与数据场景'), children: options),
      for (final r in session.vault.requests) ...[
        SectionTitle(r.authorized ? '示例核对码（用配对码发起）' : '示例核对码（只能扫码或手输找到）'),
        CodeBox(pairingCode(pairingFingerprint(r.id, r.signPub, r.boxPub, r.rootPub))),
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
  const DebugOverlay({super.key, required this.show, this.background});
  final Widget? background;
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
  Widget build(BuildContext context) =>
      widget.background ??
      AppPage(
        appBar: const AppBarSurface(title: Text('弹窗预览')),
        body: (c) => ListView(
          padding: pagePadding(c, EdgeInsets.zero),
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Banner2('可在目录切换明暗、大字号、高对比度和减少动态效果；重复打开与关闭，检查玻璃和边缘随动画一起出现。输入错误 PIN 可查看错误提示。'),
            ),
            FilledButton(onPressed: () => widget.show(c), child: const Text('重新打开弹窗')),
            for (var i = 0; i < 8; i++)
              Container(
                height: 72,
                color: i.isEven ? context.palette.sage : context.palette.yellow,
                alignment: Alignment.center,
                child: Text('合成背景 ${i + 1} · 检查弹窗折射与文字可读性', style: TextStyle(color: Palette.light.ink)),
              ),
          ],
        ),
      );
}
