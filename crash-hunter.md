Run the Firebase Crashlytics crash hunter agent.

Queries BigQuery for top crashes, invokes Claude to analyze each one, and raises
draft PRs for crashes it can fix with HIGH confidence.

If the user passes a number (e.g. `/crash-hunter 7`), treat it as the lookback
window in days. If no argument is given, default is 1 day.

Steps:
1. Run `bash .claude/scripts/crash_hunter.sh $ARGUMENTS` and stream the output.
2. When it finishes, summarize:
   - How many crash groups were found
   - For each fixed crash: exception type, crash count, draft PR URL
   - For each skipped crash: issue title and reason it was skipped
   - If no crashes were found, say so clearly
3. If the script errors (BigQuery auth, git conflict, missing config), explain
   what went wrong and the exact command to fix it.
