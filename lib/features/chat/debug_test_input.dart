import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 【只有除錯版會啟用】測試用的輸入口，給自動化測試（例如用 adb）輸入中文用。
///
/// 虛擬手機沒有中文輸入法，`adb shell input text` 又只能打英文，所以改成：
/// 把文字寫進 App 專屬目錄的 `test_input.txt`，App 每秒檢查一次，讀到就處理並刪掉檔案。
///
///   FILL:要填進輸入框的文字     只填進輸入框，不送出
///   SEND:要送出的文字           直接當成使用者輸入送出
///
/// 放檔案：
///   adb push test_input.txt /sdcard/Android/data/<應用程式 id>/files/test_input.txt
/// release 版不會啟用（呼叫端用 kDebugMode 擋住，這個檔案會被 tree-shake 掉）。
Timer? startTestInputWatcher({
  required bool Function() isMounted,
  required void Function(String text) onFill,
  required Future<void> Function(String text) onSend,
}) {
  if (!kDebugMode || kIsWeb) return null;
  var announced = false;
  return Timer.periodic(const Duration(seconds: 1), (_) async {
    try {
      final dir = await getExternalStorageDirectory();
      if (!announced) {
        announced = true;
        debugPrint('🧪 測試輸入口已啟動，監看：${dir?.path}/test_input.txt');
      }
      if (dir == null) return;
      final f = File('${dir.path}/test_input.txt');
      if (!await f.exists()) return;
      final raw = (await f.readAsString()).trim();
      await f.delete();
      if (!isMounted() || raw.isEmpty) return;
      debugPrint('🧪 測試輸入：$raw');
      if (raw.startsWith('FILL:')) {
        onFill(raw.substring(5));
      } else if (raw.startsWith('SEND:')) {
        await onSend(raw.substring(5));
      }
    } catch (e) {
      debugPrint('⚠️ 測試輸入失敗：$e');
    }
  });
}
