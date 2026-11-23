import 'package:flutter/material.dart';
import 'app.dart';
import 'services/api_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiConfig().load(); // saved backend URL, before the auth gate calls /auth/me
  runApp(const NotesPrivacyApp());
}