import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);
  ApiException.offline() : this(0, 'offline', 'Нет связи с сервером. Проверьте интернет');

  final int status;
  final String code;
  final String message;

  bool get isOffline => code == 'offline';

  @override
  String toString() => message;
}

/// Клиент API. Токен входа хранится в настройках телефона.
class Api {
  Api._();
  static final Api instance = Api._();

  static const _tokenKey = 'auth_token';
  final http.Client _client = http.Client();
  String? _token;

  /// Вызывается, когда сервер ответил «нужно войти» (сессия истекла).
  void Function()? onUnauthorized;

  bool get loggedIn => _token != null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
  }

  Future<void> setToken(String? token) async {
    _token = token;
    final prefs = await SharedPreferences.getInstance();
    if (token == null) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, token);
    }
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body ?? const {});
  Future<dynamic> patch(String path, Object body) => _send('PATCH', path, body: body);

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    var uri = Uri.parse('${AppConfig.apiUrl}$path');
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final req = http.Request(method, uri);
    req.headers['Content-Type'] = 'application/json';
    if (_token != null) req.headers['Authorization'] = 'Bearer $_token';
    if (body != null) req.body = jsonEncode(body);

    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 20)));
    } on TimeoutException {
      throw ApiException.offline();
    } catch (_) {
      throw ApiException.offline();
    }

    final text = utf8.decode(res.bodyBytes);
    dynamic data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      data = text;
    }
    if (res.statusCode >= 400) {
      final err = data is Map ? data['error'] : null;
      if (res.statusCode == 401) onUnauthorized?.call();
      throw ApiException(
        res.statusCode,
        err is Map ? '${err['code']}' : 'http_${res.statusCode}',
        err is Map ? '${err['message']}' : 'Ошибка сервера (${res.statusCode})',
      );
    }
    return data;
  }
}
