import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/endpoint_model.dart';

/// 端點清單的持久化儲存（SharedPreferences）
class EndpointStore {
  static const _keyList   = 'endpoints_list';
  static const _keyActive = 'endpoints_active_id';

  final SharedPreferences _prefs;
  EndpointStore(this._prefs);

  // ── 讀取 ──────────────────────────────────────────────

  List<EndpointModel> loadAll() {
    final raw = _prefs.getStringList(_keyList) ?? [];
    if (raw.isEmpty) {
      // 第一次使用，寫入預設值
      final def = EndpointModel.defaultEndpoint;
      saveAll([def]);
      return [def];
    }
    return raw
        .map((s) => EndpointModel.fromJson(
              jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  String loadActiveId() {
    return _prefs.getString(_keyActive) ??
        EndpointModel.defaultEndpoint.id;
  }

  EndpointModel loadActive() {
    final all = loadAll();
    final id  = loadActiveId();
    return all.firstWhere(
      (e) => e.id == id,
      orElse: () => all.first,
    );
  }

  // ── 寫入 ──────────────────────────────────────────────

  Future<void> saveAll(List<EndpointModel> list) async {
    await _prefs.setStringList(
      _keyList,
      list.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  Future<void> setActive(String id) async {
    await _prefs.setString(_keyActive, id);
  }

  // ── CRUD ──────────────────────────────────────────────

  Future<void> add(EndpointModel ep) async {
    final list = loadAll()..add(ep);
    await saveAll(list);
  }

  Future<void> update(EndpointModel ep) async {
    final list = loadAll()
        .map((e) => e.id == ep.id ? ep : e)
        .toList();
    await saveAll(list);
  }

  Future<void> delete(String id) async {
    final list = loadAll()..removeWhere((e) => e.id == id);
    // 若刪除的是目前使用中的，切換到第一個
    if (loadActiveId() == id && list.isNotEmpty) {
      await setActive(list.first.id);
    }
    await saveAll(list);
  }
}