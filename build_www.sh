#!/usr/bin/env bash
# Собирает www/ из ../index.html: библиотеки кладём локально, чтобы приложение открывалось без сети.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/../index.html}"
SCR="$HERE/.."
mkdir -p "$HERE/www/vendor"
cp "$SCR/vendor/node_modules/chart.js/dist/chart.umd.js" "$HERE/www/vendor/chart.umd.js"
cp "$SCR/vendor/node_modules/chartjs-adapter-date-fns/dist/chartjs-adapter-date-fns.bundle.min.js" "$HERE/www/vendor/chartjs-adapter-date-fns.bundle.min.js"
cp "$SCR/vendor/supabase/dist/umd/supabase.js" "$HERE/www/vendor/supabase.js"
# Tailwind: компилируем CSS под классы из index.html
cd "$SCR/vendor"
cat > tw.config.js <<'C'
module.exports = { darkMode: 'class', content: [process.env.TW_SRC], theme: { extend: { colors: { bg: '#0B0E14', card: '#121824', line: '#1E293B', em: '#10B981', bl: '#3B82F6', or: '#F97316', pu: '#8B5CF6' } } } }
C
echo '@tailwind base;@tailwind components;@tailwind utilities;' > tw.in.css
TW_SRC="$SRC" npx tailwindcss -c tw.config.js -i tw.in.css -o "$HERE/www/vendor/tw.css" --minify >/dev/null 2>&1
sed -e 's#<script src="https://cdn.tailwindcss.com"></script>#<link rel="stylesheet" href="vendor/tw.css">#' \
    -e 's#https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js#vendor/chart.umd.js#' \
    -e 's#https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js#vendor/chartjs-adapter-date-fns.bundle.min.js#' \
    -e 's#https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/dist/umd/supabase.min.js#vendor/supabase.js#' \
    -e 's#^tailwind.config = #window.tailwind = {}; tailwind.config = #' \
    "$SRC" > "$HERE/www/index.html"
echo "www built: $(wc -c < "$HERE/www/index.html") bytes"
