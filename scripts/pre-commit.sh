#!/bin/bash
# Ragex Git Pre-Commit Hook
# Prevents committing code with security issues or high complexity spikes.

# Find staged files (excluding deletions)
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(ex|exs|py|js|ts|tsx)$')

if [ -z "$STAGED_FILES" ]; then
  exit 0
fi

echo "===================================================="
echo "🔍 Running Ragex Pre-Commit Code Quality Audit..."
echo "===================================================="

# Run mix ragex.ci against current HEAD to check new staged changes
mix ragex.ci --base HEAD

CI_EXIT_CODE=$?

if [ $CI_EXIT_CODE -ne 0 ]; then
  echo "===================================================="
  echo "❌ Commit rejected! Please fix the issues reported above."
  echo "===================================================="
  exit 1
fi

echo "===================================================="
echo "✅ Code quality check passed. Committing..."
echo "===================================================="
exit 0
