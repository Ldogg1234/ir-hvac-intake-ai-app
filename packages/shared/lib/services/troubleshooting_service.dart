import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:csv/csv.dart';
import '../models/troubleshooting_result.dart';

/// Looks up HVAC fault codes from a CSV asset.
///
/// The consuming app must declare the CSV in its `pubspec.yaml` assets:
///   assets:
///     - assets/data/hvac_troubleshooting_master.csv
class TroubleshootingService {
  static const String defaultCsvPath =
      'assets/data/hvac_troubleshooting_master.csv';

  final String csvPath;

  const TroubleshootingService({this.csvPath = defaultCsvPath});

  /// Returns the matching [TroubleshootingResult] or null if not found.
  Future<TroubleshootingResult?> lookupFault(
      String brand, String faultCode) async {
    try {
      final raw = await rootBundle.loadString(csvPath);
      final rows = const CsvToListConverter().convert(raw);
      if (rows.isEmpty) return null;

      final brandLower = brand.toLowerCase().trim();
      final codeLower = faultCode.toLowerCase().trim();

      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.length < 6) continue;
        if (row[0].toString().trim().toLowerCase() == brandLower &&
            row[1].toString().trim().toLowerCase() == codeLower) {
          return TroubleshootingResult(
            brand: row[0].toString(),
            faultCode: row[1].toString(),
            symptom: row[2].toString(),
            likelyCulprit: row[3].toString(),
            canadianContextTip: row[4].toString(),
            severity: row[5].toString(),
          );
        }
      }
    } catch (e) {
      debugPrint('TroubleshootingService.lookupFault error: $e');
    }
    return null;
  }
}
