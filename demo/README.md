# Narrated demo

Builds `demo/Uberdoer-demo.mp4` (about 72 s, ElevenLabs voice "Sarah") from made-up sample data.

```bash
cd demo
# 1. Sample data (never the real database)
rm -f demo.sqlite*; python3 seed.py "$PWD/demo.sqlite" ../build/mac/Build/Products/Debug/Uberdoer.app/Contents/MacOS/uberdoer-mcp
# 2. Voice (cached; only changed scenes are re-voiced)
python3 ~/.claude/skills/elevenlabs-voiceover/scripts/voiceover.py narration.json --out audio
# 3. Record: the Debug app drives each scene and captures its own windows, timed to audio/durations.json
mkdir -p frames && cp audio/durations.json frames/
sqlite3 demo.sqlite ".backup rec.sqlite"
TASKER_DB=$PWD/rec.sqlite TASKER_NO_SYNC=1 TASKER_DEMO_DIR=$PWD/frames ../build/mac/Build/Products/Debug/Uberdoer.app/Contents/MacOS/Uberdoer
# 4. Encode, add the voice, join
S=~/.claude/skills/elevenlabs-voiceover/scripts; mkdir -p build
for d in frames/s0*/; do id=$(basename $d)
  ffmpeg -y -f concat -safe 0 -i $d/frames.ffconcat -vf "scale=1920:-2:flags=lanczos,fps=30,format=yuv420p" -c:v libx264 -crf 18 build/$id-v.mp4
  bash $S/mux.sh build/$id-v.mp4 audio/$id.mp3 build/$id.mp4; done
printf "file '%s'\n" $PWD/build/s0?_*.mp4 | grep -v -- "-v.mp4'" > build/list.txt
ffmpeg -y -f concat -safe 0 -i build/list.txt -c copy -movflags +faststart Uberdoer-demo.mp4
```

Scenes and their timelines are in `App/macOS/DemoRecorder.swift`; `TASKER_DEMO_SCENES=s02_quick,…` records only some.
The recording hides calendar events and the agent tags, and shows sync as healthy; it changes no saved settings.
