import 'dart:async';
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import '../../services/web_session.dart';
import 'cabinet_sync.dart';
import 'cabinet_transport.dart';
import 'wall.dart';

/// 視窗的顯示狀態
/// - hidden：關閉
/// - docked：嵌在聊天的文字對話區裡（預設，只佔那一塊）
/// - full：全螢幕
/// - mini：右下角的小浮動視窗
enum CabinetPanelMode { hidden, docked, mini, full }

/// 使用者在挑選頁選的一項產品
class PickedItem {
  final String productNo;
  final String name;
  final int quantity;

  /// 使用者在挑選畫面動過的規格 { 規格名稱: 值 }，例如 { width: 600, direction: 'L' }
  final Map<String, dynamic> specs;

  /// 使用者沒動、但挑選畫面上顯示的網站預設值 { 規格名稱: 值 }，例如 { marginB: 0 }。
  /// 也要送給 AI（伺服器對有些規格沒有預設值，不帶會被問「請選擇後縮」）。
  final Map<String, dynamic> defaults;

  /// 給人看的規格文字，例如「寬度 60公分・開門方向 左開門」
  final String specText;

  /// 必填但還沒選的規格名稱（可以之後用講的補）
  final List<String> missing;

  /// 系統櫃配置頁實際回報的規格值（含預設值），key 是規格名稱。
  /// 有值代表已經跟網站核對過（[verified]），給人看的文字和給 AI 的參數都以它為準。
  final Map<String, dynamic> actual;
  bool get verified => actual.isNotEmpty;

  /// 要放在哪面牆（back／left／right／front）。null＝沒指定，預設後牆。
  /// 由 AI 依使用者說的方位指定（沒說後牆、左邊＝左牆、右邊＝右牆、後面＝前牆）。
  final String? wall;

  const PickedItem(
    this.productNo,
    this.name,
    this.quantity, {
    this.specs = const {},
    this.defaults = const {},
    this.specText = '',
    this.missing = const [],
    this.actual = const {},
    this.wall,
  });

  PickedItem withQuantity(int q) => PickedItem(productNo, name, q,
      specs: specs,
      defaults: defaults,
      specText: specText,
      missing: missing,
      actual: actual,
      wall: wall);

  /// 套上配置頁回報的實際值：規格文字改成實際值、不再有「還沒選」
  PickedItem withActual(Map<String, dynamic> actual, String text) =>
      PickedItem(productNo, name, quantity,
          specs: specs,
          defaults: defaults,
          specText: text,
          missing: const [],
          actual: actual,
          wall: wall);

  /// 給聊天輸入列／訊息用的文字，例如「A01 單門衣櫃 ×2（右牆・寬度 60公分・開門方向 左開門）」。
  /// 放在後牆（預設）不標牆名，只有指定其他牆才標，讓使用者確認 AI 聽對了方位。
  String get label {
    final tag = wallTagOf(wall);
    final extra = [if (tag.isNotEmpty) tag, if (specText.isNotEmpty) specText].join('・');
    return '$productNo $name ×$quantity${extra.isEmpty ? '' : '（$extra）'}';
  }

  /// 給 AI 的描述：除了給人看的文字，還附上原樣的規格參數（規格名稱=值），
  /// AI 直接帶進下單工具，不用再問、也不會自己編
  String get forAi {
    final parts = <String>[label];
    // 優先順序（後面蓋前面）：挑選畫面的網站預設 < 配置頁核對過的實際值 < 使用者改過的
    final params = {...defaults, if (verified) ...actual, ...specs};
    if (params.isNotEmpty) {
      parts.add('規格參數 ${params.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
    }
    if (missing.isNotEmpty) parts.add('還沒選：${missing.join('、')}');
    return parts.join('；');
  }

  /// 同樣的產品、同樣的規格、同一面牆才能合併數量
  bool sameAs(PickedItem o) =>
      productNo == o.productNo &&
      mapEquals(specs, o.specs) &&
      (wall ?? 'back') == (o.wall ?? 'back');
}

/// 網頁（window.cabinetBridge）發出的事件
class CabinetEvent {
  final String type; // ready／stateChanged／quoteUpdated／saved／error
  final Map<String, dynamic> data;
  const CabinetEvent(this.type, this.data);
}

/// 控制內嵌的系統櫃網頁（/app/store/cabinet-config?embed=1）。
///
/// App 端負責：開關視窗、登入網頁、呼叫 window.cabinetBridge 的方法、接收網頁事件。
/// 網頁端的對應介面見 tachenfurniture.client/src/utils/cabinetBridge.js。
/// 容器（原生 WebView 或 Chrome 的 iframe）透過 [CabinetTransport] 接進來，
/// 登入與橋接邏輯在這裡只有一份。
class CabinetWebController extends ChangeNotifier {
  /// [background] = true：看不見的背景頁，只負責算預設值和報價，不顯示視窗
  /// （由 CabinetBackgroundHost 把網頁掛在畫面上，但完全透明、不能點）
  CabinetWebController(this._session, {this.background = false});

