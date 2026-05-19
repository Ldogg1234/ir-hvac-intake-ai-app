/// All possible statuses for a lead, in lifecycle order.
enum LeadStatus {
  intake,
  assigned,
  scheduled,
  inProgress,
  reportSubmitted,
  invoiced;

  /// The Firestore string value for this status.
  String get value {
    switch (this) {
      case LeadStatus.intake:
        return 'intake';
      case LeadStatus.assigned:
        return 'assigned';
      case LeadStatus.scheduled:
        return 'scheduled';
      case LeadStatus.inProgress:
        return 'in-progress';
      case LeadStatus.reportSubmitted:
        return 'report-submitted';
      case LeadStatus.invoiced:
        return 'invoiced';
    }
  }

  /// Parse a Firestore string back to [LeadStatus].
  static LeadStatus fromString(String? value) {
    switch (value) {
      case 'assigned':
        return LeadStatus.assigned;
      case 'scheduled':
        return LeadStatus.scheduled;
      case 'in-progress':
        return LeadStatus.inProgress;
      case 'report-submitted':
        return LeadStatus.reportSubmitted;
      case 'invoiced':
        return LeadStatus.invoiced;
      default:
        return LeadStatus.intake;
    }
  }

  bool get isActive => this == LeadStatus.inProgress;
  bool get isCompleted =>
      this == LeadStatus.reportSubmitted || this == LeadStatus.invoiced;
  bool get isPending =>
      this == LeadStatus.assigned || this == LeadStatus.scheduled;
}
