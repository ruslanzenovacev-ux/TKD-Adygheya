// Настройки, которые подставляются при сборке (--dart-define в GitHub Actions).

class AppConfig {
  /// Адрес API Gateway, например https://d5d....apigw.yandexcloud.net
  /// По умолчанию — локальный сервер разработки (10.0.2.2 = компьютер для эмулятора Android).
  static const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:8787');

  /// Адрес version.json для автообновления. Пусто — автообновление выключено.
  static const updateUrl = String.fromEnvironment('UPDATE_URL');

  /// Номер сборки и версия — для сравнения с version.json.
  static const build = int.fromEnvironment('APP_BUILD', defaultValue: 0);
  static const version = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

  /// Политика обработки персональных данных (показывается при регистрации).
  static const privacyUrl = String.fromEnvironment('PRIVACY_URL');

  /// Название секции в шапке.
  static const clubName = String.fromEnvironment('CLUB_NAME', defaultValue: 'Тхэквондо');
}