  final bool background;

  final WebSession _session;

  CabinetPanelMode mode = CabinetPanelMode.hidden;

  /// 每次重新開啟換一個 key，讓容器重建（重新載入頁面）
  Key webKey = UniqueKey();
  Uri? targetUri;
  CabinetTransport? transport;

  /// 聊天的文字對話區在螢幕上的位置（由 DockRegion 回報）。
  /// docked 模式的視窗會貼在這個範圍裡；沒有（聊天頁不在畫面上）就改成全螢幕。
  Rect? _dockRect;
  Object? _dockOwner;
  Rect? get dockRect => _dockRect;

  bool pageReady = false;
  bool loading = false;
  String? error;
  num? price;
  int cabinetCount = 0;
  String? caseNo;
  Map<String, dynamic>? lastSaved;

  bool _loginTried = false;
  int _bridgeWaitToken = 0;

  /// 目前開的是「挑選產品」頁（沒有橋接，只收 picked 事件）
  bool pickMode = false;
  Completer<List<PickedItem>?>? _pickCompleter;

  /// AI 判斷出使用者要哪個產品後，要在挑選頁預先選好的內容：
  /// { items: [{productNo, quantity, specs}], candidates: [productNo], autoAdd }
  Map<String, dynamic>? _pickPreselect;

  /// 目前開的是「修改待確認訂單」頁（App 載入後把訂單交進去，改好用 orderEdited 事件回傳）
  bool editMode = false;
  Completer<Map<String, dynamic>?>? _editCompleter;
  Map<String, dynamic>? _orderToLoad;

  /// 這兩種都是公開的小頁面：不需要登入，不縮成小視窗
  bool get lightPage => pickMode || editMode;

  final _events = StreamController<CabinetEvent>.broadcast();
  Stream<CabinetEvent> get events => _events.stream;

  bool get isOpen => mode != CabinetPanelMode.hidden;

  /// 實際顯示的樣子：docked 但找不到文字對話區的位置時，改用全螢幕
  CabinetPanelMode get effectiveMode =>
      (mode == CabinetPanelMode.docked && _dockRect == null)
          ? CabinetPanelMode.full
          : mode;

  /// DockRegion 回報文字對話區的位置（改變才通知）
  void setDockRect(Object owner, Rect rect) {
    if (_dockOwner == owner && _dockRect == rect) return;
    _dockOwner = owner;
    _dockRect = rect;
    if (isOpen) notifyListeners();
  }

  /// DockRegion 被移除時清掉（只清自己設的，避免誤清新的那個）
  void clearDockRect(Object owner) {
    if (_dockOwner != owner) return;
    _dockOwner = null;
    _dockRect = null;
    if (isOpen) notifyListeners();
  }
  bool get isEditingCase => (caseNo ?? '').isNotEmpty;

  /// 挑選／修改訂單的視窗開著、而且網頁準備好了：使用者講的話要交給網頁操作畫面，
  /// 不是送給 AI 聊天
  bool get acceptsVoice => isOpen && lightPage && pageReady;

  /// 把使用者講的話交給網頁（選規格、選產品、下一步、加入、取消…），畫面會當場照做。
  /// 回傳網頁的 {ok, handled, applied:[...]}
  Future<Map<String, dynamic>> voiceCommand(String text) => call('voice', [text]);

  // ── 開關 ────────────────────────────────────────────────

