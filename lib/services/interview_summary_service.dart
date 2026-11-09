import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/interview_models.dart';
import 'mlkit_native_bridge.dart';

class InterviewSummaryService {
  final MlKitNativeBridge _mlKitBridge;

  InterviewSummaryService(this._mlKitBridge);

  Future<InterviewSummaryResult> generateJournalistBrief({
    required String apiKey,
    required List<TranscriptEntry> entries,
  }) async {
    if (entries.isEmpty) {
      return const InterviewSummaryResult(
        summaryBullets: ['Start speaking to generate live interview summary bullets.'],
        journalistCounterQuestions: [
          'Counter-questions will appear here automatically based on what the interviewee says.'
        ],
        keyHeadline: 'Waiting for interview transcript...',
        sourceLabel: 'Ready',
      );
    }

    final formattedTranscript = entries
        .map((e) => '[${e.speaker}]: ${e.text}')
        .join('\n');

    // 1. Try On-Device ML Kit GenAI Summarization (Gemini Nano / AICore)
    List<String> onDeviceBullets = [];
    try {
      final rawOnDevice = await _mlKitBridge.summarizeOnDevice(formattedTranscript);
      if (rawOnDevice.trim().isNotEmpty) {
        onDeviceBullets = rawOnDevice
            .split('\n')
            .map((s) => s.replaceFirst(RegExp(r'^[\-\*\•\d\.\)\s]+'), '').trim())
            .where((s) => s.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // Fallback handled below
    }

    // 2. If Gemini API Key is provided, run Gemini 2.5 Flash for deep Journalist Counter-Questions + Summary
    if (apiKey.trim().isNotEmpty) {
      try {
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey.trim()}',
        );

        final prompt = '''
You are an investigative senior journalist assisting a live interview.
Analyze the following diarized interview transcript and return ONLY valid JSON matching this exact schema:
{
  "keyHeadline": "1-sentence punchy news headline capturing the core revelation so far",
  "summaryBullets": [
    "Key point 1 from the interview so far",
    "Key point 2 from the interview so far",
    "Key point 3 from the interview so far"
  ],
  "journalistCounterQuestions": [
    "Sharp counter-question 1 challenging a claim, gap, or assumption in the transcript",
    "Sharp counter-question 2 asking for concrete numbers, timeline, or accountability",
    "Sharp counter-question 3 probing the impact or contradiction in what was just said"
  ],
  "speakerRoles": {
    "Speaker 1 (Journalist)": "Journalist",
    "Speaker 2 (Interviewee)": "Interviewee"
  }
}

Live Interview Transcript:
$formattedTranscript
''';

        final response = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'contents': [
                  {
                    'parts': [
                      {'text': prompt}
                    ]
                  }
                ],
                'generationConfig': {
                  'responseMimeType': 'application/json',
                },
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          final rawJsonText =
              body['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '{}';
          final parsed = jsonDecode(rawJsonText) as Map<String, dynamic>;

          final cloudBullets = (parsed['summaryBullets'] as List<dynamic>? ?? [])
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList();
          final counterQuestions =
              (parsed['journalistCounterQuestions'] as List<dynamic>? ?? [])
                  .map((e) => e.toString())
                  .where((s) => s.isNotEmpty)
                  .toList();
          final rolesRaw = parsed['speakerRoles'] as Map<String, dynamic>? ?? {};

          return InterviewSummaryResult(
            summaryBullets: onDeviceBullets.isNotEmpty
                ? [...onDeviceBullets, ...cloudBullets].take(5).toList()
                : cloudBullets,
            journalistCounterQuestions: counterQuestions,
            speakerRoles: rolesRaw.map((k, v) => MapEntry(k, v.toString())),
            keyHeadline: parsed['keyHeadline'] as String? ?? 'Live Interview Analysis',
            sourceLabel: onDeviceBullets.isNotEmpty
                ? 'ML Kit Gemini Nano + Gemini 2.5 Flash'
                : 'Gemini 2.5 Flash Cloud',
          );
        }
      } catch (_) {
        // Fall through to instant on-device analysis if offline or API error
      }
    }

    // 3. Instant On-Device Journalist Counter-Question & Summary Engine (works 100% offline without API key)
    final localBullets = onDeviceBullets.isNotEmpty
        ? onDeviceBullets
        : _buildOnDeviceExtractiveSummary(entries);
    final localCounterQuestions = _buildOnDeviceJournalistCounterQuestions(entries);

    return InterviewSummaryResult(
      summaryBullets: localBullets,
      journalistCounterQuestions: localCounterQuestions,
      keyHeadline: entries.last.text.length > 85
          ? '${entries.last.text.substring(0, 85)}...'
          : entries.last.text,
      sourceLabel: onDeviceBullets.isNotEmpty
          ? 'On-Device ML Kit (Gemini Nano)'
          : 'On-Device Journalist Engine',
    );
  }

