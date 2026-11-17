# Rules for all Flexo League marketing agents

## Paths
DATA = `marketing/data/` in this repo (env MARKETING_DATA overrides it). Cartoon project: `marketing/cartoon/`. Series files: `marketing/series/`. Skill: `.claude/skills/inkbeat-shorts` (read its SKILL.md and the references it points to before building anything).
The owner speaks Russian: talk to them in Russian. Videos, voice-over, captions and post texts are in casual US English (the launch market is the USA).

## How we work (the owner's decision 2026-11-17)
The agency works ONLY with the inkbeat-shorts skill: one recurring 3D cartoon character with the Flexo League logo on his shirt/hoodie, one continuous storyline, storytelling episodes of about a minute,
and at the end of every episode the viewer is sent to the app. Nothing from the older pipeline (app-screen motion graphics, beat.py, render.js) is used any more.
Follow the skill's workflow exactly: plan first, look-dev next, then the final render, QA, honest weak-points list. Give feedback per its format (what is wrong, where, what instead).
Voice-over: the skill needs `vo/voice.wav`, `vo/script.txt`, `vo/timings.json`. Make the voice with a free local tool (macOS `say -v` with a good English voice, converted by ffmpeg to wav; or another free local TTS) and the word timings with free local Whisper, as the skill says. Never use paid services or a cloned/real person's voice.

## Product facts (only claim these)
Flexo League is a free gamified gym app (iOS + Android): trophies for every workout and daily goals, 17 ranks from Basement to Legend, 7-day duels with friends, clans and clan battles, lift tracking with PR charts, calories/sleep/water, technique guides, honest rating with anti-cheat. No ads in the app. App Store: live; Google Play: not yet public.

## Hard rules
- Never invent user numbers, ratings, awards, reviews, prizes, results (weight loss etc.) or features. No health/medical promises, no body shaming, no competitor names or logos.
- Own characters and designs only. Reference frames of other channels stay private on the Mac (`marketing/cartoon/ref/`, never committed or published), learn light/rhythm only.
- Only music you may legally use: the skill can generate a simple original bed.
- Text must be readable with sound off. The first 2 seconds show the key object. The last scene is the app CTA (the logo + "Flexo League", say where to get it: App Store; no fake links).
- Publishing happens only if `<DATA>/agency/config.json` has "publish": true (the owner ticks the panel checkbox) and only for finished, QA-passed episodes, once per platform.
- Large files stay on the Mac; each video must be under 10 MB for the Chrome upload (re-encode with ffmpeg if needed).
