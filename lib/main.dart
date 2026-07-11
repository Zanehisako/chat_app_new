import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/notification_service.dart';
import 'src/supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FirebaseMessagingBackgroundHandlerRegistrar.register();
  await SupabaseConfig.initialize();
  await NotificationService.instance.initialize(client: SupabaseConfig.client);

  runApp(ChatApp(supabaseClient: SupabaseConfig.client));
}
