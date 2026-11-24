import 'dart:convert';

import 'cabinet_web_controller.dart' show PickedItem;
import 'wall.dart';

/// 聊天的「已選櫃子」與系統櫃配置頁的雙向同步用到的純邏輯（不碰網頁，方便測試）。
///
/// - 正向（已選 → 配置頁）：灌進去後記住「網頁的每顆櫃子對應哪個已選品項」[assignSources]，
///   並把網頁當時的狀態存成基準。
/// - 反向（配置頁 → 已選）：網頁有變動時，拿現況跟基準比，有差異才轉回已選清單 [pickedFromConfig]。

/// 配置頁 getState().cabinets 裡的一顆櫃子
class ConfigCabinet {
  final String uuid;
  final String productNo;
  final String title;

  /// 尺寸（mm）：width／height／depth
  final Map<String, dynamic> dims;

  /// 規格名稱 → 目前的值
  final Map<String, dynamic> props;

  /// 規格名稱 → 給人看的名稱
  final Map<String, String> labels;

  /// 規格名稱 → 類型（SELECT／SELECT2／NUMBER／BOOL／…）
  final Map<String, String> types;

  /// 規格名稱 → { 值（字串）: 顯示名稱 }，選項類用來把值轉成人看得懂的文字
  final Map<String, Map<String, String>> optionLabels;

  const ConfigCabinet({
    required this.uuid,
    required this.productNo,
    required this.title,
    required this.dims,
    required this.props,
    required this.labels,
    this.types = const {},
    this.optionLabels = const {},
  });

  static const _dimKeys = ['width', 'height', 'depth'];

  static ConfigCabinet? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uuid = '${raw['uuid'] ?? ''}';
    final productNo = '${raw['productNo'] ?? ''}';
    if (uuid.isEmpty || productNo.isEmpty) return null;

    final dims = <String, dynamic>{
      for (final k in _dimKeys)
        if (raw[k] is num) k: raw[k],
    };
    final props = <String, dynamic>{};
    final labels = <String, String>{};
    final types = <String, String>{};
    final optionLabels = <String, Map<String, String>>{};
    final rows = raw['props'];
    if (rows is List) {
      for (final r in rows) {
        if (r is! Map || r['editable'] == false) continue;
        final key = '${r['propsName'] ?? r['key'] ?? ''}';
        if (key.isEmpty || r['value'] == null) continue;
        props[key] = r['value'];
        labels[key] = '${r['label'] ?? key}';
        types[key] = '${r['type'] ?? ''}'.toUpperCase();
        final opts = _parseOptions(r['options']);
        if (opts.isNotEmpty) optionLabels[key] = opts;
      }
    }
    return ConfigCabinet(
      uuid: uuid,
      productNo: productNo,
      title: '${raw['title'] ?? productNo}',
      dims: dims,
      props: props,
      labels: labels,
      types: types,
      optionLabels: optionLabels,
    );
  }

  /// options 可能是 { 顯示名稱: 值 }、[ { label, value } ] 或 [值, 值]
  static Map<String, String> _parseOptions(Object? o) {
    final out = <String, String>{};
    if (o is Map) {
      o.forEach((k, v) => out['$v'] = '$k'.trim());
    } else if (o is List) {
      for (final e in o) {
        if (e is Map && e.containsKey('value')) {
          out['${e['value']}'] = '${e['label'] ?? e['value']}'.trim();
        } else {
          out['$e'] = '$e';
        }
      }
    }
    return out;
  }
}

List<ConfigCabinet> parseConfigCabinets(Object? list) => [
      if (list is List)
        for (final c in list)
          if (ConfigCabinet.fromJson(c) case final cc?) cc,
    ];

/// 一組櫃子的「指紋」：有加、刪、改尺寸或規格就會不一樣
String configSignature(Iterable<ConfigCabinet> cabinets) {
  final rows = [
    for (final c in cabinets)
      [c.uuid, c.productNo, _sorted(c.dims), _sorted(c.props)],
  ]..sort((a, b) => '${a[0]}'.compareTo('${b[0]}'));
  return jsonEncode(rows);
}

Map<String, dynamic> _sorted(Map<String, dynamic> m) =>
    {for (final k in (m.keys.toList()..sort())) k: m[k]};

/// 正向灌進配置頁後，網頁回報的 added（依序 uuid + productNo）要對回是哪個已選品項。
/// 一個品項數量 N 會佔 N 顆；同品號的依序分配。
Map<String, PickedItem> assignSources(
  List<({String uuid, String productNo})> added,
  List<PickedItem> items,
) {
  final remaining = [for (final p in items) p.quantity];
  final out = <String, PickedItem>{};
  for (final a in added) {
    final i = items.indexWhere((p) => p.productNo == a.productNo);
    // 找第一個還有名額的同品號品項
    var idx = -1;
    for (var j = 0; j < items.length; j++) {
      if (items[j].productNo == a.productNo && remaining[j] > 0) {
        idx = j;
        break;
      }
    }
    if (idx < 0) idx = i; // 名額用完（網頁多放了）：歸給第一個同品號的
    if (idx < 0) continue;
    remaining[idx] = remaining[idx] - 1;
    out[a.uuid] = items[idx];
  }
  return out;
}

