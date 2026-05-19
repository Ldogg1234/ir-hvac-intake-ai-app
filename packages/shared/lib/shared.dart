/// Shared package for IR HVAC apps.
/// Import this single file to access all models, services, and constants.
library shared;

// Constants
export 'constants/app_colors.dart';
export 'constants/collections.dart';
export 'constants/lead_status.dart';

// Models
export 'models/lead.dart';
export 'models/report.dart';
export 'models/professional_report.dart';
export 'models/ai_report_result.dart';
export 'models/troubleshooting_result.dart';

// Services
export 'services/lead_service.dart';
export 'services/report_service.dart';
export 'services/cloud_functions_service.dart';
export 'services/media_service.dart';
export 'services/troubleshooting_service.dart';
