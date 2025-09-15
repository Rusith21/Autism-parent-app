import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // debugPrint
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// ====== CONFIG ======
/// Android emulator: http://10.0.2.2:8000
/// iOS simulator:    http://localhost:8000
/// Physical device:  http://<your-PC-LAN-IP>:8000 http://34.122.210.99/predict
//const String BASE_URL = "http://172.20.10.2:8000";
const String BASE_URL = "http://34.122.210.99";

void main() {
  runApp(const MyApp());
}

/// Pretty-print JSON in logs
void logJson(String label, Object? data) {
  final enc = const JsonEncoder.withIndent('  ');
  debugPrint('$label:\n${enc.convert(data)}');
}

/// Simple card model (what we render & persist)
class Activity {
  final String id;
  final String name;        // shown on card title
  final String weeklyPlan;  // shown when expanded

  Activity({
    required this.id,
    required this.name,
    required this.weeklyPlan,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'weeklyPlan': weeklyPlan,
  };

  factory Activity.fromJson(Map<String, dynamic> json) => Activity(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    weeklyPlan: json['weeklyPlan'] ?? '',
  );
}

/// Response models (must match your Flask JSON)
class Top1Recommendation {
  final String activityId;
  final String? name;
  final String? description;
  final String? detailedDescription;
  final String? weeklyPlan;
  final double prob;

  Top1Recommendation({
    required this.activityId,
    this.name,
    this.description,
    this.detailedDescription,
    this.weeklyPlan,
    required this.prob,
  });

  factory Top1Recommendation.fromJson(Map<String, dynamic> json) {
    return Top1Recommendation(
      activityId: json['activity_id'] ?? '',
      name: json['name'],
      description: json['description'],
      detailedDescription: json['detailed_description'],
      weeklyPlan: json['weekly_plan'],
      prob: (json['prob'] ?? 0).toDouble(),
    );
  }
}

class PredictResponse {
  final Top1Recommendation? top1;
  final List<String> followUps;

  PredictResponse({required this.top1, required this.followUps});

  factory PredictResponse.fromJson(Map<String, dynamic> json) {
    return PredictResponse(
      top1: json['top1_recommendation'] == null
          ? null
          : Top1Recommendation.fromJson(json['top1_recommendation']),
      followUps: (json['follow_up_questions'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

/// Local storage helper
class TaskStorage {
  static const _finishedKey = 'finished_task_ids';
  static const _cardsKey = 'suggested_cards_v1'; // chain of cards

  static Future<List<String>> getFinished() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getStringList(_finishedKey) ?? <String>[];
  }

  static Future<void> addFinished(String id) async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_finishedKey) ?? <String>[];
    if (!list.contains(id)) {
      list.add(id);
      await sp.setStringList(_finishedKey, list);
    }
  }

  static Future<List<Activity>> getCards() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_cardsKey);
    if (raw == null) return <Activity>[];
    final List data = jsonDecode(raw) as List;
    return data.map((e) => Activity.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> saveCards(List<Activity> cards) async {
    final sp = await SharedPreferences.getInstance();
    final raw = jsonEncode(cards.map((e) => e.toJson()).toList());
    await sp.setString(_cardsKey, raw);
  }

  static Future<void> clearAll() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_cardsKey);
    await sp.remove(_finishedKey);
  }
}

/// POST to Flask /predict, with full request/response logging
Future<PredictResponse> submitToModel({
  required Map<String, dynamic> context,
  int topK = 5,
  int followupN = 3,
  List<String> excludeIds = const [], // 👈 NEW
}) async {
  final uri = Uri.parse('$BASE_URL/predict');
  final payload = {
    'top_k': topK,
    'followup_n': followupN,
    'context': context,
    'exclude_ids': excludeIds, // 👈 send to server
  };

  // 🔎 Outgoing request logs
  debugPrint('[HTTP] POST $uri');
  debugPrint('[HTTP] headers: {Content-Type: application/json}');
  logJson('[HTTP] body', payload);

  final res = await http
      .post(
    uri,
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(payload),
  )
      .timeout(const Duration(seconds: 15));

  // 🔎 Incoming response logs
  debugPrint('[HTTP] status: ${res.statusCode}');
  try {
    final decoded = jsonDecode(res.body);
    logJson('[HTTP] response JSON', decoded);
  } catch (_) {
    debugPrint('[HTTP] response (text): ${res.body}');
  }

  if (res.statusCode != 200) {
    throw Exception('Server ${res.statusCode}: ${res.body}');
  }
  return PredictResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

/// ===== UI =====
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      colorSchemeSeed: Colors.indigo,
      useMaterial3: true,
      cardTheme: const CardThemeData(
        margin: EdgeInsets.symmetric(vertical: 8),
      ),
    );
    return MaterialApp(
      title: 'Adaptive Tasks',
      theme: theme,
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _rand = Random();
  final ScrollController _scroll = ScrollController();

  bool _loading = true;
  List<Activity> _cards = [];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    // 1) Try to load existing chain of cards from storage
    final saved = await TaskStorage.getCards();

    if (saved.isNotEmpty) {
      setState(() {
        _cards = saved;
        _loading = false;
      });
      return;
    }

    // 2) No saved cards? Pick ONE random from default ACT001..3
    final defaults = <Activity>[
      Activity(
        id: 'ACT021',
        name: 'ACT021',
        weeklyPlan: 'Mon–Fri: 5 trials · Short sessions · Praise & reward',
      ),
      Activity(
        id: 'ACT102',
        name: 'ACT102',
        weeklyPlan:
        'Mon: intro · Tue: 5 trials · Wed: generalize · Thu: 5 trials · Fri: review',
      ),
      Activity(
        id: 'ACT153',
        name: 'ACT153',
        weeklyPlan: 'Daily: 3–5 trials · Use visuals · Fade prompts',
      ),
    ];
    final one = defaults[_rand.nextInt(defaults.length)];
    _cards = [one];
    await TaskStorage.saveCards(_cards);

    setState(() => _loading = false);
  }

