import 'package:flutter/material.dart';

enum AppView {
  facilities('Facilities', 'Facilities', Icons.apartment_rounded),
  addFacility('Add facility', 'Add a facility', Icons.add_business_rounded),
  reservations(
    'Reservations',
    'Reservation requests',
    Icons.pending_actions_rounded,
  ),
  calendar('Calendar', 'Reservation calendar', Icons.calendar_month_rounded),
  verifications(
    'Verifications',
    'Campus verifications',
    Icons.verified_user_rounded,
  ),
  users('Users', 'Accounts', Icons.people_alt_rounded),
  feedback('Feedback', 'Reservation feedback', Icons.reviews_rounded),
  anomalies('Anomalies', 'Anomaly Center', Icons.shield_moon_rounded),
  loyalty('Loyalty', 'Loyalty points', Icons.stars_rounded),
  audit('Audit log', 'Audit log', Icons.history_rounded),
  reports('Reports', 'Reports', Icons.insights_rounded),
  notes('Design notes', 'Design notes', Icons.sticky_note_2_rounded),
  profile('Profile', 'Your profile', Icons.account_circle_rounded),
  userApp('User app', 'SmartReserve', Icons.phone_iphone_rounded),
  auth('Onboarding', 'Onboarding', Icons.login_rounded);

  const AppView(this.crumb, this.title, this.icon);

  final String crumb;

  final String title;

  final IconData icon;

  List<String> get breadcrumbs => this == AppView.addFacility
      ? const ['Facilities', 'Add facility']
      : [crumb];

  bool get usesAdminChrome => this != AppView.userApp && this != AppView.auth;

  AppView get navSection =>
      this == AppView.addFacility ? AppView.facilities : this;
}
