// 中文按词折行：用 BudouX 的简体中文模型（assets/budoux/zh-hans.json）判断词的边界，
// 再在同一个词的汉字之间插入不可见的“禁止断行”字符，让折行只落在词与词之间。
// 每一行末尾的四个字也连在一起，免得只剩一两个字落到下一行。
import 'dart:convert';

class PhraseBreaker {
  PhraseBreaker(this._model)
      : _base = -0.5 * _model.values.fold<int>(0, (sum, group) => sum + group.values.fold(0, (a, b) => a + b));

  factory PhraseBreaker.fromJson(String json) => PhraseBreaker((jsonDecode(json) as Map)
      .map((k, v) => MapEntry(k as String, (v as Map).map((a, b) => MapEntry(a as String, b as int)))));

  final Map<String, Map<String, int>> _model;
  final double _base;

  /// 禁止断行字符（WORD JOINER），不占宽度，也不显示。
  static const joiner = '⁠';

  /// 模型会拆开、但界面文案里应当连在一起的词。
  static const _keep = [
    '数据', '找回', '更换', '验证码', '恢复码', '二维码', '同一个',
    '只能', '每次', '不会', '这台', '锁屏', '打开', '再次', '本机',
  ];

  int _w(String group, String key) => _model[group]?[key] ?? 0;

  /// 把一行文字切成词（与 BudouX 的 Parser.parse 相同的打分方式）。
  List<String> words(String s) {
    if (s.isEmpty) return [];
    final out = [s[0]];
    for (var i = 1; i < s.length; i++) {
      var score = _base;
      if (i > 2) score += _w('UW1', s[i - 3]);
      if (i > 1) score += _w('UW2', s[i - 2]);
      score += _w('UW3', s[i - 1]);
      score += _w('UW4', s[i]);
      if (i + 1 < s.length) score += _w('UW5', s[i + 1]);
      if (i + 2 < s.length) score += _w('UW6', s[i + 2]);
      if (i > 1) score += _w('BW1', s.substring(i - 2, i));
      score += _w('BW2', s.substring(i - 1, i + 1));
      if (i + 1 < s.length) score += _w('BW3', s.substring(i, i + 2));
      if (i > 2) score += _w('TW1', s.substring(i - 3, i));
      if (i > 1) score += _w('TW2', s.substring(i - 2, i + 1));
      if (i + 1 < s.length) score += _w('TW3', s.substring(i - 1, i + 2));
      if (i + 2 < s.length) score += _w('TW4', s.substring(i, i + 3));
      if (score > 0) {
        out.add(s[i]);
      } else {
        out[out.length - 1] += s[i];
      }
    }
    return out;
  }

  static bool _han(String c) {
    final u = c.codeUnitAt(0);
    return u >= 0x4E00 && u <= 0x9FFF;
  }

  /// 在同一个词的汉字之间、以及每一行末尾的四个字之间插入禁止断行字符；
  /// 换行符分开的每一行单独处理。其余位置的英文、数字和标点交给系统原有的折行规则。
  String glue(String text) => text.split('\n').map(_glueLine).join('\n');

  String _glueLine(String s) {
    if (s.length < 2) return s;
    // inside[i] 为真表示第 i 个字和前一个字属于同一个词。
    final inside = List.filled(s.length, false);
    var at = 0;
    for (final word in words(s)) {
      for (var k = 1; k < word.length; k++) {
        inside[at + k] = true;
      }
      at += word.length;
    }
    for (final word in _keep) {
      for (var from = s.indexOf(word); from >= 0; from = s.indexOf(word, from + 1)) {
        for (var k = 1; k < word.length; k++) {
          inside[from + k] = true;
        }
      }
    }
    // 不超过六个字的行不会折成“一行加孤字”，不用处理行尾。
    final tail = s.length > 6 ? s.length - 3 : s.length;
    final out = StringBuffer(s[0]);
    for (var i = 1; i < s.length; i++) {
      if (i >= tail || (inside[i] && _han(s[i - 1]) && _han(s[i]))) out.write(joiner);
      out.write(s[i]);
    }
    return out.toString();
  }
}
