// Checks whether a valid backend session exists and displays login or the existing app screen.
// Pass your current home screen as authenticatedChild so existing app functionality is preserved.
import 'dart:async';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../models/app_user.dart';
import '../screens/login_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authenticatedChild,
    required this.themeNotifier,
  });

  final Widget authenticatedChild;
  final ValueNotifier<bool> themeNotifier;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late Future<AppUser> _userFuture;

  @override
  void initState() {
    super.initState();
    _userFuture = AuthService.instance.currentUser();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppUser>(
      future: _userFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasData) return widget.authenticatedChild;
        return LoginScreen(
          themeNotifier: widget.themeNotifier,
        );
      },
    );
  }
}