class ReverseResult {
  final List<PickedItem> items;

  /// 現在每顆櫃子（uuid）對應到的已選品項，下一次比對用
  final Map<String, PickedItem> sources;
  const ReverseResult(this.items, this.sources);
}

/// 配置頁 → 已選清單。
/// - 原本就有的櫃子：沿用原來品項的規格，只把「跟基準比有變」的尺寸／規格蓋上去。
/// - 使用者在配置頁新加的櫃子：沒有任何規格覆蓋（用網頁預設）。
/// - 同品號、同規格的合併成一項，數量相加。
ReverseResult pickedFromConfig({
  required List<ConfigCabinet> current,
  required Map<String, ConfigCabinet> baseline,
  required Map<String, PickedItem> sources,
  required List<PickedItem> previous,
}) {
  final groups = <String, PickedItem>{};
  final order = <String>[];
  final uuidToKey = <String, String>{};

  for (final c in current) {
    final src = sources[c.uuid];
    final base = baseline[c.uuid];
    PickedItem item;
    if (src != null && base != null) {
      final specs = Map<String, dynamic>.of(src.specs);
      final changed = <String>[];
      for (final e in c.dims.entries) {
        if (base.dims[e.key] != e.value) {
          specs[e.key] = e.value;
          changed.add(e.key);
        }
      }
      for (final e in c.props.entries) {
        if (base.props[e.key] != e.value) {
          specs[e.key] = e.value;
          changed.add(e.key);
        }
      }
      item = PickedItem(
        src.productNo,
        src.name,
        1,
        specs: specs,
        defaults: src.defaults,
        wall: src.wall,
        specText: changed.isEmpty ? src.specText : _specText(specs, c.labels),
        missing: changed.isEmpty
            ? src.missing
            : [for (final m in src.missing) if (!changed.contains(m)) m],
      );
    } else {
      final prev = previous.where((p) => p.productNo == c.productNo);
      item = PickedItem(
        c.productNo,
        prev.isNotEmpty ? prev.first.name : c.title,
        1,
      );
    }
    // 同品號同規格但放在不同牆的，不能合併成同一項
    final key =
        '${item.productNo}|${jsonEncode(_sorted(item.specs))}|${item.wall ?? 'back'}';
    uuidToKey[c.uuid] = key;
    final existing = groups[key];
    if (existing == null) {
      groups[key] = item;
      order.add(key);
    } else {
      groups[key] = existing.withQuantity(existing.quantity + 1);
    }
  }

  return ReverseResult(
    [for (final k in order) groups[k]!],
    {for (final e in uuidToKey.entries) e.key: groups[e.value]!},
  );
}

// ── 跟配置頁核對：拿網站實際的規格值（含預設）更新已選品項 ─────────────

const _specTypes = {'SELECT', 'SELECT2', 'NUMBER', 'BOOL'};

/// 一顆櫃子在配置頁的實際規格值。只收挑選頁會讓人選的那幾種類型（SELECT／SELECT2／NUMBER／BOOL），
/// 跟挑選頁的規格清單是同一份 Props，所以不會多出挑選頁沒有的欄位。
Map<String, dynamic> actualSpecs(ConfigCabinet c) => {
      for (final e in c.props.entries)
        if (_specTypes.contains(c.types[e.key])) e.key: e.value,
    };

/// 有些規格沒設中文標籤（標籤就是 width 這種名稱），跟網頁一樣用常見的中文名稱補上
const _fallbackLabels = {
  'width': '寬度',
  'height': '高度',
  'depth': '深度',
  'direction': '開門方向',
};

String _labelOf(ConfigCabinet c, String key) {
  final raw = (c.labels[key] ?? '').trim();
  if (raw.isNotEmpty && raw != key) return raw;
  return _fallbackLabels[key] ?? (raw.isEmpty ? key : raw);
}