  Future<void> _onFinish(Activity tappedCard) async {
    // Always use the LAST card’s ID, no matter which card was tapped
    final Activity current = _cards.isNotEmpty ? _cards.last : tappedCard;
    debugPrint('[APP] Finish tapped. Using LAST activity_id: ${current.id}');

    // 1) Get form answers (modal)
    final result = await showModalBottomSheet<_FormResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => QuestionFormSheet(activityId: current.id),
    );
    if (result == null) return;

    // 2) Build context payload
    final ctx = {
      'activity_id': current.id, // 👈 send last activity id
      'session_completed': result.sessionCompleted ? 'yes' : 'no',
      'engagement_rating': result.engagementRating,
      'independence_level': result.independenceLevel,
      'difficulty_feel': result.difficultyFeel,
      'behavior_issue': result.behaviorIssue ? 'yes' : 'no',
      'child_preference': result.childPreference,
      'time_fit': result.timeFit,
      'prompts_used_max': result.promptsUsedMax,
      'generalization_seen': result.generalizationSeen ? 'yes' : 'no',
    };
    logJson('[APP] Context payload (will send)', ctx);

    // 3) Build exclude list: last + all finished
    final finished = await TaskStorage.getFinished();
    final exclude = <String>{ current.id, ...finished }.toList();
    logJson('[APP] exclude_ids', exclude);

