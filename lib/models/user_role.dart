enum UserRole {
  ADMIN,
  OFFICER,
  TSP;

  static UserRole fromString(String role) {
    switch (role.toUpperCase()) {
      case 'ADMIN':
        return UserRole.ADMIN;
      case 'OFFICER':
        return UserRole.OFFICER;
      case 'TSP':
        return UserRole.TSP;
      default:
        return UserRole.OFFICER;
    }
  }

  String toShortString() {
    return this.toString().split('.').last;
  }
}
