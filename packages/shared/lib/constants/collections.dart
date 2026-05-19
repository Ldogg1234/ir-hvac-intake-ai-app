/// Firestore collection name constants.
/// Use these everywhere — never hardcode collection names in app code.
class FirestoreCollections {
  FirestoreCollections._();

  static const String leads = 'leads';
  static const String reports = 'reports';
  static const String hvacReports = 'hvac_reports';
}

/// Firebase Storage path helpers.
class StoragePaths {
  StoragePaths._();

  /// Categorized media warehouse path: warehouse/{brand}/{model}/{type}/{filename}
  static String warehouseMedia({
    required String brand,
    required String model,
    required String type,
    required String filename,
  }) =>
      'warehouse/$brand/$model/$type/$filename';

  /// Reports output folder.
  static String report(String filename) => 'reports/$filename';
}
