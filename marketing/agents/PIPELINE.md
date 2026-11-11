# Weekly marketing run

Runs every Monday as a scheduled Claude task in the project thread "Настроить автопостинг видео в соцсети".
WEEK = date of that Monday (YYYY-MM-DD). DATA = /mnt/project-files/fitness/marketing/.

1. Update the repo (main) so the engine and these prompts are current.
2. Analyst agent (`.claude/agents/marketing-analyst.md`) → DATA/reports/WEEK.md
3. Writer agent (`.claude/agents/marketing-writer.md`) → DATA/weeks/WEEK/scripts/*.json (7 scripts)
4. Editor agent (`.claude/agents/marketing-editor.md`) → DATA/weeks/WEEK/videos/*.mp4 + captions.md
5. The thread posts the videos and captions.md to the owner for approval.
6. Publishing: manual by the owner for now (download from the thread, paste caption from captions.md),
   or via `engine/post.py` (Upload-Post) only after the owner's explicit OK for each batch.
   After posting, set status "posted" + posted_at in log.json.
7. Owner drops analytics screenshots/CSVs into the thread → saved into DATA/stats/ for next week's analyst.