    try {
      // 4) Call model with excludeIds
      final resp = await submitToModel(
        context: ctx,
        topK: 5,
        followupN: 3,
        excludeIds: exclude, // 👈 important
      );

      // Keep a log of the parsed top1
      final rlog = {
        'activity_id': resp.top1?.activityId,
        'name': resp.top1?.name,
        'prob': resp.top1?.prob,
        'weekly_plan': resp.top1?.weeklyPlan,
      };
      logJson('[APP] Parsed top1', rlog);

      // store finished id as the LAST activity
      await TaskStorage.addFinished(current.id);

      // 5) Append NEW card from recommendation (no dedupe)
      final r = resp.top1;
      if (r != null) {
        final newCard = Activity(
          id: r.activityId,
          name: (r.name == null || r.name!.isEmpty) ? r.activityId : r.name!,
          weeklyPlan: r.weeklyPlan ?? '',
        );

        setState(() {
          _cards.add(newCard);
        });
        await TaskStorage.saveCards(_cards);

        // Auto-scroll to newest card
        await Future.delayed(const Duration(milliseconds: 50));
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      }

      if (!mounted) return;
      // 6) (Optional) Show details + follow-ups
      await showDialog(
        context: context,
        builder: (_) => RecommendationDialog(resp: resp),
      );
    } catch (e, st) {
      debugPrint('Error: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _resetAll() async {
    await TaskStorage.clearAll();
    setState(() {
      _cards.clear();
      _loading = true;
    });
    await _boot();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adaptive Tasks'),
        actions: [
          IconButton(
            tooltip: 'Reset (clear storage)',
            onPressed: _resetAll,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(12),
        itemCount: _cards.length,
        itemBuilder: (_, i) => _buildCard(_cards[i]),
      ),
    );
  }

  Widget _buildCard(Activity a) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: ElevatedButton(
          onPressed: () => _onFinish(a),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
          child: const Text('Finish'),
        ),
        title: Text(
          a.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        childrenPadding:
        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Row(
            children: const [
              Icon(Icons.calendar_today_outlined, size: 18),
              SizedBox(width: 8),
              Text('Weekly Plan',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(a.weeklyPlan.isEmpty ? '—' : a.weeklyPlan),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// ===== Modal Bottom Sheet: question form =====

class _FormResult {
  final bool sessionCompleted;
  final double engagementRating;
  final String independenceLevel; // low/medium/high
  final String difficultyFeel;    // too_easy/ok/too_hard
  final bool behaviorIssue;
  final String childPreference;
  final String timeFit;           // ok/too_short/too_long/mismatch
  final String promptsUsedMax;    // low/medium/high
  final bool generalizationSeen;

  _FormResult({
    required this.sessionCompleted,
    required this.engagementRating,
    required this.independenceLevel,
    required this.difficultyFeel,
    required this.behaviorIssue,
    required this.childPreference,
    required this.timeFit,
    required this.promptsUsedMax,
    required this.generalizationSeen,
  });
}

class QuestionFormSheet extends StatefulWidget {
  final String activityId;
  const QuestionFormSheet({super.key, required this.activityId});

  @override
  State<QuestionFormSheet> createState() => _QuestionFormSheetState();
}

class _QuestionFormSheetState extends State<QuestionFormSheet> {
  final _formKey = GlobalKey<FormState>();

  bool _sessionCompleted = true;
  double _engagement = 3; // 1..5
  String _independence = 'medium';
  String _difficulty = 'ok';
  bool _behaviorIssue = false;
  String _childPref = '';
  String _timeFit = 'ok';
  String _promptsMax = 'low';
  bool _generalizationSeen = false;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Finish ${widget.activityId}',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),

              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Session completed'),
                value: _sessionCompleted,
                onChanged: (v) => setState(() => _sessionCompleted = v),
              ),

              const SizedBox(height: 8),
              const Text('Engagement rating (1–5)'),
              Slider(
                value: _engagement,
                min: 1,
                max: 5,
                divisions: 8,
                label: _engagement.toStringAsFixed(1),
                onChanged: (v) => setState(() => _engagement = v),
              ),

              const SizedBox(height: 8),
              _DropdownRow(
                label: 'Independence level',
                value: _independence,
                items: const ['low', 'medium', 'high'],
                onChanged: (v) => setState(() => _independence = v!),
              ),

              const SizedBox(height: 8),
              _DropdownRow(
                label: 'Difficulty feel',
                value: _difficulty,
                items: const ['too_easy', 'ok', 'too_hard'],
                onChanged: (v) => setState(() => _difficulty = v!),
              ),

              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Behavior issue observed'),
                value: _behaviorIssue,
                onChanged: (v) => setState(() => _behaviorIssue = v),
              ),

              const SizedBox(height: 8),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Child preference (e.g., cars, animals)',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => _childPref = v.trim(),
              ),

              const SizedBox(height: 8),
              _DropdownRow(
                label: 'Time fit',
                value: _timeFit,
                items: const ['ok', 'too_short', 'too_long', 'mismatch'],
                onChanged: (v) => setState(() => _timeFit = v!),
              ),

              const SizedBox(height: 8),
              _DropdownRow(
                label: 'Prompts used (max)',
                value: _promptsMax,
                items: const ['low', 'medium', 'high'],
                onChanged: (v) => setState(() => _promptsMax = v!),
              ),

              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Generalization seen'),
                value: _generalizationSeen,
                onChanged: (v) => setState(() => _generalizationSeen = v),
              ),

              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.send),
                  label: const Text('Submit'),
                  onPressed: () {
                    if (_formKey.currentState?.validate() ?? true) {
                      final result = _FormResult(
                        sessionCompleted: _sessionCompleted,
                        engagementRating:
                        double.parse(_engagement.toStringAsFixed(1)),
                        independenceLevel: _independence,
                        difficultyFeel: _difficulty,
                        behaviorIssue: _behaviorIssue,
                        childPreference: _childPref,
                        timeFit: _timeFit,
                        promptsUsedMax: _promptsMax,
                        generalizationSeen: _generalizationSeen,
                      );
                      Navigator.of(context).pop(result);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DropdownRow extends StatelessWidget {
  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String?> onChanged;

  const _DropdownRow({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            value: value,
            items: items
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: onChanged,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
      ],
    );
  }
}

/// Info dialog showing model’s top1 + follow-ups
class RecommendationDialog extends StatelessWidget {
  final PredictResponse resp;
  const RecommendationDialog({super.key, required this.resp});

  @override
  Widget build(BuildContext context) {
    final r = resp.top1;
    final followUps = resp.followUps;
    return AlertDialog(
      title: const Text('Next Task Recommendation'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r != null) ...[
              Text(r.name ?? r.activityId,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text('ID: ${r.activityId} • P=${r.prob.toStringAsFixed(3)}'),
              const SizedBox(height: 12),
              if ((r.description ?? '').isNotEmpty) ...[
                const Text('Description',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(r.description!),
                const SizedBox(height: 12),
              ],
              if ((r.detailedDescription ?? '').isNotEmpty) ...[
                const Text('Detailed Description',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(r.detailedDescription!),
                const SizedBox(height: 12),
              ],
              if ((r.weeklyPlan ?? '').isNotEmpty) ...[
                const Text('Weekly Plan',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(r.weeklyPlan!),
                const SizedBox(height: 12),
              ],
            ],
            if (followUps.isNotEmpty) ...[
              const Divider(),
              const Text('Follow-up questions',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              for (final q in followUps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• $q'),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('OK')),
      ],
    );
  }
}
