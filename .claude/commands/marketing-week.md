---
description: Run the Flexo League marketing team (analyst → writer → editor) for a new week of short videos
argument-hint: "[number of videos, default 7] [extra wishes]"
---
Run the weekly marketing pipeline described in `marketing/agents/PIPELINE.md`. Read `marketing/agents/playbook.md` first (Paths section).
Arguments from the owner: $ARGUMENTS

1. Use the `marketing-analyst` agent to update metrics and write the report.
2. Use the `marketing-writer` agent to write the scripts (count from the arguments, default 7; pass along any wishes).
3. Use the `marketing-editor` agent to render, check, fix and package the videos.
Between steps, give the owner a 1-2 line update in Russian. At the end, list the video files and the path to captions.md.
Never publish anything: posting is done by the owner, or with `marketing/engine/post.py --confirm` only after the owner explicitly says so.
