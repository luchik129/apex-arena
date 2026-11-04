#!/usr/bin/env bash
# index.html -> www/index.html и docs/app/index.html (те же замены CDN, что в build_www.sh, без пересборки tailwind)
set -e; cd "$(dirname "$0")/../.."
sed -e 's#<script src="https://cdn.tailwindcss.com"></script>#<link rel="stylesheet" href="vendor/tw.css">#' \
    -e 's#https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js#vendor/chart.umd.js#' \
    -e 's#https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js#vendor/chartjs-adapter-date-fns.bundle.min.js#' \
    -e 's#https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/dist/umd/supabase.min.js#vendor/supabase.js#' \
    -e 's#^tailwind.config = #window.tailwind = {}; tailwind.config = #' \
    index.html > www/index.html
cp www/index.html docs/app/index.html
