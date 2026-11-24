/// 房間的四面牆。以使用者「面對後牆」為固定視角：
/// 沒特別說＝後牆（正對面）、左邊＝左牆、右邊＝右牆、後面（背後）＝前牆。
/// 跟網頁（roomPlan.js）的 back／left／right／front 一致。
const wallLabels = <String, String>{
  'back': '後牆',
  'left': '左牆',
  'right': '右牆',
  'front': '前牆',
};

/// 牆面代號正規化：back／left／right／front，也容忍中文（後牆、左牆、右牆、前牆、左邊、右邊…）。
/// 認不得（或沒給）回傳 null，代表用預設（後牆）。
/// 這只是把工具參數整理成固定代號，要不要放哪一面是 AI 依使用者說的話判斷（MCP 的 pick_product）。
String? normalizeWall(Object? v) {
  final s = '${v ?? ''}'.trim().toLowerCase();
  const alias = <String, String>{
    'back': 'back', '後牆': 'back', '後': 'back', '後面': 'back',
    'left': 'left', '左牆': 'left', '左': 'left', '左邊': 'left',
    'right': 'right', '右牆': 'right', '右': 'right', '右邊': 'right',
    'front': 'front', '前牆': 'front', '前': 'front',
  };
  return alias[s];
}

/// 給人看的牆名；後牆（預設）和沒指定都回傳空字串，不用特別標出來
String wallTagOf(String? wall) =>
    (wall == null || wall == 'back') ? '' : (wallLabels[wall] ?? '');
