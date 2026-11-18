
import 'package:flutter/material.dart';

import '../data/demo_data.dart';
import '../services/auth_service.dart';
import 'dashboard_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.themeNotifier,
  });

  final ValueNotifier<bool> themeNotifier;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final formKey = GlobalKey<FormState>();

  final fullNameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool isSignup = false;
  bool hidePassword = true;
  bool isLoading = false;

  @override
  void dispose() {
    fullNameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> authenticate() async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    if (isLoading) return;

    FocusScope.of(context).unfocus();

    setState(() => isLoading = true);

    final email = emailController.text.trim();
    final password = passwordController.text;

    try {
      final user = isSignup
          ? await AuthService.instance.register(
              fullName: fullNameController.text.trim(),
              email: email,
              password: password,
            )
          : await AuthService.instance.login(
              email: email,
              password: password,
            );

      if (!mounted) return;

      // Store the authenticated user's actual ID.
      DemoData.currentUserId = user.id;

      // Preserve the existing Supabase data-loading functionality.
      DemoData.loadFromSupabase(user.id);

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => DashboardScreen(
            themeNotifier: widget.themeNotifier,
            email: user.email,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString()),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 450),
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: widget.themeNotifier,
                        builder: (context, isDark, child) {
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isDark
                                    ? Icons.nightlight_round
                                    : Icons.wb_sunny_outlined,
                              ),
                              const SizedBox(width: 6),
                              const Text('Dark mode'),
                              Switch(
                                value: isDark,
                                onChanged: (value) {
                                  widget.themeNotifier.value = value;
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 20),

                    CircleAvatar(
                      radius: 42,
                      backgroundColor: colors.primary,
                      child: const Icon(
                        Icons.shield_moon,
                        color: Colors.white,
                        size: 44,
                      ),
                    ),

                    const SizedBox(height: 22),

                    const Text(
                      'Privacy Preserving\nSmart Notes',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 8),

                    const Text(
                      'Smart note taking with privacy in mind',
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 30),

                    Text(
                      isSignup ? 'Create Account' : 'Welcome Back',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 18),

                    if (isSignup) ...[
                      TextFormField(
                        controller: fullNameController,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Full Name',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (value) {
                          if (!isSignup) return null;

                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter your full name';
                          }

                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                    ],

                    TextFormField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      validator: (value) {
                        final email = value?.trim() ?? '';

                        if (email.isEmpty) {
                          return 'Please enter your email';
                        }

                        final emailPattern =
                            RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

                        if (!emailPattern.hasMatch(email)) {
                          return 'Enter a valid email address';
                        }

                        return null;
                      },
                    ),

                    const SizedBox(height: 14),

                    TextFormField(
                      controller: passwordController,
                      obscureText: hidePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => authenticate(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: () {
                            setState(() {
                              hidePassword = !hidePassword;
                            });
                          },
                          icon: Icon(
                            hidePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.length < 6) {
                          return 'Password must have at least 6 characters';
                        }

                        return null;
                      },
                    ),

                    const SizedBox(height: 22),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: isLoading ? null : authenticate,
                        child: isLoading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                isSignup ? 'Create Account' : 'Login',
                              ),
                      ),
                    ),

                    TextButton(
                      onPressed: isLoading
                          ? null
                          : () {
                              setState(() {
                                isSignup = !isSignup;
                              });

                              formKey.currentState?.reset();
                              passwordController.clear();
                            },
                      child: Text(
                        isSignup
                            ? 'Already have an account? Login'
                            : 'New user? Create an account',
                      ),
                    ),

                    const SizedBox(height: 12),

                    const Text(
                      'Your account is authenticated through the backend service.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