/// 實際值轉成給人看的文字，例如「寬度 45公分・開門方向 左開門 <・上固隔 後縮0cm」
/// 選項類用選項的顯示名稱，數字加單位（沒單位用 mm），跟網頁挑選頁的寫法一致。
String actualText(ConfigCabinet c, Map<String, dynamic> actual) {
  final parts = <String>[];
  for (final e in actual.entries) {
    final k = e.key;
    final v = e.value;
    final label = _labelOf(c, k);
    final opt = c.optionLabels[k]?['$v'];
    if (opt != null) {
      parts.add('$label $opt');
    } else if (c.types[k] == 'BOOL') {
      parts.add('$label ${v == true ? '是' : '否'}');
    } else if (c.types[k] == 'NUMBER' && v is num) {
      parts.add('$label ${_num(v)}mm');
    } else {
      parts.add('$label $v');
    }
  }
  return parts.join('・');
}

class ResolveResult {
  final List<PickedItem> items;
  final bool changed;
  const ResolveResult(this.items, this.changed);
}

/// 把配置頁回報的實際值套到目前的已選清單。
/// [synced] 是當初灌進配置頁的清單，[sources] 是網頁每顆櫃子（uuid）對應哪個 synced 品項。
/// 目前清單的品項只有「跟 synced 裡的同品號、同規格、同數量」才會更新；
/// 灌進去之後又被使用者改過的就先不動（下一輪同步會處理）。
ResolveResult applyResolved({
  required List<PickedItem> current,
  required List<PickedItem> synced,
  required Map<String, PickedItem> sources,
  required List<ConfigCabinet> cabinets,
}) {
  // 每個 synced 品項取第一顆對應的櫃子當代表
  final rep = <PickedItem, ConfigCabinet>{};
  for (final c in cabinets) {
    final s = sources[c.uuid];
    if (s != null) rep.putIfAbsent(s, () => c);
  }

  var changed = false;
  final out = <PickedItem>[];
  for (final item in current) {
    PickedItem? match;
    for (final s in synced) {
      if (s.productNo == item.productNo &&
          s.quantity == item.quantity &&
          s.sameAs(item)) {
        match = s;
        break;
      }
    }
    final cab = match == null ? null : rep[match];
    if (cab == null) {
      out.add(item);
      continue;
    }
    final actual = actualSpecs(cab);
    // 網頁這次沒回報任何規格（還在計算、讀不到）：不要拿空的蓋掉卡片原本的內容
    if (actual.isEmpty) {
      out.add(item);
      continue;
    }
    final text = actualText(cab, actual);
    final same = item.verified &&
        jsonEncode(_sorted(item.actual)) == jsonEncode(_sorted(actual)) &&
        item.specText == text;
    if (same) {
      out.add(item);
    } else {
      out.add(item.withActual(actual, text));
      changed = true;
    }
  }
  return ResolveResult(out, changed);
}

/// 已選清單的指紋（品號＋規格＋數量），判斷「報價是不是算的目前這份」
String pickedSignature(Iterable<PickedItem> items) => jsonEncode([
      for (final p in items)
        [p.productNo, _sorted(p.specs), p.quantity, p.wall ?? 'back'],
    ]);

