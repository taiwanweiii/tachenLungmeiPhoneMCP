import 'package:curtain_mcp_flutter/voice/voice_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('插話關鍵字比對', () {
    const kw = ['停一下'];

    test('只說關鍵字：回空字串（打斷，等使用者接著說）', () {
      expect(matchBargeIn('停一下', kw), '');
      expect(matchBargeIn('停一下。', kw), '');
    });

    test('關鍵字後面接著講：回後面的話', () {
      expect(matchBargeIn('停一下，改成兩個', kw), '改成兩個');
    });

    test('前面混到 AI 的聲音：只取關鍵字後面', () {
      expect(matchBargeIn('已幫你選好請在畫面停一下改成兩個', kw), '改成兩個');
    });

    test('4 個字以上的關鍵字：語音聽錯一個字也算', () {
      expect(matchBargeIn('小龍停下 改寬度', ['小隆停下']), '改寬度');
    });

    test('3 個字以下要完全一樣（「看一下」不能誤觸「停一下」）；聽錯的寫法可另外加', () {
      expect(matchBargeIn('停以下 改寬度', kw), isNull);
      expect(matchBargeIn('停以下 改寬度', ['停一下', '停以下']), '改寬度');
    });

    test('沒說關鍵字：不打斷', () {
      expect(matchBargeIn('請在畫面上看一下規格', kw), isNull);
      expect(matchBargeIn('', kw), isNull);
    });

    test('AI 自己唸到的字（喇叭回音）不算插話', () {
      const reply = '好的，請等一下，我幫你查';
      // 「等一下」跟「停一下」只差一個字，但它是 AI 正在唸的內容
      expect(matchBargeIn('好的請等一下我幫你查', kw, speaking: reply), isNull);
      // 使用者真的說了「停一下」：AI 沒唸過這三個字，算插話
      expect(matchBargeIn('好的請等一下停一下', kw, speaking: reply), '');
    });

    test('兩個字的關鍵字要完全一樣', () {
      expect(matchBargeIn('小龍你好', ['小隆']), isNull);
      expect(matchBargeIn('小隆改成三個', ['小隆']), '改成三個');
    });

    test('多個關鍵字、全形與英文大小寫', () {
      expect(matchBargeIn('ＳＴＯＰ 換牆', ['停一下', 'stop']), '換牆');
    });

    test('沒有關鍵字：不會打斷', () {
      expect(matchBargeIn('停一下', const []), isNull);
    });
  });

  group('設定存取', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('預設值：連續對話關、10 秒暫停、1.5 秒算一句、關鍵字「停一下」', () async {
      final s = await VoiceConversationSettings.load();
      expect(s.continuous, false);
      expect(s.idleSeconds, 10);
      expect(s.endSilenceSeconds, 1.5);
      expect(s.keywords, ['停一下']);
      expect(s.bargeInEnabled, false); // 沒開連續對話就不能插話
    });

    test('存了再讀回來一樣；超出範圍會被拉回', () async {
      final s = VoiceConversationSettings(
          continuous: true, idleSeconds: 99, endSilenceSeconds: 2.5, keywords: ['小隆']);
      await s.save();
      final r = await VoiceConversationSettings.load();
      expect(r.continuous, true);
      expect(r.idleSeconds, VoiceConversationSettings.maxIdle);
      expect(r.endSilenceSeconds, 2.5);
      expect(r.keywords, ['小隆']);
      expect(r.bargeInEnabled, true);
    });
  });
}
