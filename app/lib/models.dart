// Модели данных, приходящих с сервера.

int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
String? _str(dynamic v) => v?.toString();

class UserInfo {
  UserInfo({required this.id, required this.email, required this.name, this.phone, required this.roles});

  factory UserInfo.fromJson(Map<String, dynamic> j) => UserInfo(
        id: '${j['id']}',
        email: '${j['email']}',
        name: '${j['name'] ?? ''}',
        phone: _str(j['phone']),
        roles: [for (final r in (j['roles'] as List? ?? const [])) '$r'],
      );

  final String id;
  final String email;
  final String name;
  final String? phone;
  final List<String> roles;

  bool get isAdmin => roles.contains('admin');
  bool get isTrainer => roles.contains('trainer');

  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'name': name, 'phone': phone, 'roles': roles};
}

class Child {
  Child.fromJson(Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        birthDate = _str(j['birthDate']),
        status = '${j['status']}',
        groupId = _str(j['groupId']),
        groupName = _str(j['groupName']),
        parentId = _str(j['parentId']),
        balance = _int(j['balance']),
        available = _int(j['available']),
        debt = _int(j['debt']),
        nextExpiryDate = j['nextExpiry'] is Map ? _str(j['nextExpiry']['date']) : null,
        nextExpiryLessons = j['nextExpiry'] is Map ? _int(j['nextExpiry']['lessons']) : 0,
        markId = j['mark'] is Map ? _str(j['mark']['id']) : null,
        markDebt = j['mark'] is Map && j['mark']['debt'] == true,
        raw = j;

  final String id;
  final String name;
  final String? birthDate;
  final String status;
  final String? groupId;
  final String? groupName;
  final String? parentId;
  final int balance;
  final int available;
  final int debt;
  final String? nextExpiryDate;
  final int nextExpiryLessons;

  /// Только в списке группы: отметка за выбранный день.
  final String? markId;
  final bool markDebt;

  /// Полный ответ сервера (в карточке там ещё абонементы, посещения и платежи).
  final Map<String, dynamic> raw;

  bool get isPending => status == 'pending';
  bool get isArchived => status == 'archived';

  List<Map<String, dynamic>> listOf(String key) =>
      [for (final e in (raw[key] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
}

class Plan {
  Plan.fromJson(Map<String, dynamic> j)
      : id = '${j['id']}',
        title = '${j['title']}',
        lessons = _int(j['lessons']),
        price = _int(j['price']),
        validDays = _int(j['validDays']),
        active = j['active'] != false;

  final String id;
  final String title;
  final int lessons;
  final int price; // копейки
  final int validDays;
  final bool active;
}

class Group {
  Group.fromJson(Map<String, dynamic> j)
      : id = '${j['id']}',
        name = '${j['name']}',
        schedule = '${j['schedule'] ?? ''}',
        place = '${j['place'] ?? ''}',
        trainerId = _str(j['trainerId']),
        trainerName = _str(j['trainerName']),
        active = j['active'] != false;

  final String id;
  final String name;
  final String schedule;
  final String place;
  final String? trainerId;
  final String? trainerName;
  final bool active;
}

class Payment {
  Payment.fromJson(Map<String, dynamic> j)
      : id = '${j['id']}',
        childId = _str(j['childId']),
        title = '${j['title'] ?? ''}',
        amount = _int(j['amount']),
        lessons = _int(j['lessons']),
        status = '${j['status']}',
        method = _str(j['method']),
        createdAt = '${j['createdAt'] ?? ''}',
        confirmationUrl = _str(j['confirmationUrl']),
        refundedAmount = _int(j['refundedAmount']);

  final String id;
  final String? childId;
  final String title;
  final int amount;
  final int lessons;
  final String status;
  final String? method;
  final String createdAt;
  final String? confirmationUrl;
  final int refundedAmount;
}
