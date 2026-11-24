import 'wall.dart';

/// 配置頁按「發送到聊天」時，把畫面上的櫃子排列和填的案件欄位整理成兩份文字：
///
/// - [composeLayoutMessage]：**使用者看得到**的聊天訊息。只有誰是第幾個，不出現座標。
/// - [composeLayoutAiNote]：**只給 AI 看**的備註（牆面、順序、沿牆位置、座標、規格），畫面不顯示。
///
/// [data] 是網頁 `sendToChat` 事件的內容：
/// `{ orderInfo: {Customer...}, price, room: {width,depth,height}, cabinets: [...] }`。
/// 每個櫃子有 productNo／title／width／height／depth／props／remark，
/// 以及 wall（back/left/right/front/none，沒有房間資料時是 null）、along（沿牆位置 mm）、
/// pose {x,z,rotationDeg}。
///
/// 順序一律順時針（面對後牆，從上方看）：後牆由左到右 → 右牆由後往前 → 前牆由右到左 → 左牆由前往後。
/// 網頁已經依這個規則算好 along（後／前牆是左緣離左牆、左／右牆是後緣離後牆），這裡直接由小到大排。

/// 順時針（從上方看，後牆在上）：後牆 → 右牆 → 前牆 → 左牆
const _wallOrder = ['back', 'right', 'front', 'left'];

class _Cab {
  _Cab(this.raw, this.wall, this.along);
  final Map<String, dynamic> raw;

  /// back／left／right／front；null＝網頁沒給位置（當成沒有牆面資訊）；'none'＝不靠任何牆
  final String? wall;
  final num along;

  /// 這面牆上的第幾個（從 1 開始），[_arrange] 填入
  int order = 0;
}

