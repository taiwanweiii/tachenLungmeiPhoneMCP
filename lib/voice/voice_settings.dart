import 'package:shared_preferences/shared_preferences.dart';

/// 簡易模式的語音對話設定（長按「你」或右上角選單打開）：
/// - 連續對話：AI 講完自動再開始聽，不用每句都再按一次
/// - 幾秒沒講話自動暫停
/// - 講完停頓多久算一句
/// - 插話關鍵字：連續對話時，AI 講話中說出關鍵字就打斷 AI，改聽使用者說
///
/// 關鍵字只做文字比對（手機語音辨識邊聽邊出字，半秒內就能反應），不送 AI 判斷：
/// 它是使用者自己設定的控制詞，作用跟按鈕一樣，真正要做什麼還是交給 AI。
class VoiceConversationSettings {
  bool continuous;

  /// 開始聽之後一直沒開口幾秒就暫停
  int idleSeconds;

  /// 講完停頓幾秒就算一句、送出
  double endSilenceSeconds;

  /// 插話關鍵字（空的 = 不能插話）
  List<String> keywords;

  VoiceConversationSettings({
    this.continuous = false,
    this.idleSeconds = 10,
    this.endSilenceSeconds = 1.5,
    List<String>? keywords,
  }) : keywords = keywords ?? const ['停一下'];

  static const minIdle = 5, maxIdle = 30;
  static const minEndSilence = 0.8, maxEndSilence = 4.0;

  static const _kContinuous = 'voice_continuous';
  static const _kIdle = 'voice_idle_seconds';
  static const _kEndSilence = 'voice_end_silence';
  static const _kKeywords = 'voice_barge_keywords';

  /// 插話有沒有作用：要開連續對話、而且至少有一個關鍵字
  bool get bargeInEnabled => continuous && keywords.isNotEmpty;

  static Future<VoiceConversationSettings> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return VoiceConversationSettings(
        continuous: p.getBool(_kContinuous) ?? false,
        idleSeconds: (p.getInt(_kIdle) ?? 10).clamp(minIdle, maxIdle),
        endSilenceSeconds:
            (p.getDouble(_kEndSilence) ?? 1.5).clamp(minEndSilence, maxEndSilence),
        keywords: p.getStringList(_kKeywords) ?? const ['停一下'],
      );
    } catch (_) {
      return VoiceConversationSettings();
    }
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kContinuous, continuous);
      await p.setInt(_kIdle, idleSeconds);
      await p.setDouble(_kEndSilence, endSilenceSeconds);
      await p.setStringList(_kKeywords, keywords);
    } catch (_) {}
  }
}

/// 比對用的正規化：去掉空白、標點，全形轉半形，英文轉小寫
String normalizeSpoken(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    var c = r;
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0; // 全形 → 半形
    final ch = String.fromCharCode(c);
    if (RegExp(r'[\s\p{P}\p{S}]', unicode: true).hasMatch(ch)) continue;
    b.write(ch.toLowerCase());
  }
  return b.toString();
}

/// 兩段等長文字差幾個字
int _diff(String a, String b) {
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    if (a.codeUnitAt(i) != b.codeUnitAt(i)) d++;
  }
  return d;
}

/// 在 [heard] 裡找插話關鍵字。找到回傳「關鍵字後面的話」（沒有就是空字串），找不到回 null。
///
/// - 關鍵字 4 個字以上容許語音聽錯一個字（例如「小隆停下」聽成「小龍停下」）；
///   3 個字以下要完全一樣。常被聽錯的寫法可以另外加成一個關鍵字。
/// - [speaking]：AI 正在唸的文字。麥克風會收到喇叭的聲音，聽到的那幾個字如果
///   AI 正在唸的內容裡也有，就當作是 AI 自己的聲音，不算使用者插話。
/// - 同一句有好幾處符合時用最後一處（使用者插話通常在最後）
String? matchBargeIn(String heard, List<String> keywords, {String? speaking}) {
  final h = normalizeSpoken(heard);
  final spoken = speaking == null ? '' : normalizeSpoken(speaking);
  int? bestEnd;
  for (final raw in keywords) {
    final k = normalizeSpoken(raw);
    if (k.isEmpty || h.length < k.length) continue;
    // 3 個字以下要完全一樣（「看一下」「等一下」跟「停一下」只差一個字，很容易誤觸）；
    // 4 個字以上才容許聽錯一個字
    final tolerance = k.length >= 4 ? 1 : 0;
    for (var i = h.length - k.length; i >= 0; i--) {
      final w = h.substring(i, i + k.length);
      if (_diff(w, k) > tolerance) continue;
      if (spoken.contains(w)) continue; // AI 自己唸到的，不算
      final end = i + k.length;
      if (bestEnd == null || end > bestEnd) bestEnd = end;
      break; // 這個關鍵字最後一處已找到
    }
  }
  if (bestEnd == null) return null;
  return h.substring(bestEnd);
}
