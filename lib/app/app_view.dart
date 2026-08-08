enum AppView {
  facilities('Facilities', 'Facilities'),
  addFacility('Add facility', 'Add a facility'),
  reservations('Reservations', 'Reservation requests'),
  calendar('Calendar', 'Reservation calendar'),
  verifications('Verifications', 'Campus verifications'),
  users('Users', 'Accounts'),
  audit('Audit log', 'Audit log'),
  reports('Reports', 'Reports'),
  notes('Design notes', 'Design notes'),
  profile('Profile', 'Your profile'),
  studentApp('Student app', 'SmartReserve'),
  auth('Onboarding', 'Onboarding');

  const AppView(this.crumb, this.title);

  final String crumb;

  final String title;

  List<String> get breadcrumbs => this == AppView.addFacility
      ? const ['Facilities', 'Add facility']
      : [crumb];

  bool get usesAdminChrome =>
      this != AppView.studentApp && this != AppView.auth;

  AppView get navSection =>
      this == AppView.addFacility ? AppView.facilities : this;
}