/// 依牆面分組、組內由小到大排序，並填好每個櫃子在該牆的順序。
/// 回傳順序：後牆 → 左牆 → 右牆 → 前牆 → 不靠牆 → 沒有位置資料的。
List<_Cab> _arrange(Map<String, dynamic> data) {
  final cabs = <_Cab>[
    if (data['cabinets'] is List)
      for (final c in data['cabinets'] as List)
        if (c is Map)
          () {
            final m = Map<String, dynamic>.from(c);
            final w = normalizeWall(m['wall']) ??
                ('${m['wall']}' == 'none' ? 'none' : null);
            final along = (m['along'] is num)
                ? m['along'] as num
                : _poseAlong(m, w);
            return _Cab(m, w, along);
          }(),
  ];
  int rank(String? w) {
    final i = _wallOrder.indexOf(w ?? '');
    if (i >= 0) return i;
    return w == 'none' ? _wallOrder.length : _wallOrder.length + 1;
  }

  // 穩定排序：先看牆面，同一面牆再看沿牆位置；沒有位置資料的維持網頁給的順序
  final indexed = [for (var i = 0; i < cabs.length; i++) (i, cabs[i])];
  indexed.sort((a, b) {
    final r = rank(a.$2.wall).compareTo(rank(b.$2.wall));
    if (r != 0) return r;
    if (a.$2.wall == null) return a.$1.compareTo(b.$1);
    // 前牆、左牆的順時針方向與 along 增加的方向相反
    final rev = a.$2.wall == 'front' || a.$2.wall == 'left';
    final c = rev ? b.$2.along.compareTo(a.$2.along) : a.$2.along.compareTo(b.$2.along);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final sorted = [for (final e in indexed) e.$2];
  final counter = <String?, int>{};
  for (final c in sorted) {
    counter[c.wall] = (counter[c.wall] ?? 0) + 1;
    c.order = counter[c.wall]!;
  }
  return sorted;
}

/// 網頁沒給 along 時，用房間座標 pose 退而求其次（中心座標，不是邊緣，但排序夠用）
num _poseAlong(Map<String, dynamic> m, String? wall) {
  final p = m['pose'];
  if (p is Map) {
    final v = (wall == 'left' || wall == 'right') ? p['z'] : p['x'];
    if (v is num) return v;
  }
  return 0;
}

String _head(Map<String, dynamic> c) {
  final no = '${c['productNo'] ?? ''}'.trim();
  final title = '${c['title'] ?? ''}'.trim();
  final h = [if (no.isNotEmpty) no, if (title.isNotEmpty && title != no) title].join(' ');
  return h.isEmpty ? '（未命名）' : h;
}

String _wallName(String? w) =>
    w == 'none' ? '未靠牆' : (wallLabels[w ?? ''] ?? '');

/// 使用者看得到的訊息：客戶、櫃子（誰是第幾個）、報價。沒有座標、沒有規格參數。
String composeLayoutMessage(Map<String, dynamic> data) {
  final lines = <String>['我在配置畫面排好了櫃子，請依這個配置幫我處理：'];

  final info = data['orderInfo'];
  if (info is Map) {
    final customer = '${info['Customer'] ?? ''}'.trim();
    if (customer.isNotEmpty) lines.add('客戶：$customer');
    final caseName = '${info['CaseName'] ?? ''}'.trim();
    if (caseName.isNotEmpty) lines.add('案名：$caseName');
  }

  final cabs = _arrange(data);
  if (cabs.isEmpty) {
    lines.add('（配置畫面裡目前沒有櫃子）');
    return lines.join('\n');
  }

  // 全部都在後牆（語音預設）或沒有位置資料：不用提牆面，直接 1、2、3…
  final onlyBackOrUnknown = cabs.every((c) => c.wall == null || c.wall == 'back');
  if (onlyBackOrUnknown) {
    lines.add('櫃子（由左到右）：');
    for (var i = 0; i < cabs.length; i++) {
      lines.add('${i + 1}. ${_head(cabs[i].raw)}');
    }
  } else {
    // 有櫃子在別面牆：依牆面分組，每面牆各自從 1 開始
    String? cur = '\u0000';
    for (final c in cabs) {
      if (c.wall != cur) {
        cur = c.wall;
        lines.add('${cur == null ? '其他' : _wallName(cur)}：');
      }
      lines.add('${c.order}. ${_head(c.raw)}');
    }
  }

  final price = _n(data['price']);
  if (price != null && price > 0) lines.add('目前報價：$price');
  return lines.join('\n');
}

/// 只給 AI 的備註：每個櫃子在哪面牆、第幾個、沿牆位置、房間座標與規格參數。
/// 使用者在聊天裡看不到這段；這些資訊目前只供參考，下單 API 不會把位置寫進訂單。
String composeLayoutAiNote(Map<String, dynamic> data) {
  final cabs = _arrange(data);
  if (cabs.isEmpty) return '';
  final lines = <String>[
    '【配置資料，只給你看，不要整段唸給使用者】',
    '視角：面對後牆。順序順時針：後牆由左到右、右牆由後往前、前牆由右到左、左牆由前往後（「沿牆位置」是離左牆／後牆的距離，前牆、左牆的順序與它相反）。座標單位 mm，原點在後牆左角，x 往右牆、z 往前牆。',
  ];

  final room = data['room'];
  if (room is Map) {
    final w = _n(room['width']), d = _n(room['depth']), h = _n(room['height']);
    if (w != null && d != null && h != null) {
      lines.add('房間：寬 $w × 深 $d × 高 $h');
    }
  }

  for (final c in cabs) {
    final m = c.raw;
    final parts = <String>[];
    if (c.wall != null) {
      parts.add('${_wallName(c.wall)}第${c.order}個');
      parts.add('沿牆位置 ${_n(c.along)}');
    }
    final p = m['pose'];
    if (p is Map) {
      parts.add('座標 x=${_n(p['x'])}, z=${_n(p['z'])}, 旋轉=${_n(p['rotationDeg'])}');
    }

    final specs = <String>[];
    for (final k in const ['width', 'height', 'depth']) {
      final v = _n(m[k]);
      if (v != null) specs.add('$k=$v');
    }
    // 網頁回報的 props 是陣列 [{ key, label, value, ... }]；也容忍 { key: value } 的寫法
    void addProp(Object? key, Object? v) {
      if (key == null || v == null || v is Map || v is List) return;
      final k = '$key';
      if (const ['width', 'height', 'depth'].contains(k)) return; // 尺寸以櫃體實際值為準
      specs.add('$k=$v');
    }

    final props = m['props'];
    if (props is List) {
      for (final e in props) {
        if (e is Map) addProp(e['key'] ?? e['propsName'], e['value']);
      }
    } else if (props is Map) {
      props.forEach(addProp);
    }
    if (specs.isNotEmpty) parts.add('規格參數 ${specs.join(', ')}');

    final remark = '${m['remark'] ?? ''}'.trim();
    if (remark.isNotEmpty) parts.add('備註：$remark');
    lines.add('- ${_head(m)}${parts.isEmpty ? '' : '；${parts.join('；')}'}');
  }
  return lines.join('\n');
}

/// 數字轉成整數（網頁給的是 mm，可能帶小數）；不是數字回傳 null
int? _n(Object? v) {
  if (v is num) return v.round();
  final p = num.tryParse('${v ?? ''}');
  return p?.round();
}