String _num(num v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// 給人看的規格文字，例如「寬度 80公分・開門方向 左開門」。尺寸 mm 換成公分。
String _specText(Map<String, dynamic> specs, Map<String, String> labels) {
  const dimNames = {'width': '寬度', 'height': '高度', 'depth': '深度'};
  final parts = <String>[];
  for (final e in specs.entries) {
    final v = e.value;
    if (dimNames.containsKey(e.key) && v is num) {
      parts.add('${dimNames[e.key]} ${_num(v / 10)}公分');
    } else {
      parts.add('${labels[e.key] ?? e.key} $v');
    }
  }
  return parts.join('・');
}

/// 使用者在配置頁把櫃子拖到別面牆、按「發送到聊天」後，把網頁回報的牆面寫回已選清單。
/// 之後重新打開配置頁（同步已選清單）才會還原在同一面牆，不會被放回後牆。
///
/// 依品號對應：同品號的櫃子照順序分給已選項目；同一項的數量若分散在不同牆就拆成多項。
/// 網頁沒回報牆面（null）或不靠牆（none）的維持原樣。
List<PickedItem> applyWallsFromLayout(
    List<PickedItem> picked, List<dynamic> cabinets) {
  final byNo = <String, List<String?>>{};
  for (final c in cabinets) {
    if (c is! Map) continue;
    final no = '${c['productNo'] ?? ''}';
    final w = normalizeWall(c['wall']);
    byNo.putIfAbsent(no, () => []).add(w);
  }
  final out = <PickedItem>[];
  for (final p in picked) {
    final walls = byNo[p.productNo];
    if (walls == null || walls.isEmpty) {
      out.add(p);
      continue;
    }
    final take = <String?>[];
    for (var i = 0; i < p.quantity && walls.isNotEmpty; i++) {
      take.add(walls.removeAt(0));
    }
    // 網頁給的比已選少（例如使用者在網頁刪掉）就不動，避免亂改
    if (take.length < p.quantity) {
      out.add(p);
      continue;
    }
    final counts = <String, int>{};
    for (final w in take) {
      final k = w ?? (p.wall ?? 'back');
      counts[k] = (counts[k] ?? 0) + 1;
    }
    counts.forEach((k, n) {
      out.add(PickedItem(p.productNo, p.name, n,
          specs: p.specs,
          defaults: p.defaults,
          specText: p.specText,
          missing: p.missing,
          actual: p.actual,
          wall: k == 'back' ? null : k));
    });
  }
  return out;
}

/// 把已選櫃子換到另一面牆。[productNo] 有給只換那個品號，沒給換全部。
/// 換完同品號、同規格、同牆的會合併數量。
/// AI 要調整已選櫃子：換牆（[wall]）和／或排在該牆第幾個（[position]，從 1 開始）。
/// 同一面牆內的擺放順序就是已選清單的順序（網頁依序接在前一個後面），所以排序 = 調整清單順序。
/// 第幾個以「櫃子數」算（數量 2 的品項佔 2 個位置）；排不進去就排在該牆最後。
///
/// [count]：只把這個品號的 [count] 個換到 [wall]（同品號可以拆開放不同牆，例如 2 個衣櫃一左一右）。
/// 不帶就是整個品項一起換。
List<PickedItem> movePicked(List<PickedItem> picked,
    {String? wall, String? productNo, int? position, int? count}) {
  String? wallOf(PickedItem p) => p.wall == 'back' ? null : p.wall;
  final tw0 = wall == null ? null : (wall == 'back' ? null : wall);
  var out = wall == null
      ? List.of(picked)
      : (count != null && productNo != null)
          ? _moveCount(picked, wall, productNo, count)
          : moveWall(picked, wall, productNo: productNo);
  if (position == null || productNo == null) return out;
  var ti = wall == null
      ? -1
      : out.indexWhere((p) => p.productNo == productNo && wallOf(p) == tw0);
  if (ti < 0) ti = out.indexWhere((p) => p.productNo == productNo);
  if (ti < 0) return out;
  final target = out.removeAt(ti);
  final tw = wallOf(target);
  final idx = [
    for (var i = 0; i < out.length; i++)
      if (wallOf(out[i]) == tw) i
  ];
  var insertAt = idx.isEmpty ? out.length : idx.last + 1;
  final need = position - 1;
  if (need <= 0) {
    if (idx.isNotEmpty) insertAt = idx.first;
  } else {
    var cum = 0;
    for (final i in idx) {
      cum += out[i].quantity;
      if (cum >= need) {
        insertAt = i + 1;
        break;
      }
    }
  }
  out.insert(insertAt, target);
  return out;
}

/// 把 [productNo] 的 [count] 個換到 [wall]：整個品項不夠就拆開，剩下的留在原牆。
List<PickedItem> _moveCount(
    List<PickedItem> picked, String wall, String productNo, int count) {
  final w = wall == 'back' ? null : wall;
  String? wallOf(PickedItem p) => p.wall == 'back' ? null : p.wall;
  var left = count < 1 ? 1 : count;
  final kept = <PickedItem>[];
  final moved = <PickedItem>[];
  PickedItem onWall(PickedItem p, int q) => PickedItem(p.productNo, p.name, q,
      specs: p.specs,
      defaults: p.defaults,
      specText: p.specText,
      missing: p.missing,
      actual: p.actual,
      wall: w);
  for (final p in picked) {
    if (p.productNo != productNo || wallOf(p) == w || left <= 0) {
      kept.add(p);
      continue;
    }
    final take = p.quantity <= left ? p.quantity : left;
    left -= take;
    moved.add(onWall(p, take));
    if (take < p.quantity) kept.add(p.withQuantity(p.quantity - take));
  }
  for (final m in moved) {
    final i = kept.indexWhere((o) => o.sameAs(m));
    if (i >= 0) {
      kept[i] = kept[i].withQuantity(kept[i].quantity + m.quantity);
    } else {
      kept.add(m);
    }
  }
  return kept;
}

List<PickedItem> moveWall(List<PickedItem> picked, String wall,
    {String? productNo}) {
  final w = wall == 'back' ? null : wall;
  final out = <PickedItem>[];
  for (final p in picked) {
    final hit = productNo == null || p.productNo == productNo;
    final q = !hit
        ? p
        : PickedItem(p.productNo, p.name, p.quantity,
            specs: p.specs,
            defaults: p.defaults,
            specText: p.specText,
            missing: p.missing,
            actual: p.actual,
            wall: w);
    final i = out.indexWhere((o) => o.sameAs(q));
    if (i >= 0) {
      out[i] = out[i].withQuantity(out[i].quantity + q.quantity);
    } else {
      out.add(q);
    }
  }
  return out;
}
