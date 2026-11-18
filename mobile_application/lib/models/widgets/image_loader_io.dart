import 'dart:io';
import 'package:flutter/widgets.dart';

bool checkLocalImageExists(String? path) {
  if (path == null || path.isEmpty) return false;
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

Widget? buildLocalImage(String? path) {
  if (path == null || path.isEmpty) return null;
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    return Image.file(file, fit: BoxFit.cover);
  } catch (_) {
    return null;
  }
}