  List<String> _buildOnDeviceExtractiveSummary(List<TranscriptEntry> entries) {
    final substantive = entries
        .where((e) => e.text.trim().split(RegExp(r'\s+')).length >= 4)
        .toList();
    if (substantive.isEmpty) {
      return entries.map((e) => '${e.speaker}: ${e.text}').take(3).toList();
    }

    // Score turns by information density (numbers, key verbs, length, recency)
    final scored = substantive.asMap().entries.map((item) {
      final text = item.value.text;
      final words = text.split(RegExp(r'\s+'));
      double score = words.length.clamp(5, 35).toDouble();
      if (RegExp(r'\d+').hasMatch(text)) score += 12;
      if (RegExp(
              r'\b(because|therefore|plan|policy|million|billion|percent|report|decision|future|problem|solution|promise|target)\b',
              caseSensitive: false)
          .hasMatch(text)) {
        score += 10;
      }
      // Slight recency boost
      score += (item.key / substantive.length) * 6.0;
      return MapEntry(item.value, score);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return scored
        .take(3)
        .map((e) => '${e.key.speaker}: "${e.key.text}"')
        .toList();
  }

  List<String> _buildOnDeviceJournalistCounterQuestions(List<TranscriptEntry> entries) {
    final recentTurns = entries.reversed.take(5).toList();
    final combinedRecent = recentTurns.map((e) => e.text).join(' ');
    final lastStatement = entries.last.text.trim();
    final shortQuote = lastStatement.length > 65
        ? '${lastStatement.substring(0, 65)}...'
        : lastStatement;

    final questions = <String>[];

    // 1. Probe numbers, budgets, percentages, or timelines
    if (RegExp(r'\b(\d+|percent|million|billion|year|month|growth|budget|cost)\b',
            caseSensitive: false)
        .hasMatch(combinedRecent)) {
      questions.add(
        'You referenced specific figures or timelines ("$shortQuote") — what independent data or audit verifies those numbers, and what happens if that target is missed?',
      );
    }

    // 2. Probe future promises / commitments ("will", "plan", "going to", "working on")
    if (RegExp(r'\b(will|plan|going to|commit|promise|expect|aim|working on)\b',
            caseSensitive: false)
        .hasMatch(combinedRecent)) {
      questions.add(
        'Regarding your plan ("$shortQuote"), what concrete milestones can the public hold you accountable to in the next 90 days, and what is the biggest obstacle?',
      );
    }

    // 3. Probe generalizations or absolutes ("always", "never", "everyone", "best", "completely")
    if (RegExp(r'\b(always|never|everyone|nobody|completely|totally|best|guaranteed|impossible)\b',
            caseSensitive: false)
        .hasMatch(combinedRecent)) {
      questions.add(
        'Critics and affected stakeholders would push back on "$shortQuote" — what is the strongest counter-evidence to your position, and how do you address those impacted?',
      );
    }

    // 4. Always provide sharp journalistic follow-ups anchored to the latest statement
    if (questions.length < 3) {
      questions.add(
        'Following up on "$shortQuote": what specific evidence or real-world example backs that up right now?',
      );
    }
    if (questions.length < 3) {
      questions.add(
        'Who bears direct responsibility if the outcome you described in "$shortQuote" does not materialize, and what is your contingency plan?',
      );
    }
    if (questions.length < 3) {
      questions.add(
        'What is the one part of this issue you have not mentioned yet that critics would say is the real root cause?',
      );
    }

    return questions.take(3).toList();
  }
}