  /// 開新案件的配置畫面。帶 [cabinets]（聊天裡已選的櫃子）會在網頁就緒後灌進場景，
  /// 之後已選清單有變動可以再呼叫 [syncCabinets] 同步。
  Future<void> openNew({List<PickedItem> cabinets = const []}) async {
    final uri = _session.cabinetConfigUri();
    final wasOpen = isOpen && targetUri == uri;
    _initialCabinets = cabinets.isEmpty ? null : List.of(cabinets);
    await _open(uri);
    if (wasOpen) {
      // 已經開著：不會重新載入，直接同步
      final init = _initialCabinets;
      _initialCabinets = null;
      if (init != null) unawaited(syncCabinets(init));
      unawaited(_applyPrefillOrderInfo());
    }
  }

  /// 開配置頁時要預填到「建立詢單」視窗的案件欄位（例如 { 'Customer': '阿名' }），
  /// 由聊天頁在開啟前設定。網頁就緒後套用一次。
  Map<String, dynamic>? prefillOrderInfo;

  /// 網頁按「發送到聊天」時呼叫：帶配置畫面的櫃子（含位置）和填的案件欄位。
  /// 聊天頁用它組成一則訊息送給 AI。
  void Function(Map<String, dynamic> data)? onSendToChat;

  Future<void> _applyPrefillOrderInfo() async {
    final pre = prefillOrderInfo;
    if (pre == null) return;
    final r = await call('setOrderInfo', [pre]);
    if (r['ok'] != true) debugPrint('⚠️ 預填案件欄位失敗：${r['message']}');
  }

  /// 開啟配置頁時要灌進去的櫃子（網頁橋接就緒後套用一次）
  List<PickedItem>? _initialCabinets;
  bool _syncing = false;
  List<PickedItem>? _pendingSync;

  // ── 反向同步（配置頁 → 聊天的已選清單）──
  /// 配置頁裡的櫃子有被使用者加、刪、改尺寸／規格時呼叫，帶最新的已選清單
  void Function(List<PickedItem> items)? onCabinetsChanged;

  /// 最近一次灌進去（或回報）後，網頁的櫃子狀態；之後有差異才算使用者在網頁改了
  Map<String, ConfigCabinet> _baseline = {};

  /// 網頁的每顆櫃子（uuid）對應到哪個已選品項
  Map<String, PickedItem> _sources = {};
  List<PickedItem> _lastPicked = const [];
  Timer? _reverseTimer;

  void _scheduleReverse() {
    if (onCabinetsChanged == null) return;
    if (!pageReady || pickMode || editMode || caseNo != null) return;
    _reverseTimer?.cancel();
    // 等網頁穩定（拖曳、算價途中不讀）
    _reverseTimer = Timer(const Duration(milliseconds: 1200), _reverseSync);
  }

  Future<void> _reverseSync() async {
    final cb = onCabinetsChanged;
    if (cb == null || !pageReady || pickMode || editMode || caseNo != null) {
      return;
    }
    if (_syncing || _pendingSync != null) return; // 正向同步中，事件是自己引起的
    try {
      final s = await getState();
      if (s['ok'] != true) return;
      if (s['busy'] == true || s['quoting'] == true) {
        _scheduleReverse(); // 還在忙，晚點再讀
        return;
      }
      if (_syncing || _pendingSync != null) return;
      final current = parseConfigCabinets(s['cabinets']);
      if (configSignature(current) == configSignature(_baseline.values)) {
        return; // 跟上次一樣：沒有人動
      }
      final r = pickedFromConfig(
        current: current,
        baseline: _baseline,
        sources: _sources,
        previous: _lastPicked,
      );
      _baseline = {for (final c in current) c.uuid: c};
      _sources = r.sources;
      _lastPicked = r.items;
      cb(r.items);
    } catch (e) {
      debugPrint('⚠️ 配置頁 → 已選清單同步失敗：$e');
    }
  }

  static Map<String, dynamic> _draftCabinet(PickedItem p) => {
        'productNo': p.productNo,
        'quantity': p.quantity,
        // 規格名稱跟網頁一致（width／height／depth／direction／marginB…），整包當覆蓋值
        'params': p.specs,
        // 要放哪面牆；沒指定就不帶，網頁用預設的自動擺放（後牆）
        if (p.wall != null) 'wall': p.wall,
      };

