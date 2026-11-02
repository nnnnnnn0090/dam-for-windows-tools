import 'package:flutter/widgets.dart';

import 'app/app_controller.dart';
import 'ui/app.dart';

/// 単一起動の判定と、他プロセスの後始末（ジョブオブジェクト）はrunner側で済んでいます。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerLicenses();
  runApp(DamToolsApp(controller: AppController()));
}
