enum UserRole { soldier, commander }

class UserSession {
  final String userId;
  final String name;
  final String unitId;
  final UserRole role;

  UserSession({
    required this.userId,
    required this.name,
    required this.unitId,
    required this.role,
  });

  bool get isCommander => role == UserRole.commander;
}