  /// 把聊天裡已選的櫃子同步進配置頁（整份取代場景裡的櫃體，只改網頁畫面，不寫資料庫）。
  /// 配置頁沒開、還沒就緒、或開的是挑選／修改／既有案件頁就略過。
  /// 同步中又有新變動時只保留最新一份，做完再接著同步。
  Future<void> syncCabinets(List<PickedItem> items) async {
    if (pickMode || editMode || caseNo != null) return;
    if (!pageReady) {
      // 背景頁還在載入：記下最新一份，網頁就緒後會自動同步
      if (background && isOpen) {
        _initialCabinets = items.isEmpty ? null : List.of(items);
        notifyListeners();
      }
      return;
    }
    _pendingSync = List.of(items);
    if (_syncing) return;
    _syncing = true;
    final gen = _syncGen;
    notifyListeners();
    try {
      while (_pendingSync != null) {
        final next = _pendingSync!;
        _pendingSync = null;
        if (!pageReady || gen != _syncGen) return; // 同步途中視窗被關掉或重開
        // 背景頁：清單變空不用為了「空場景」重新載入網頁（下次有櫃子才會載入）
        if (background && next.isEmpty) continue;
        if (background && _appliedOnce) {
          // 背景頁已經放過櫃子：網頁在「清空再重放」之後報價會卡住（價格一直是 0、
          // 讀不到規格值），所以改成重新載入網頁，讓它像第一次一樣從空場景開始
          await _reloadForSync(next);
          return;
        }
        final relayout = relayoutOnNextSync;
        relayoutOnNextSync = false;
        final r = await applyDraft(
            {'cabinets': [for (final p in next) _draftCabinet(p)]},
            clear: true,
            relayout: relayout);
        if (r['ok'] != true) {
          final missing = (r['missing'] as List?)?.join('、') ?? '';
          error = missing.isNotEmpty
              ? '網頁找不到品號：$missing'
              : '${r['message'] ?? '同步櫃子失敗'}';
          notifyListeners();
        }
        if (next.isNotEmpty) _appliedOnce = true;
        // 記住網頁每顆櫃子對應哪個已選品項，並把網頁現在的狀態當基準（反向同步比對用）
        final added = <({String uuid, String productNo})>[
          if (r['added'] is List)
            for (final a in r['added'] as List)
              if (a is Map)
                (uuid: '${a['uuid']}', productNo: '${a['productNo']}'),
        ];
        _sources = assignSources(added, next);
        _lastPicked = next;
        final s = await _readSettledState(expectCabinets: next.isNotEmpty);
        if (s['ok'] == true) {
          price = s['price'] as num? ?? price;
          final cabinets = parseConfigCabinets(s['cabinets']);
          if (background && kDebugMode) {
            // 診斷（只在除錯版）：背景頁每顆櫃子回報了幾個規格值
            final raw = s['cabinets'];
            debugPrint('🔎 背景頁同步完：price=${s['price']} busy=${s['busy']} '
                'quoting=${s['quoting']} 櫃子=${raw is List ? raw.length : '?'} '
                '解析=${cabinets.length} added=${added.length} '
                '各櫃規格數=${cabinets.map((c) => '${c.productNo}:${actualSpecs(c).length}').join(',')} '
                '原始props=${raw is List ? raw.map((c) => c is Map && c['props'] is List ? (c['props'] as List).length : -1).join(',') : '?'}');
          }
          cabinetCount = cabinets.length;
          _baseline = {for (final c in cabinets) c.uuid: c};
          notifyListeners();
          // 同步完才回報（途中又有新變動就等最後一份）：網頁實際的規格值（含預設）和價格
          if (_pendingSync == null) {
            onSynced?.call(next, _sources, cabinets);
          }
        }
      }
    } catch (e) {
      debugPrint('⚠️ 同步櫃子到配置頁失敗：$e');
    } finally {
      // 網頁已被關掉或重開（世代變了）：旗標已被重設、新的同步可能已在跑，不要動它
      if (gen == _syncGen) _syncing = false;
      notifyListeners();
    }
  }

  /// 每次關閉或重新載入網頁就加一；舊網頁上卡住的同步不能再擋住新的同步
  int _syncGen = 0;

  /// 作廢進行中的同步（網頁被關掉或換了新頁面）
  void _abandonSync() {
    _syncGen++;
    _syncing = false;
    _pendingSync = null;
  }

  /// 背景頁是否已經放過櫃子（放過之後再同步要重新載入網頁）
  bool _appliedOnce = false;

