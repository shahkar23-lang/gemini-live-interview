class TranscriptEntry {
  final String id;
  String speaker;
  final String text;
  final DateTime timestamp;
  final Duration sessionOffset;
  final bool isFromGeminiModel;
  final bool isOnDeviceMlKit;

  TranscriptEntry({
    required this.id,
    required this.speaker,
    required this.text,
    required this.timestamp,
    this.sessionOffset = Duration.zero,
    this.isFromGeminiModel = false,
    this.isOnDeviceMlKit = false,
  });
}

class InterviewSummaryResult {
  final List<String> summaryBullets;
  final List<String> journalistCounterQuestions;
  final Map<String, String> speakerRoles;
  final String keyHeadline;
  final String sourceLabel;

  const InterviewSummaryResult({
    required this.summaryBullets,
    required this.journalistCounterQuestions,
    this.speakerRoles = const {},
    required this.keyHeadline,
    required this.sourceLabel,
  });
}
