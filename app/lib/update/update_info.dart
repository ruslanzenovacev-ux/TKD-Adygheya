/// Содержимое version.json, который GitHub Actions выкладывает при каждом выпуске.
///
/// {
///   "version": "1.0.42", "build": 142,
///   "minBuild": 130,                 // всё, что старее, обязано обновиться
///   "apkUrl": "https://.../tkd-1.0.42.apk",
///   "sha256": "…",                   // контрольная сумма APK
///   "notes": "Что нового"
/// }
class UpdateInfo {
  UpdateInfo({required this.version, required this.build, required this.minBuild, required this.apkUrl, required this.sha256, required this.notes});

  factory UpdateInfo.fromJson(Map<String, dynamic> j) => UpdateInfo(
        version: '${j['version'] ?? ''}',
        build: (j['build'] as num?)?.toInt() ?? 0,
        minBuild: (j['minBuild'] as num?)?.toInt() ?? 0,
        apkUrl: '${j['apkUrl'] ?? ''}',
        sha256: '${j['sha256'] ?? ''}'.toLowerCase(),
        notes: '${j['notes'] ?? ''}'.trim(),
      );

  final String version;
  final int build;
  final int minBuild;
  final String apkUrl;
  final String sha256;
  final String notes;

  bool isNewerThan(int currentBuild) => build > currentBuild;

  /// Обязательное обновление: текущая сборка старше минимально допустимой
  /// (например, сервер поменял формат данных).
  bool isRequiredFor(int currentBuild) => currentBuild < minBuild;
}
