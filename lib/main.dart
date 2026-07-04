import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseConfig.initialize();

  runApp(ChatApp(supabaseClient: SupabaseConfig.client));
}
