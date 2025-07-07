#!/bin/bash

echo "🔍 Listing .sh files in /deploy_projects:"
for f in /deploy_projects/*.sh; do
  echo " - $f"
done

echo ""
echo "🛠️  Fixing shebang (removing Windows-style line endings)..."
for f in /deploy_projects/*.sh; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f"
done

echo "✅ Fixed deployment scripts"
