import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'cabinet_transport.dart';

/// 原生 WebView（手機／桌面）版本：直接在頁面裡執行 JS。
class NativeTransport implements CabinetTransport {
  NativeTransport(this._c);
  final InAppWebViewController _c;

  @override
  Future<Map<String, dynamic>> call(String method, List<dynamic> args) async {
    try {
      final res = await _c.callAsyncJavaScript(
        functionBody: '''
          const fn = window.cabinetBridge && window.cabinetBridge[method];
          if (!fn) return { ok: false, message: '網頁橋接尚未就緒' };
          return await fn(...args);
        ''',
        arguments: {'method': method, 'args': args},
      );
      if (res == null) return {'ok': false, 'message': '網頁沒有回應'};
      if (res.error != null) return {'ok': false, 'message': '${res.error}'};
      final v = res.value;
      return v is Map
          ? Map<String, dynamic>.from(v)
          : {'ok': false, 'message': '網頁回傳格式不正確'};
    } catch (e) {
      return {'ok': false, 'message': '$e'};
    }
  }

  @override
  Future<bool> hasBridge() async {
    final r = await _c.callAsyncJavaScript(
        functionBody: 'return typeof window.cabinetBridge !== "undefined";');
    return r?.value == true;
  }

  @override
  Future<bool> hasSession() async {
    final r = await _c.callAsyncJavaScript(functionBody: '''
      const r = await fetch('/api/React/getSession');
      return r.status === 200;
    ''');
    return r?.value == true;
  }

  @override
  Future<Map<String, dynamic>> signIn(String userId, String password) async {
    // 帳密用參數傳入，不拼進字串，也不印出來
    final res = await _c.callAsyncJavaScript(
      functionBody: '''
        const r = await fetch('/Account/SignIn', {
          method: 'POST',
          body: JSON.stringify({
            Email: '', windowAuth: '', UserID: u, Password: p,
            btnLogin: '', RememberMe: 'Y', CmdID: 'UserLogin'
          }),
        });
        if (!r.ok) return { ok: false, message: 'HTTP ' + r.status };
        const d = await r.json();
        if (d && d.UserID && d.UserID.length > 0) return { ok: true };
        return { ok: false, message: (d && (d.Status || d.message)) || '登入失敗' };
      ''',
      arguments: {'u': userId, 'p': password},
    );
    final v = res?.value;
    return v is Map
        ? Map<String, dynamic>.from(v)
        : {'ok': false, 'message': '${res?.error ?? '登入失敗'}'};
  }

  @override
  Future<void> reload(Uri uri) =>
      _c.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString())));
}
