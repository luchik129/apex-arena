# Daily marketing run

Runs every day as a scheduled Claude task in the project thread "Настроить автопостинг видео в соцсети",
or on the owner's computer with `/marketing-day`. DAY = today (YYYY-MM-DD). DATA = see "Paths" in playbook.md.

1. Update the repo so the engine and these prompts are current.
2. Analyst (`.claude/agents/marketing-analyst.md`) → DATA/reports/DAY.md
3. Writer (`.claude/agents/marketing-writer.md`) → DATA/days/DAY/scripts/*.json (3 scripts)
4. Editor (`.claude/agents/marketing-editor.md`) → DATA/days/DAY/videos/*.mp4 + captions.md
5. Hand the 3 videos + captions.md to the owner.
6. Publishing: manual by the owner (TikTok, Instagram Reels, YouTube Shorts), captions from captions.md.
   `engine/post.py` (Upload-Post) only after the owner's explicit OK. When the owner says what was posted, set status "posted" + posted_at.
7. The owner drops analytics screenshots/CSVs into DATA/stats/ (or the thread) → the next day's analyst reads them.
