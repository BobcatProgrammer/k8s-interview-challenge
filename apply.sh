#!/usr/bin/env sh
# Commit any changes under gitops/ and push to Gitea.
# Usage: ./apply.sh [commit message]

set -e

MSG="${*:-fix: update manifests}"

if [ -z "$(git diff --name-only; git diff --cached --name-only)" ] && \
   [ -z "$(git ls-files --others --exclude-standard)" ]; then
  echo "Nothing to commit."
else
  git add gitops/
  git commit -m "$MSG"
  git push origin main
fi

echo ""
echo "Flux will reconcile within 30s. To trigger immediately:"
echo "  ./sync.sh"
