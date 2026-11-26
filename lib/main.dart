import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'core/di/service_locator.dart';
import 'services/mcp_client_service.dart';
import 'services/web_session.dart';
import 'app.dart';
import 'features/chat/simple_style.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await setupServiceLocator();
  await AppStyle.load(); // 畫面風格先讀好，第一個畫面就是對的顏色
  runApp(const ProviderScope(child: CurtainMcpApp()));
  // 畫面先出來，登入在背景做，失敗不影響使用
  unawaited(_autoLogin());
}

/// 畫面一打開就用 .env 的預設工號密碼登入（DEFAULT_LOGIN_USER / DEFAULT_LOGIN_PASSWORD）。
/// 沒設定就略過；想改帳號，到設定頁重新登入即可。
/// 登入成功後，內嵌的系統櫃網頁也用同一組帳密（只放記憶體）。
Future<void> _autoLogin() async {
  final user = (dotenv.maybeGet('DEFAULT_LOGIN_USER') ?? '').trim();
  final password = dotenv.maybeGet('DEFAULT_LOGIN_PASSWORD') ?? '';
  if (user.isEmpty || password.isEmpty) return;

  // 剛開機網路／伺服器可能還沒好：先快速試 3 次，之後每 15 秒再試，最多約 10 分鐘。
  // （只試 3 次失敗就放棄的話，內嵌網頁會一直停在登入畫面、規格預設值永遠算不出來）
  for (var attempt = 1; attempt <= 43; attempt++) {
    try {
      await GetIt.instance<McpClientService>()
          .authAsync('/auth/login', {'userId': user, 'password': password});
      GetIt.instance<WebSession>().rememberLogin(user, password);
      debugPrint('✅ 已用預設工號 $user 登入');
      return;
    } catch (e) {
      debugPrint('⚠️ 預設登入失敗（第 $attempt 次）：$e');
      await Future<void>.delayed(Duration(seconds: attempt < 3 ? 3 : 15));
    }
  }
}
