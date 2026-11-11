import 'package:flutter/widgets.dart';
import 'image_loader_stub.dart'
    if (dart.library.io) 'image_loader_io.dart';

bool localImageExists(String? path) => checkLocalImageExists(path);

Widget? loadLocalImage(String? path) => buildLocalImage(path);
