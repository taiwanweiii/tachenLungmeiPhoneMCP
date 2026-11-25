import 'package:curtain_mcp_flutter/features/chat/conversation_settings_sheet.dart';
import 'package:curtain_mcp_flutter/voice/voice_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('對話設定：開連續對話、加關鍵字、刪關鍵字都會回報', (t) async {
    t.view.physicalSize = const Size(780, 1800);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);

    VoiceConversationSettings? last;
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        // 跟 App 一樣：FilledButton 預設滿版寬（曾經讓 Row 裡的按鈕畫不出來）
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 56)),
        ),
      ),
      home: Scaffold(
        body: ConversationSettingsSheet(
          initial: VoiceConversationSettings(),
          onChanged: (s) => last = s,
        ),
      ),
    ));
    expect(t.takeException(), isNull);
    expect(find.text('停一下'), findsOneWidget);
    expect(find.text('10 秒'), findsOneWidget);
    expect(find.text('1.5 秒'), findsOneWidget);

    await t.tap(find.byType(Switch));
    await t.pump();
    expect(last?.continuous, true);
    expect(last?.bargeInEnabled, true);

    await t.enterText(find.byType(TextField), '小隆');
    await t.tap(find.text('加入'));
    await t.pump();
    expect(last?.keywords, ['停一下', '小隆']);

    await t.tap(find.byTooltip('刪除「停一下」'));
    await t.pump();
    expect(last?.keywords, ['小隆']);
  });
}
