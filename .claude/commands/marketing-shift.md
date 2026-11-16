---
description: One shift of the Flexo League marketing agency (council, analyst, writer, editor, publisher). Run by the Start button.
argument-hint: "[extra wishes]"
---
One work shift of the agency. Read `marketing/agents/playbook.md` and `marketing/agents/PIPELINE.md` first.
Owner wishes: $ARGUMENTS

Update `<DATA>/agency/state.json` field "step" before each step (so the city shows what is going on), then:
1. `marketing-analyst`: report. 2. `marketing-director`: council, decisions, plan. 3. `marketing-writer`: scripts per the plan.
4. `marketing-editor`: render and check videos. 5. `marketing-publisher`: posting.md; it publishes ONLY if `<DATA>/agency/config.json` has "publish": true,
   and then only the videos of today's batch, once per platform. If "publish" is false, prepare everything and stop there.
6. Run `python3 marketing/agency/export_city.py` so the city shows the new numbers, roster and decisions.
If the file `<DATA>/agency/STOP` exists, finish the current step cleanly, remove nothing else, and end the shift.
