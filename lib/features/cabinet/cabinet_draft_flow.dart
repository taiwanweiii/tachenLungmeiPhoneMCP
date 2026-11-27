import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../models/mcp_models.dart';
import '../../services/mcp_client_service.dart';
import 'cabinet_web_controller.dart';

/// MCP 草稿 → 內嵌系統櫃配置畫面。
///
/// MCP 的 commit_case／quick_order 會給「更新詢單」連結：
///   {web}/app/store-price/{案號}/{空間}/{櫃組}?draft={草稿}&space={s}&wall={w}
/// App 攔下這種連結，不開外部瀏覽器，改成：
///   1. 在浮動視窗開 cabinet-config 編輯該案件的該櫃組（載入既有櫃體）
///   2. 向 MCP 取草稿（GET /drafts/{draft}），把這面牆「新增」的柜子灌進畫面
///   3. 使用者看過價格後，按畫面上的「更新詢單」才真的存檔（點連結進來的這條路由人按）
///      ※ 剛確認建立的新訂單改走 [autoSave]：使用者已經確認過，App 在背景直接存檔，不開畫面
///   4. 收到網頁的 saved 事件後，回報 MCP（POST /drafts/{draft}/applied）把已存的柜子從草稿移除
/// 新牆面／新空間的連結（/app/order/store/…）這裡不處理，照舊用外部瀏覽器開。
class CabinetDraftFlow {
  CabinetDraftFlow(this._ctrl, this._mcp) {
    _ctrl.events.listen(_onEvent);
  }

  final CabinetWebController _ctrl;
  final McpClientService _mcp;

  static final _linkRe = RegExp(r'/app/store-price/([^/?#]+)/([^/?#]+)/([^/?#]+)');

  /// 目前視窗正在處理的草稿：存檔成功後要回報哪些柜子
  String? _draftId;
  List<String> _appliedIds = const [];

  /// 取草稿裡還沒存進案件的柜子。優先用 MCP 工具（走 /mcp，經過網站的 MCP proxy 也能用；
  /// proxy 不轉發 /drafts，直接打 HTTP 會拿到網頁 HTML）；舊版 MCP 沒有這個工具才改打 /drafts。
  Future<dynamic> _getDraft(String draftId) async {
    final text = await _tool('get_pending_draft', {'caseNo': draftId});
    if (text != null) return jsonDecode(text);
    return _mcp.httpJson('GET', '/drafts/${Uri.encodeComponent(draftId)}');
  }

  /// 回報這批柜子已存進案件（從草稿移除）。失敗不影響已存的案件。
  Future<void> _markApplied(String draftId, List<String> ids) async {
    try {
      final text =
          await _tool('mark_draft_applied', {'caseNo': draftId, 'cabinets': ids});
      if (text != null) return;
      await _mcp.httpJson(
          'POST', '/drafts/${Uri.encodeComponent(draftId)}/applied',
          body: {'cabinets': ids});
    } catch (err) {
      debugPrint('⚠️ 回報草稿已套用失敗：$err');
    }
  }

  /// 呼叫 MCP 工具，回傳文字結果；MCP 沒有這個工具回傳 null（呼叫端改走舊的 HTTP 端點）。
  /// 工具回報失敗丟例外。
  Future<String?> _tool(String name, Map<String, dynamic> args) async {
    final ToolResult? r;
    try {
      r = await _mcp.callToolAsync(name, args);
    } catch (e) {
      if ('$e'.contains('找不到工具')) return null;
      rethrow;
    }
    final text = (r?.content ?? const <ToolContent>[])
        .where((c) => c.type == 'text')
        .map((c) => c.text ?? '')
        .join('')
        .trim();
    if (r == null || r.isError == true) {
      throw Exception(text.isEmpty ? '伺服器沒有回應' : text);
    }
    return text;
  }

  /// 例外轉成給人看的原因（不要出現 FormatException 這種字）
  static String _reason(Object e) {
    if (e is FormatException) return '伺服器回傳的不是草稿資料';
    return '$e'.replaceFirst(RegExp(r'^\w*(Exception|Error): '), '');
  }

  /// 解析「更新詢單」連結；不是這種連結回傳 null
  static ({
    String caseNo,
    String roomId,
    String closetId,
    String draft,
    String space,
    String wall
  })? parseLink(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final m = _linkRe.firstMatch(uri.path);
    final draft = uri.queryParameters['draft'];
    final space = uri.queryParameters['space'];
    final wall = uri.queryParameters['wall'];
    if (m == null || draft == null || space == null || wall == null) {
      return null;
    }
    return (
      caseNo: Uri.decodeComponent(m.group(1)!),
      roomId: Uri.decodeComponent(m.group(2)!),
      closetId: Uri.decodeComponent(m.group(3)!),
      draft: draft,
      space: space,
      wall: wall,
    );
  }

