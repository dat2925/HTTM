import 'package:flutter/material.dart';

import '../models/session_state.dart';

/// Status bar: red background + big text while [SessionState.isAlerting],
/// with a smaller line showing which stream (route vs. camera) drove the
/// current decision.
class StatusPanel extends StatelessWidget {
  const StatusPanel({super.key, required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final alerting = state.isAlerting;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      color: alerting ? Colors.red.shade700 : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            state.statusText,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: alerting ? Colors.white : null,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (state.subStatusText != null) ...[
            const SizedBox(height: 6),
            Text(
              state.subStatusText!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: alerting ? Colors.white70 : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