  /// 重新載入背景網頁，網頁就緒後自動把 [items] 灌進去（走 _initialCabinets 那條已驗證的路）
  Future<void> _reloadForSync(List<PickedItem> items) async {
    final t = transport;
    final uri = targetUri;
    if (t == null || uri == null) return;
    _initialCabinets = items.isEmpty ? null : List.of(items);
    _appliedOnce = false;
    pageReady = false;
    loading = true;
    _baseline = {};
    _sources = {};
    _bridgeWaitToken++;
    notifyListeners();
    await t.reload(uri);
  }

  /// 灌進櫃子之後讀網頁狀態。applyDraft 回來時網頁常常還在重算（尤其是整份取代之後，
  /// 會先被「清空」那一次的報價提早放行）：價格是 0、或讀不到規格值，就每 2 秒重讀，
  /// 最多 60 秒，直到有價格也有規格。途中又有新的同步排隊就不等了。
  Future<Map<String, dynamic>> _readSettledState(
      {required bool expectCabinets}) async {
    var s = await getState();
    if (!expectCabinets) return s;
    for (var i = 0; i < 30; i++) {
      if (_pendingSync != null || !pageReady) return s;
      final price = s['price'];
      final cabinets = parseConfigCabinets(s['cabinets']);
      final settled = s['ok'] == true &&
          s['busy'] != true &&
          s['quoting'] != true &&
          price is num &&
          price > 0 &&
          cabinets.isNotEmpty &&
          cabinets.every((c) => actualSpecs(c).isNotEmpty);
      if (background && kDebugMode) {
        debugPrint('🔎 等網頁穩定 #$i：price=$price 規格數='
            '${cabinets.map((c) => actualSpecs(c).length).join(',')} 穩定=$settled');
      }
      if (settled) return s;
      await Future<void>.delayed(const Duration(seconds: 2));
      s = await getState();
    }
    return s;
  }

  /// 每次把已選清單灌進配置頁、並讀回網頁狀態之後呼叫：
  /// (灌進去的清單, 網頁每顆櫃子對應哪個品項, 網頁現在的櫃子與實際規格值)
  void Function(List<PickedItem> synced, Map<String, PickedItem> sources,
      List<ConfigCabinet> cabinets)? onSynced;

  /// 同步進行中，或背景頁還在載入、等著同步（畫面顯示「試算中」）
  bool get syncBusy =>
      _syncing ||
      _pendingSync != null ||
      _bgLatest != null ||
      (background && isOpen && error == null && (!pageReady || _initialCabinets != null));

  /// 背景報價頁：第一次需要時才載入網頁，之後直接同步。
  /// 已選清單變空而且網頁還沒開，就不用開。
  Future<void> syncBackground(List<PickedItem> items) async {
    if (!background) return;
    if (!isOpen) {
      if (items.isEmpty) return;
      await openNew(cabinets: items);
      return;
    }
    // 連續按 ＋／－：每次只記下最新一份，靜止 1.5 秒才開始算（一輪要約 1 分鐘，
    // 不要為中途的數字白算）
    _bgLatest = List.of(items);
    _bgDebounce?.cancel();
    notifyListeners(); // 讓畫面立刻顯示「試算中…」
    _bgDebounce = Timer(const Duration(milliseconds: 1500), () {
      final latest = _bgLatest;
      _bgLatest = null;
      _bgDebounce = null;
      if (latest != null) unawaited(syncCabinets(latest));
    });
  }

  Timer? _bgDebounce;
  List<PickedItem>? _bgLatest;

  /// 編輯既有案件（案號／空間／櫃組）
  Future<void> openCase(String caseNo,
          {String roomId = 'A', String closetId = '1'}) =>
      _open(_session.cabinetConfigUri(
          caseNo: caseNo, roomId: roomId, closetId: closetId));

  /// 開挑選畫面（產品目錄）讓使用者選櫃子。
  /// 選好回傳清單；按取消或關掉視窗回傳 null。
  Future<List<PickedItem>?> pickProducts({Map<String, dynamic>? preselect}) async {
    // 上一次還沒結束就當作取消
    final prev = _pickCompleter;
    if (prev != null && !prev.isCompleted) prev.complete(null);
    final c = _pickCompleter = Completer<List<PickedItem>?>();
    _pickPreselect = preselect;
    await _open(_session.pickerUri());
    return c.future;
  }

