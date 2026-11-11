// 新页面、弹窗或分步状态必须同步添加到这里；所有入口使用 DebugSession。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/debug_session.dart';
import '../app/updater.dart';
import '../core/update_info.dart';
import '../core/crypto.dart';
import '../core/debug_account.dart';
import '../core/debug_approvals.dart';
import '../core/debug_push.dart';
import '../core/vault.dart' show ApprovalRequest;
import 'about.dart';
import 'ai_prompt.dart';
import 'approval.dart';
import 'auth_pages.dart';
import 'device_grants.dart';
import 'devices.dart';
import 'device_review.dart';
import 'env_editor.dart';
import 'env_page.dart';
import 'env_var_sheet.dart';
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
import 'variable_edit.dart';
import 'vaults.dart';
import 'vaults_tab.dart';

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
    DebugPageEntry('变量库列表、新建按钮与行尾间距', (s) => VaultsTab(c: s.c)),
    DebugPageEntry('环境列表、新建按钮与行尾间距', (s) => EnvironmentsTab(c: s.c)),
    DebugPageEntry('设备列表、添加设备菜单与行尾间距', (s) => s.vault.paired ? DevicesTab(c: s.c) : SignInPage(c: s.c)),
    DebugPageEntry('设置、白色滑块与输入弹窗', (s) => s.vault.paired ? SettingsTab(c: s.c) : SignInPage(c: s.c)),
    DebugPageEntry('关于、连点版本号与开源许可', (s) => AboutPage(c: s.c)),
    DebugPageEntry('环境详情：来自哪个变量库、可访问的电脑与菜单', (s) => _environment(s)),
    DebugPageEntry('环境详情：同名变量被遮住、引用的变量库已删除', (s) => _environment(s, problems: true)),
    DebugPageEntry('环境变量面板：选中的变量（已改名），可以改名、移除、编辑值和备注', (s) => _envVariable(s, 'debug-env-2', 'LLM_KEY')),
    DebugPageEntry('环境变量面板：来自“全部变量”，不能单独移除的提示', (s) => _envVariable(s, 'debug-env-1', null)),
    DebugPageEntry('新建环境：添加变量库、勾选与改名、实时预览', (s) => EnvEditorPage(c: s.c)),
    DebugPageEntry('编辑引用：顺序、选择变量库和变量、重名时不能保存', (s) {
      final id = _problemEnv(s);
      return id == null ? _none('环境') : EnvEditorPage(c: s.c, envId: id);
    }),
    DebugPageEntry('变量库详情、用到它的环境、变量库 ID 与菜单', (s) => _vault(s, (id) => VaultPage(c: s.c, vaultId: id))),
    DebugPageEntry('添加变量', (s) => _vault(s, (id) => VariableEditPage(c: s.c, vaultId: id))),
    DebugPageEntry(
      '编辑变量',
      (s) => _vault(s, (id) => VariableEditPage(c: s.c, vaultId: id, name: s.vault.entries(id).keys.firstOrNull)),
    ),
    DebugPageEntry(
      '无法解密的变量（删除或重新填写）',
      (s) => _vault(s, (id) => VariableEditPage(c: s.c, vaultId: id, name: s.vault.brokenVariables(id).firstOrNull)),
    ),
    DebugPageEntry('设备详情：已授权的环境、无人值守标记、激活开关与拖动排序', (s) => _devicePage(s, 'debug-computer')),
    DebugPageEntry(
      '环境授权面板：需手机批准，“高级”默认收起；展开后开启无人值守的确认与期限',
      (s) => DebugOverlay(
        background: _devicePage(s, 'debug-computer'),
        show: (c) => editDeviceGrant(c, s.c, 'debug-computer', 'debug-env-4'),
      ),
    ),
    DebugPageEntry(
      '环境授权面板：已开启无人值守，“高级”默认展开、期限与取消授权',
      (s) => DebugOverlay(
        background: _devicePage(s, 'debug-computer'),
        show: (c) => editDeviceGrant(c, s.c, 'debug-computer', 'debug-env-1'),
      ),
    ),
    DebugPageEntry(
      '添加环境：只列还没授权的，默认只读、需手机批准',
      (s) => DebugOverlay(
        background: _devicePage(s, 'debug-computer'),
        show: (c) => addDeviceGrant(c, s.c, 'debug-computer'),
      ),
    ),
    DebugPageEntry('电脑版本与更新：有新版本、让电脑更新、自动更新', (s) => _devicePage(s, 'debug-computer')),
    DebugPageEntry('电脑版本与更新：已是最新、后台服务不在线', (s) => _devicePage(s, 'debug-linux')),
    DebugPageEntry('电脑版本与更新：版本未知、不支持在手机上更新', (s) => _devicePage(s, 'debug-mac')),
    DebugPageEntry('扫码添加与核对码弹窗', (s) => AddDevicePage(c: s.c)),
    DebugPageEntry('生成配对码与剩余时间', (s) => DebugOverlay(show: (c) => showPairingCode(c, s.c))),
    DebugPageEntry('复制 AI 安装提示词（仅服务器或含邮箱和配对码）', (s) => DebugOverlay(show: (c) => showAiPrompt(c, s.c))),
    DebugPageEntry(
      '批准与拒绝设备（用配对码发起，添加环境并设置授权）',
      (s) => s.vault.requests.isEmpty
          ? const Center(child: Text('当前没有待批准请求，请重置示例。'))
          : ReviewPairingPage(c: s.c, request: s.vault.requests.first, scanned: false),
    ),
    DebugPageEntry(
      '设备列表：电脑的批准请求',
      (s) => DevicesTab(c: s.c),
      prepare: (s) async {
        s.c.approvals = await s.vault.pendingApprovals();
      },
    ),
    DebugPageEntry('批准使用变量：居中放大的请求码、命令、按环境列出、多久内不再询问与范围', (s) => _approval(s, debugApproval())),
    DebugPageEntry('批准使用变量：Windows 电脑只能授权给所有程序', (s) => _approval(s, debugApproval(deviceId: 'debug-computer'))),
    DebugPageEntry('批准写入变量：新增和删除、值默认遮住', (s) => _approval(s, debugApproval(write: true))),
    DebugPageEntry('批准请求已失效（电脑已取消或超时）', (s) => _approval(s, debugApproval(), expire: true)),
    DebugPageEntry('设备详情：正在生效的授权与结束', (s) => _devicePage(s, 'debug-mac')),
  ],
  '后台通知': [
    DebugPageEntry('设置：后台通知正常', (s) => SettingsTab(c: s.c), prepare: (s) => s.setPush(DebugPushScenario.ok)),
    DebugPageEntry(
      '设置：后台通知已关闭，打开开关重新登记',
      (s) => SettingsTab(c: s.c),
      prepare: (s) => s.setPush(DebugPushScenario.ok, enabled: false),
    ),
    DebugPageEntry(
      '设置：还没有允许通知，点“允许通知”请求权限',
      (s) => SettingsTab(c: s.c),
      prepare: (s) => s.setPush(DebugPushScenario.needsPermission),
    ),
    DebugPageEntry(
      '设置：系统权限已关闭与打开系统设置',
      (s) => SettingsTab(c: s.c),
      prepare: (s) => s.setPush(DebugPushScenario.systemOff),
    ),
    DebugPageEntry(
      '设置：这台手机收不到后台通知',
      (s) => SettingsTab(c: s.c),
      prepare: (s) => s.setPush(DebugPushScenario.unavailable),
    ),
    DebugPageEntry('设置：服务器关闭了后台通知', (s) => SettingsTab(c: s.c), prepare: (s) => s.setPush(DebugPushScenario.serverOff)),
    DebugPageEntry(
      '点开通知时请求已处理或已过期',
      (s) => DebugOverlay(
        background: HomePage(c: s.c),
        show: (c) async => toast(c, staleNotificationText),
      ),
    ),
  ],
  '账号接入': [
    DebugPageEntry('连接服务器：默认地址、手动修改与模拟连接', (s) => ConnectPage(c: s.c), stage: Stage.connect),
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
      '恢复后检查设备：多台管理设备与电脑、卡片间距与勾选移除',
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
      '首页新建变量库、遮罩与键盘弹出避让',
      (s) => DebugOverlay(
        background: HomePage(c: s.c),
        show: (c) => askName(c, title: '新建变量库', label: '变量库名称'),
      ),
    ),
    DebugPageEntry('新建变量库，创建后打开它', (s) => DebugOverlay(show: (c) => createVaultFlow(c, s.c))),
    DebugPageEntry(
      '重命名弹窗',
      (s) => DebugOverlay(
        show: (c) async {
          if (s.vault.vaults.isEmpty) {
            toast(c, '请先创建示例变量库');
            return;
          }
          final v = s.vault.vaults.first;
          final name = await askName(c, title: '重命名变量库', initial: v.name);
          if (name != null && c.mounted) {
            await runBusy(c, () => s.c.guard(() => s.vault.renameVault(v.id, name)), done: '已重命名');
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
      appleDistribution ? '检查更新与新版本号' : '检查更新、长说明与下载页',
      (s) => DebugOverlay(show: (c) => checkForUpdate(c, manual: true, channel: s.c.updateChannel)),
    ),
  ],
};

Future<void> _waiting(DebugSession s, {String? code}) async {
  s.prepareAccount();
  s.c.pendingPairing = await s.account.startPairing(s.c.session!, '示例手机', code: code);
}

Widget _devicePage(DebugSession s, String id) => s.vault.devices.any((d) => d.id == id)
    ? DevicePage(c: s.c, deviceId: id)
    : const Center(child: Text('当前没有示例设备，请切换到正常数据。'));

/// 批准页。[expire] 时请求随即从待处理列表消失，显示“已失效”。
Widget _approval(DebugSession s, ApprovalRequest a, {bool expire = false}) {
  if (!s.vault.approvals.any((x) => x.id == a.id)) s.vault.approvals.add(a);
  s.c.approvals = List.of(s.vault.approvals);
  if (expire) {
    Future.delayed(const Duration(milliseconds: 600), () {
      s.vault.expireApproval(a.id);
      s.c.approvals = List.of(s.vault.approvals);
      s.c.refresh();
    });
  }
  return ApprovalPage(c: s.c, request: a);
}

Widget _none(String what) => Center(child: Text('当前没有示例$what，请重置示例或先在首页创建。'));

/// 有同名被遮住或引用失效的示例环境。
String? _problemEnv(DebugSession s) =>
    s.vault.environments.where((e) => envProblems(s.c, e.id).isNotEmpty).firstOrNull?.id;

Widget _environment(DebugSession s, {bool problems = false}) {
  final id = problems ? _problemEnv(s) : s.vault.environments.firstOrNull?.id;
  return id == null ? _none('环境') : EnvironmentPage(c: s.c, envId: id);
}

/// 环境详情页上打开变量面板；[name] 为 null 时取第一个变量。
Widget _envVariable(DebugSession s, String envId, String? name) {
  final env = s.vault.environments.where((e) => e.id == envId).firstOrNull;
  final item = env?.items.where((i) => name == null || i.name == name).firstOrNull;
  if (env == null || item == null) return _none('环境');
  return DebugOverlay(
    background: EnvironmentPage(c: s.c, envId: envId),
    show: (c) => showEnvVariableSheet(c, c: s.c, envId: envId, item: item, entry: s.vault.envEntries(envId)[item.name]),
  );
}

Widget _vault(DebugSession s, Widget Function(String id) page) {
  final id = s.vault.vaults.firstOrNull?.id;
  return id == null ? _none('变量库') : page(id);
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
