import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';
import 'screens/home.dart';
import 'screens/login.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.instance.load();
  runApp(const TkdApp());
}

class TkdApp extends StatefulWidget {
  const TkdApp({super.key});

  @override
  State<TkdApp> createState() => _TkdAppState();
}

class _TkdAppState extends State<TkdApp> {
  static const _userKey = 'current_user';
  UserInfo? _user;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Api.instance.onUnauthorized = () {
      if (_user != null) _setUser(null);
    };
    _restore();
  }

  // При запуске берём пользователя из памяти телефона, чтобы тренер мог работать без интернета,
  // и тихо обновляем данные с сервера.
  Future<void> _restore() async {
    if (!Api.instance.loggedIn) {
      setState(() => _loading = false);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_userKey);
    if (cached != null) _user = UserInfo.fromJson(Map<String, dynamic>.from(jsonDecode(cached) as Map));
    setState(() => _loading = false);
    try {
      final me = UserInfo.fromJson(Map<String, dynamic>.from(await Api.instance.get('/me') as Map));
      await _setUser(me);
    } on ApiException catch (e) {
      if (e.status == 401) await _setUser(null);
    }
  }

  Future<void> _setUser(UserInfo? user) async {
    final prefs = await SharedPreferences.getInstance();
    if (user == null) {
      await Api.instance.setToken(null);
      await prefs.remove(_userKey);
    } else {
      await prefs.setString(_userKey, jsonEncode(user.toJson()));
    }
    if (mounted) setState(() => _user = user);
  }

  Future<void> _logout() async {
    try {
      await Api.instance.post('/auth/logout');
    } catch (_) {}
    await _setUser(null);
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1F3A93);
    return MaterialApp(
      title: 'Тхэквондо',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _user == null
              ? LoginScreen(onLoggedIn: (token, user) async {
                  await Api.instance.setToken(token);
                  await _setUser(user);
                })
              : HomeScreen(
                  key: ValueKey(_user!.roles.join(',')),
                  user: _user!,
                  onLogout: _logout,
                  onUserChanged: _setUser,
                ),
    );
  }
}
