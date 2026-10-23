import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../config.dart';
import '../models.dart';
import '../widgets/common.dart';

/// Вход по коду на почту. Новый пользователь при первом входе указывает имя и даёт согласие (152-ФЗ).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLoggedIn});

  final Future<void> Function(String token, UserInfo user) onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Step { email, code }

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  _Step _step = _Step.email;
  bool _newUser = false;
  bool _consent = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_email, _code, _name, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _requestCode() async {
    setState(() => _busy = true);
    try {
      await Api.instance.post('/auth/request-code', {'email': _email.text.trim()});
      setState(() => _step = _Step.code);
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_newUser && !_consent) {
      showMessage(context, 'Отметьте согласие на обработку персональных данных', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await Api.instance.post('/auth/verify', {
        'email': _email.text.trim(),
        'code': _code.text.trim(),
        if (_newUser) 'name': _name.text.trim(),
        if (_newUser && _phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
        if (_newUser) 'consent': _consent,
      }) as Map;
      await widget.onLoggedIn('${res['token']}', UserInfo.fromJson(Map<String, dynamic>.from(res['user'] as Map)));
    } on ApiException catch (e) {
      if (e.code == 'consent_required' || e.code == 'name_required') {
        // Почта ещё не зарегистрирована — показываем поля регистрации, код остаётся действительным.
        setState(() => _newUser = true);
        if (e.code == 'name_required' && mounted) showMessage(context, e.message, error: true);
      } else if (mounted) {
        showMessage(context, e.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.sports_martial_arts, size: 64, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 12),
                    Text(AppConfig.clubName, textAlign: TextAlign.center, style: t.headlineSmall),
                    const SizedBox(height: 4),
                    Text('Абонементы и посещения', textAlign: TextAlign.center, style: t.bodyMedium),
                    const SizedBox(height: 32),
                    if (_step == _Step.email) ..._emailStep() else ..._codeStep(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _emailStep() => [
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _busy ? null : _requestCode(),
          decoration: const InputDecoration(labelText: 'Электронная почта', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _requestCode,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(_busy ? 'Отправляем…' : 'Получить код')),
        ),
        const SizedBox(height: 12),
        const Text('Мы пришлём на почту код для входа. Пароль не нужен.', textAlign: TextAlign.center),
      ];

  List<Widget> _codeStep() => [
        Text('Код отправлен на ${_email.text.trim()}', textAlign: TextAlign.center),
        const SizedBox(height: 16),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 8),
          decoration: const InputDecoration(labelText: 'Код из письма', border: OutlineInputBorder(), counterText: ''),
        ),
        if (_newUser) ...[
          const SizedBox(height: 16),
          const Text('Вы входите впервые. Расскажите о себе:'),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            autofillHints: const [AutofillHints.name],
            decoration: const InputDecoration(labelText: 'Ваши имя и фамилия', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: const InputDecoration(labelText: 'Телефон (необязательно)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _consent,
            onChanged: (v) => setState(() => _consent = v ?? false),
            title: _consentText(),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _verify,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(_busy ? 'Проверяем…' : (_newUser ? 'Зарегистрироваться' : 'Войти'))),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _step = _Step.email;
                    _code.clear();
                    _newUser = false;
                  }),
          child: const Text('Изменить почту или отправить код ещё раз'),
        ),
      ];

  Widget _consentText() {
    const text = 'Я даю согласие на обработку моих персональных данных и данных моего ребёнка';
    if (AppConfig.privacyUrl.isEmpty) return const Text(text);
    return Text.rich(TextSpan(children: [
      const TextSpan(text: '$text в соответствии с '),
      TextSpan(
        text: 'политикой конфиденциальности',
        style: TextStyle(color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(AppConfig.privacyUrl), mode: LaunchMode.externalApplication),
      ),
    ]));
  }
}