  /// 開「修改訂單」畫面，把待確認的訂單（quick_order 的參數）交給網頁讓使用者改。
  /// 按「套用修改」回傳改好的訂單；關掉視窗回傳 null（不改）。
  Future<Map<String, dynamic>?> editOrder(Map<String, dynamic> order) async {
    final prev = _editCompleter;
    if (prev != null && !prev.isCompleted) prev.complete(null);
    final c = _editCompleter = Completer<Map<String, dynamic>?>();
    _orderToLoad = Map<String, dynamic>.from(order);
    await _open(_session.orderEditUri());
    return c.future;
  }

  void _finishEdit(Map<String, dynamic>? order) {
    final c = _editCompleter;
    _editCompleter = null;
    _orderToLoad = null;
    if (c != null && !c.isCompleted) c.complete(order);
    if (editMode) close();
  }

  void _finishPick(List<PickedItem>? items) {
    final c = _pickCompleter;
    _pickCompleter = null;
    _pickPreselect = null;
    if (c != null && !c.isCompleted) c.complete(items);
    if (pickMode) close();
  }

  Future<void> _open(Uri uri) async {
    // 已經開著同一頁：直接展開，不重新載入
    if (isOpen && targetUri == uri && !uri.queryParameters.containsKey('mode')) {
      expand();
      return;
    }
    _abandonSync();
    targetUri = uri;
    pickMode = uri.queryParameters['mode'] == 'pick';
    editMode = uri.queryParameters['mode'] == 'edit';
    caseNo = uri.queryParameters['caseNo'];
    webKey = UniqueKey();
    transport = null;
    pageReady = false;
    loading = true;
    error = null;
    price = null;
    cabinetCount = 0;
    lastSaved = null;
    _loginTried = false;
    _appliedOnce = false;
    _bridgeWaitToken++;
    // 預設只佔聊天的文字對話區；找不到那一塊（不在聊天頁）才用全螢幕。
    // 背景頁不顯示視窗，只要「不是 hidden」代表開著
    mode = background
        ? CabinetPanelMode.mini
        : (_dockRect != null ? CabinetPanelMode.docked : CabinetPanelMode.full);
    notifyListeners();
  }

  /// 放大成全螢幕
  void expand() {
    if (mode == CabinetPanelMode.hidden) return;
    mode = CabinetPanelMode.full;
    notifyListeners();
  }

  /// 縮回聊天的文字對話區（找不到那一塊就縮成小視窗）
  void dock() {
    if (mode == CabinetPanelMode.hidden) return;
    // 挑選頁、修改頁要操作，找不到文字對話區時維持全螢幕，不縮成小視窗
    mode = _dockRect != null
        ? CabinetPanelMode.docked
        : (lightPage ? CabinetPanelMode.full : CabinetPanelMode.mini);
    notifyListeners();
  }

  /// 縮成右下角小視窗（挑選畫面要操作，不縮小窗，改縮回文字對話區）
  void minimize() {
    if (mode == CabinetPanelMode.hidden) return;
    if (lightPage) {
      dock();
      return;
    }
    mode = CabinetPanelMode.mini;
    notifyListeners();
  }

  /// 點小視窗：回到文字對話區
  void restore() => dock();

  void close() {
    // 挑選中被關掉 = 取消
    final c = _pickCompleter;
    _pickCompleter = null;
    _pickPreselect = null;
    if (c != null && !c.isCompleted) c.complete(null);
    pickMode = false;
    // 修改訂單中被關掉 = 不改
    final e = _editCompleter;
    _editCompleter = null;
    _orderToLoad = null;
    if (e != null && !e.isCompleted) e.complete(null);
    editMode = false;
    _initialCabinets = null;
    _abandonSync();
    _reverseTimer?.cancel();
    _bgDebounce?.cancel();
    _bgLatest = null;
    _baseline = {};
    _sources = {};
    mode = CabinetPanelMode.hidden;
    transport = null;
    pageReady = false;
    loading = false;
    _bridgeWaitToken++;
    notifyListeners();
  }

  // ── 容器事件（由 CabinetOverlay／iframe 轉進來）──────────────

  void attachTransport(CabinetTransport t) {
    transport = t;
  }

