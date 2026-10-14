// AI 安装提示词：与实例首页的写法一致，带上邮箱和配对码时 AI 助手不必再询问。
import 'package:flutter_test/flutter_test.dart';
import 'package:harmonia/core/ai_prompt.dart';

void main() {
  test('只带服务器时让 AI 助手向用户询问邮箱和配对码', () {
    final p = aiInstallPrompt('https://env.example.com');
    expect(p, contains('Harmonia（和弦，https://env.example.com）'));
    expect(p, contains('接入服务器 https://env.example.com（邮箱和配对码向用户询问）'));
    expect(p, contains('/update-feed/install.sh | HARMONIA_YES=0 sh'));
    expect(
      p,
      contains(
        "\$env:HARMONIA_YES = '0'; irm https://github.com/harmonia-vault/harmonia/releases/download/update-feed/install.ps1 | iex",
      ),
    );
    expect(p, contains('运行 harmonia skill'));
  });

  test('带邮箱和配对码时写进提示词，不再让 AI 助手询问', () {
    final p = aiInstallPrompt('https://env.example.com', email: 'me@example.com', code: '7K3M-9Q2P');
    expect(p, contains('邮箱是 me@example.com，配对码是 7K3M-9Q2P'));
    expect(p, isNot(contains('向用户询问')));
  });

  test('只给其中一项时按只带服务器处理', () {
    expect(aiInstallPrompt('https://a.example', email: 'me@example.com'), aiInstallPrompt('https://a.example'));
  });
}