  /// 給 openLink 用的攔截器。回傳 true = 已處理（不要再開外部瀏覽器）。
  bool handleLink(String url) {
    final p = parseLink(url);
    if (p == null) return false;
    unawaited(_run(p.caseNo, p.roomId, p.closetId, p.draft, p.space, p.wall));
    return true;
  }

  /// 建單後自動存檔（不開畫面）：使用者已經確認建立訂單（按按鈕或說「確認建立」），
  /// 所以在看不見的背景配置頁 [bg] 載入剛建立的案件櫃組、套入草稿的櫃子、算好價格後
  /// 直接「更新詢單」寫進案件，不用再點連結到網頁按。
  /// 連結不是「更新詢單」格式回傳 null（照舊讓使用者點）。結束後關掉背景頁，
  /// 之後已選清單有東西時會重新開來試算。
  Future<({bool ok, String message, num? price})?> autoSave(
      String url, CabinetWebController bg) async {
    final p = parseLink(url);
    if (p == null) return null;
    ({bool ok, String message, num? price}) fail(String m) =>
        (ok: false, message: m, price: null);
    try {
      await bg.openCase(p.caseNo, roomId: p.roomId, closetId: p.closetId);
      final draft = await _getDraft(p.draft);
      final (cabinets, ids) = _pickNewCabinets(draft, p.space, p.wall);
      if (cabinets.isEmpty) return fail('草稿這面牆沒有要新增的柜子');
      if (!await bg.waitUntilReady()) return fail('網頁載入逾時');
      final r = await bg.applyDraft({'cabinets': cabinets}, clear: false);
      if (r['ok'] != true) {
        final missing = (r['missing'] as List?)?.join('、');
        return fail(missing != null && missing.isNotEmpty
            ? '這些品號在網頁找不到：$missing'
            : '${r['message'] ?? '套入櫃子失敗'}');
      }
      await bg.waitSettled();
      // 網頁還在算價或資料還沒載完會回「請稍候」：每 3 秒再試，最多約 2 分鐘
      var s = <String, dynamic>{};
      for (var i = 0; i < 40; i++) {
        s = await bg.updateCase();
        if (s['ok'] == true) break;
        if (!'${s['message'] ?? ''}'.contains('稍候')) break;
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      if (s['ok'] != true) return fail('${s['message'] ?? '存檔失敗'}');
      // 已存進案件：把這批柜子從 MCP 草稿移除（失敗不影響已存的案件）
      unawaited(_markApplied(p.draft, ids));
      return (ok: true, message: '', price: s['price'] as num?);
    } catch (e) {
      return fail(_reason(e));
    } finally {
      bg.close();
    }
  }

  /// 建單後直接存（最快）：背景頁 [bg] 已經把這張訂單的櫃子組好、算好價格了（建單前一直在試算），
  /// 所以不重新載入案件，直接叫它把算好的櫃子存進剛建立的案件櫃組。
  /// 呼叫端要先確認背景頁算的清單就是這張訂單（[orderMatchesPicked]）。
  /// 回傳 fallback=true 代表還沒寫進資料庫就停了，可以改走 [autoSave]（重新載入）；
  /// fallback=false 又失敗代表寫到一半，不能自動重存（可能會重複），只能讓使用者手動開。
  /// 連結不是「更新詢單」格式回傳 null。
  Future<({bool ok, bool fallback, String message, num? price})?> saveDirect(
      String url, CabinetWebController bg) async {
    final p = parseLink(url);
    if (p == null) return null;
    ({bool ok, bool fallback, String message, num? price}) back(String m) =>
        (ok: false, fallback: true, message: m, price: null);
    try {
      if (!bg.isOpen || bg.error != null) return back('背景頁沒有開著');
      final draft = await _getDraft(p.draft);
      final (cabinets, ids) = _pickNewCabinets(draft, p.space, p.wall);
      if (cabinets.isEmpty) return back('草稿這面牆沒有要新增的柜子');
      final s = await bg.saveToCase(
        caseNo: p.caseNo,
        roomId: p.roomId,
        closetId: p.closetId,
        closetName: _wallName(draft, p.space, p.wall),
      );
      if (s['ok'] != true) {
        final msg = '${s['message'] ?? '存檔失敗'}';
        if (s['stage'] != 'save') return back(msg);
        bg.close();
        return (ok: false, fallback: false, message: msg, price: null);
      }
      // 已存進案件：把這批柜子從 MCP 草稿移除（失敗不影響已存的案件）
      unawaited(_markApplied(p.draft, ids));
      // 背景頁的櫃子已經編成這個案號了，關掉；之後再挑櫃子會重新開來試算
      bg.close();
      return (ok: true, fallback: false, message: '', price: s['price'] as num?);
    } catch (e) {
      // 呼叫本身出錯（網頁沒回應）：不知道有沒有寫進去，不自動重存
      bg.close();
      return (ok: false, fallback: false, message: _reason(e), price: null);
    }
  }

  /// 草稿裡這面牆的名稱（存檔時帶給網頁，櫃組名稱才不會被改成預設的「櫃組 1」）
  static String? _wallName(dynamic draft, String spaceId, String wallId) {
    if (draft is! Map) return null;
    for (final s in (draft['spaces'] as List? ?? const [])) {
      if (s is! Map || '${s['localId']}' != spaceId) continue;
      for (final w in (s['walls'] as List? ?? const [])) {
        if (w is Map && '${w['localId']}' == wallId) {
          final n = '${w['wallName'] ?? ''}'.trim();
          return n.isEmpty ? null : n;
        }
      }
    }
    return null;
  }

  Future<void> _run(String caseNo, String roomId, String closetId,
      String draftId, String spaceId, String wallId) async {
    _draftId = null;
    _appliedIds = const [];
    await _ctrl.openCase(caseNo, roomId: roomId, closetId: closetId);

    // 先取草稿（和網頁載入同時進行），再等網頁就緒
    List<Map<String, dynamic>> cabinets;
    List<String> ids;
    try {
      final draft = await _getDraft(draftId);
      (cabinets, ids) = _pickNewCabinets(draft, spaceId, wallId);
    } catch (e) {
      _ctrl.onLoadError('取得草稿失敗：${_reason(e)}');
      return;
    }
    if (cabinets.isEmpty) {
      _ctrl.onLoadError('草稿這面牆沒有要新增的柜子');
      return;
    }

    if (!await _ctrl.waitUntilReady()) {
      _ctrl.onLoadError('網頁載入逾時，無法套入草稿');
      return;
    }
    // clear=false：保留案件裡原本就有的櫃體，只加草稿新增的
    final r = await _ctrl.applyDraft({'cabinets': cabinets}, clear: false);
    if (r['ok'] != true) {
      final missing = (r['missing'] as List?)?.join('、');
      _ctrl.onLoadError(missing != null && missing.isNotEmpty
          ? '這些品號在網頁找不到：$missing'
          : '${r['message'] ?? '套入草稿失敗'}');
      // 部分成功的也記下來，使用者仍可決定要不要存
    }
    _draftId = draftId;
    _appliedIds = ids;
    await _ctrl.refreshState();
  }

  /// 取出指定空間／牆面中「新增（Status = I）」的柜子，以及它們回報用的代號 space:wall:cabinet
  (List<Map<String, dynamic>>, List<String>) _pickNewCabinets(
      dynamic draft, String spaceId, String wallId) {
    final cabs = <Map<String, dynamic>>[];
    final ids = <String>[];
    if (draft is! Map) return (cabs, ids);
    for (final s in (draft['spaces'] as List? ?? const [])) {
      if (s is! Map || '${s['localId']}' != spaceId) continue;
      for (final w in (s['walls'] as List? ?? const [])) {
        if (w is! Map || '${w['localId']}' != wallId) continue;
        for (final c in (w['cabinets'] as List? ?? const [])) {
          if (c is! Map || c['status'] != 'I') continue;
          cabs.add(Map<String, dynamic>.from(c));
          ids.add('$spaceId:$wallId:${c['localId']}');
        }
      }
    }
    return (cabs, ids);
  }

  void _onEvent(CabinetEvent e) {
    if (e.type != 'saved') return;
    final draftId = _draftId;
    if (draftId == null || _appliedIds.isEmpty) return;
    if (e.data['updated'] != true) return;
    final ids = _appliedIds;
    _draftId = null;
    _appliedIds = const [];
    // 存檔成功：把這批柜子從 MCP 草稿移除（失敗不影響已存的案件，使用者之後可手動清草稿）
    unawaited(_markApplied(draftId, ids));
  }
}