  /// 頁面載入完成（原生 WebView 的 onLoadStop／iframe 的 load）
  Future<void> onPageLoaded() async {
    final t = transport;
    if (t == null) return;
    // 第一次載入完：確認網頁已登入，沒登入就用 MCP 登入時記下的工號密碼登入，再重載
    // 挑選頁、修改訂單頁是公開頁，不需要登入
    if (!_loginTried && !lightPage) {
      _loginTried = true;
      final needReload = await _ensureWebLogin(t);
      if (needReload) {
        final uri = targetUri;
        if (uri != null) await t.reload(uri);
        return;
      }
    }
    loading = false;
    notifyListeners();
    unawaited(_waitForBridge());
  }

  void onLoadError(String message) {
    loading = false;
    error = message;
    notifyListeners();
  }

  /// 回傳 true = 剛登入成功，需要重新載入頁面讓網頁抓到登入狀態
  Future<bool> _ensureWebLogin(CabinetTransport t) async {
    try {
      if (await t.hasSession()) return false;
      final cred = _session.credentials;
      if (cred == null) {
        // 沒有記下帳密：不處理，使用者可以直接在視窗裡的網頁登入畫面自己登入
        return false;
      }
      final r = await t.signIn(cred.userId, cred.password);
      if (r['ok'] == true) return true;
      error = '網頁登入失敗：${r['message'] ?? '未知原因'}';
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('⚠️ 網頁登入檢查失敗：$e');
      return false;
    }
  }

