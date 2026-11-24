import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import '../services/skill_store.dart';

final skillStoreProvider = ChangeNotifierProvider<SkillStore>((ref) {
  return GetIt.instance<SkillStore>();
});
