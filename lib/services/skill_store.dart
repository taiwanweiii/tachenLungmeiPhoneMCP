import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/skill_model.dart';

class SkillStore extends ChangeNotifier {
  static const _kSkills   = 'skills_v1';
  static const _kActiveId = 'active_skill_id';

  late SharedPreferences _prefs;
  List<SkillModel> _skills  = [];
  String _activeId          = SkillModel.defaultCurtainOrder.id;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _load();
  }

  Future<void> _load() async {
    final raw        = _prefs.getStringList(_kSkills) ?? [];
    final userSkills = raw.map(SkillModel.fromJson).toList();
    _skills = [
      SkillModel.defaultCurtainOrder,
      SkillModel.defaultFullAccess,
      SkillModel.defaultChat,
      ...userSkills,
    ];
    _activeId = _prefs.getString(_kActiveId) ?? SkillModel.defaultCurtainOrder.id;
  }

  Future<void> _saveUserSkills() async {
    final userSkills = _skills.where((s) => !s.isBuiltIn).toList();
    await _prefs.setStringList(
        _kSkills, userSkills.map((s) => s.toJson()).toList());
  }

  // ── Getters ───────────────────────────────────────────
  List<SkillModel> get skills => List.unmodifiable(_skills);

  SkillModel get activeSkill => _skills.firstWhere(
        (s) => s.id == _activeId,
        orElse: () => SkillModel.defaultCurtainOrder,
      );

  // ── CRUD ──────────────────────────────────────────────
  Future<void> setActiveSkill(SkillModel skill) async {
    _activeId = skill.id;
    await _prefs.setString(_kActiveId, skill.id);
    notifyListeners();
  }

  Future<void> addSkill(SkillModel skill) async {
    _skills.add(skill);
    await _saveUserSkills();
    notifyListeners();
  }

  Future<void> updateSkill(SkillModel skill) async {
    final idx = _skills.indexWhere((s) => s.id == skill.id);
    if (idx != -1) _skills[idx] = skill;
    await _saveUserSkills();
    notifyListeners();
  }

  Future<void> deleteSkill(String id) async {
    _skills.removeWhere((s) => s.id == id);
    if (_activeId == id) {
      _activeId = SkillModel.defaultCurtainOrder.id;
      await _prefs.setString(_kActiveId, _activeId);
    }
    await _saveUserSkills();
    notifyListeners();
  }
}