  /// 等網頁把 window.cabinetBridge 掛上來（使用者手動登入的話可能要等很久）
  Future<void> _waitForBridge() async {
    final token = ++_bridgeWaitToken;
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (token == _bridgeWaitToken && DateTime.now().isBefore(deadline)) {
      final t = transport;
      if (t == null) return;
      try {
        if (await t.hasBridge()) {
          // 讓網頁開始初始化（編輯既有案件時會在這裡載入櫃體），等它回報完成
          final ready = await call('whenReady');
          if (token != _bridgeWaitToken) return;
          if (ready['ok'] == true) {
            pageReady = true;
            final order = _orderToLoad;
            if (editMode && order != null) {
              final r = await call('loadOrder', [order]);
              if (r['ok'] != true) {
                error = '${r['message'] ?? '載入訂單失敗'}';
                notifyListeners();
              }
            } else if (pickMode) {
              // AI 已經判斷出使用者要哪個產品：先把畫面選好（只改畫面上的選擇，不會建立任何東西）
              final pre = _pickPreselect;
              if (pre != null) {
                final r = await call('preselect', [pre]);
                if (r['ok'] != true) {
                  error = '${r['message'] ?? '預先選好失敗'}';
                  notifyListeners();
                }
              }
              notifyListeners();
            } else {
              // 從聊天打開配置頁：先預填案件欄位，再把已選的櫃子灌進場景
              await _applyPrefillOrderInfo();
              final init = _initialCabinets;
              _initialCabinets = null;
              if (init != null) {
                await syncCabinets(init);
              } else {
                await refreshState();
              }
            }
          } else {
            error = '${ready['message'] ?? '網頁初始化失敗'}';
            notifyListeners();
          }
          return;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// 網頁事件（原生：JS handler；Chrome：postMessage）
  void onBridgeEvent(Map<String, dynamic> payload) {
    final type = '${payload['type']}';
    final data = payload['data'] is Map
        ? Map<String, dynamic>.from(payload['data'] as Map)
        : <String, dynamic>{};
    switch (type) {
      case 'stateChanged':
        cabinetCount = (data['cabinetCount'] as num?)?.toInt() ?? cabinetCount;
        _scheduleReverse();
        break;
      case 'quoteUpdated':
        price = data['price'] as num?;
        _scheduleReverse();
        break;
      case 'saved':
        lastSaved = data;
        break;
      case 'sendToChat':
        // 「發送到聊天」：不儲存案件，把櫃子排列交給聊天頁，視窗收起讓使用者看到聊天
        _events.add(CabinetEvent(type, data));
        onSendToChat?.call(data);
        close();
        return;
      case 'error':
        error = '${data['message'] ?? '網頁回報錯誤'}';
        break;
      case 'ready':
        pageReady = true;
        break;
      case 'picked':
        final raw = data['items'];
        final items = <PickedItem>[
          if (raw is List)
            for (final i in raw)
              if (i is Map && '${i['productNo']}'.isNotEmpty)
                PickedItem(
                  '${i['productNo']}',
                  '${i['name'] ?? ''}',
                  (i['quantity'] as num?)?.toInt() ?? 1,
                  specs: i['specs'] is Map
                      ? Map<String, dynamic>.from(i['specs'] as Map)
                      : const {},
                  defaults: i['defaults'] is Map
                      ? Map<String, dynamic>.from(i['defaults'] as Map)
                      : const {},
                  wall: normalizeWall(i['wall']),
                  specText: '${i['specText'] ?? ''}',
                  missing: i['missing'] is List
                      ? [for (final m in i['missing'] as List) '$m']
                      : const [],
                ),
        ];
        _events.add(CabinetEvent(type, data));
        _finishPick(items.isEmpty ? null : items);
        return;
      case 'orderEdited':
        _events.add(CabinetEvent(type, data));
        final o = data['order'];
        _finishEdit(o is Map ? Map<String, dynamic>.from(o) : null);
        return;
      case 'editCancelled':
        _events.add(CabinetEvent(type, data));
        _finishEdit(null);
        return;
      case 'pickCancelled':
        _events.add(CabinetEvent(type, data));
        _finishPick(null);
        return;
    }
    _events.add(CabinetEvent(type, data));
    notifyListeners();
  }

  /// 等網頁初始化完成（含既有案件的櫃體載入）。逾時回 false。
  Future<bool> waitUntilReady(
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (pageReady) return true;
      if (!isOpen) return false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return pageReady;
  }

  // ── 呼叫網頁橋接 ─────────────────────────────────────────

  /// 呼叫 window.cabinetBridge[method](...args)，回傳網頁給的 {ok, ...}。
  /// 網頁沒準備好或 JS 出錯時回 {ok:false, message}。
  Future<Map<String, dynamic>> call(String method,
      [List<dynamic> args = const []]) async {
    final t = transport;
    if (t == null) return {'ok': false, 'message': '網頁視窗還沒開啟'};
    return t.call(method, args);
  }

  Future<Map<String, dynamic>> getState() => call('getState');

  Future<Map<String, dynamic>> addCabinet(Map<String, dynamic> args) =>
      call('addCabinet', [args]);

  Future<Map<String, dynamic>> updateCabinet(
          dynamic ref, Map<String, dynamic> patch) =>
      call('updateCabinet', [ref, patch]);

  Future<Map<String, dynamic>> removeCabinet(dynamic ref) =>
      call('removeCabinet', [ref]);

  Future<Map<String, dynamic>> duplicateCabinet(dynamic ref) =>
      call('duplicateCabinet', [ref]);

  Future<Map<String, dynamic>> clearAll() => call('clearAll');

  /// 把 MCP 草稿（或 {cabinets:[...]}）灌進網頁。clear=false 時保留場景裡原有的櫃體。
  Future<Map<String, dynamic>> applyDraft(Object draft,
          {bool clear = true, bool relayout = false}) =>
      call('applyDraft', [
        draft,
        {'clear': clear, if (relayout) 'relayout': true}
      ]);

  /// 下一次同步要重新排位置（不還原手動位置）。AI 調整櫃子順序時設定，同步時用掉
  bool relayoutOnNextSync = false;

  /// 開啟網頁的「建立詢單」視窗（新案件）。orderInfo 可預填案件欄位。
  Future<Map<String, dynamic>> submitNew({Map<String, dynamic>? orderInfo}) =>
      call('submit', [
        {if (orderInfo != null) 'orderInfo': orderInfo}
      ]);

  /// 更新既有案件。**會直接寫入資料庫**，只能在使用者按下確認鈕之後呼叫。
  /// dryRun=true 只演練不寫入。
  Future<Map<String, dynamic>> updateCase({bool dryRun = false}) =>
      call('updateCase', [
        {'dryRun': dryRun}
      ]);

  /// 同步目前價格與櫃體數量（網頁事件沒有送到時用）
  Future<void> refreshState() async {
    final s = await getState();
    if (s['ok'] == true) {
      price = s['price'] as num? ?? price;
      cabinetCount = (s['cabinets'] as List?)?.length ?? cabinetCount;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _reverseTimer?.cancel();
    _events.close();
    super.dispose();
  }
}
