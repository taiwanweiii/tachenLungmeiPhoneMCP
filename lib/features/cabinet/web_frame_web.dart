import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;
import 'cabinet_transport.dart';

/// Chrome（Flutter Web）版容器：iframe + postMessage。
/// 網頁端的對應接收程式在 tachenfurniture.client/src/utils/hostBridge.js。
///
/// 外層 → 網頁：{ source:'cabinet-host', id, method, args }
/// 網頁 → 外層：{ source:'cabinet-host-reply', id, result }（指令回覆）
///              { source:'cabinet-bridge', type, data, at }（事件）
Widget buildCabinetFrame({
  required Uri uri,
  required bool interactive,
  required void Function(CabinetTransport transport) onTransport,
  required VoidCallback onLoaded,
  required void Function(Map<String, dynamic> payload) onEvent,
}) =>
    _FrameView(
      uri: uri,
      interactive: interactive,
      onTransport: onTransport,
      onLoaded: onLoaded,
      onEvent: onEvent,
    );

int _viewSeq = 0;

class _FrameView extends StatefulWidget {
  const _FrameView({
    required this.uri,
    required this.interactive,
    required this.onTransport,
    required this.onLoaded,
    required this.onEvent,
  });
  final Uri uri;

  /// false = 小視窗：iframe 不接收滑鼠／觸控，事件交給蓋在上面的 Flutter 元件
  /// （Flutter Web 上，蓋在 iframe 上的元件預設收不到點擊）
  final bool interactive;
  final void Function(CabinetTransport) onTransport;
  final VoidCallback onLoaded;
  final void Function(Map<String, dynamic>) onEvent;

  @override
  State<_FrameView> createState() => _FrameViewState();
}

class _FrameViewState extends State<_FrameView> {
  late final String _viewType;
  late final web.HTMLIFrameElement _iframe;
  late final _FrameTransport _transport;
  StreamSubscription<web.Event>? _loadSub;

  @override
  void initState() {
    super.initState();
    _viewType = 'cabinet-frame-${_viewSeq++}';
    _iframe = web.HTMLIFrameElement()
      ..src = widget.uri.toString()
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.pointerEvents = widget.interactive ? 'auto' : 'none'
      ..allow = 'fullscreen';
    _transport = _FrameTransport(
      _iframe,
      widget.uri.origin,
      widget.onEvent,
    );
    ui_web.platformViewRegistry
        .registerViewFactory(_viewType, (int viewId) => _iframe);
    _loadSub = web.EventStreamProviders.loadEvent
        .forTarget(_iframe)
        .listen((_) => widget.onLoaded());
    // 建立後馬上交給控制器；onLoaded 會在頁面載入完成時另外通知
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.onTransport(_transport));
  }

  @override
  void didUpdateWidget(covariant _FrameView old) {
    super.didUpdateWidget(old);
    if (old.interactive != widget.interactive) {
      _iframe.style.pointerEvents = widget.interactive ? 'auto' : 'none';
    }
  }

  @override
  void dispose() {
    _loadSub?.cancel();
    _transport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}

class _FrameTransport implements CabinetTransport {
  _FrameTransport(this._iframe, this._origin, this._onEvent) {
    _sub = web.EventStreamProviders.messageEvent
        .forTarget(web.window)
        .listen(_onMessage);
  }

  final web.HTMLIFrameElement _iframe;
  final String _origin;
  final void Function(Map<String, dynamic>) _onEvent;
  late final StreamSubscription<web.MessageEvent> _sub;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _seq = 0;

  void dispose() {
    _sub.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete({'ok': false, 'message': '視窗已關閉'});
      }
    }
    _pending.clear();
  }

  void _onMessage(web.MessageEvent e) {
    // 只收我們嵌入的那個網頁的訊息
    if (e.origin != _origin) return;
    final data = _toDart(e.data.dartify());
    if (data is! Map<String, dynamic>) return;
    switch (data['source']) {
      case 'cabinet-host-reply':
        final id = data['id'];
        final c = id is num ? _pending.remove(id.toInt()) : null;
        if (c != null && !c.isCompleted) {
          final r = data['result'];
          c.complete(r is Map<String, dynamic>
              ? r
              : {'ok': false, 'message': '網頁回傳格式不正確'});
        }
        break;
      case 'cabinet-bridge':
        _onEvent(data);
        break;
    }
  }

  /// dartify 出來的 Map 是 Map<Object?, Object?>，統一轉成 Map<String, dynamic>
  static Object? _toDart(Object? v) {
    if (v is Map) {
      return v.map((k, val) => MapEntry('$k', _toDart(val)));
    }
    if (v is List) return v.map(_toDart).toList();
    return v;
  }

  Future<Map<String, dynamic>> _send(String method, List<dynamic> args,
      {Duration timeout = const Duration(seconds: 180)}) {
    final win = _iframe.contentWindow;
    if (win == null) {
      return Future.value({'ok': false, 'message': '網頁視窗還沒就緒'});
    }
    final id = ++_seq;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    win.postMessage(
      {'source': 'cabinet-host', 'id': id, 'method': method, 'args': args}
          .jsify(),
      _origin.toJS,
    );
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      return {'ok': false, 'message': '網頁沒有回應（逾時）'};
    });
  }

  @override
  Future<Map<String, dynamic>> call(String method, List<dynamic> args) =>
      _send(method, args);

  @override
  Future<bool> hasBridge() async {
    final r = await _send('hasBridge', const [],
        timeout: const Duration(seconds: 8));
    return r['present'] == true;
  }

  @override
  Future<bool> hasSession() async {
    final r = await _send('hasSession', const [],
        timeout: const Duration(seconds: 8));
    return r['loggedIn'] == true;
  }

  @override
  Future<Map<String, dynamic>> signIn(String userId, String password) =>
      _send('signIn', [userId, password],
          timeout: const Duration(seconds: 30));

  @override
  Future<void> reload(Uri uri) async {
    _iframe.src = uri.toString();
  }
}
