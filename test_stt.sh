#!/bin/zsh
# Side-by-side speech-to-text comparison on a single recording.
#
# How to test your own voice:
#   1. Dictate once (hold Fn and speak) — this leaves the clip at /tmp/hs-dictate.wav
#   2. Run:  ~/.hammerspoon/test_stt.sh
#   3. Compare the three transcripts of the SAME audio.
#
# Optional: pass a wav path as $1, and set the language hint via STT_LANG (en|fr|…).
#   STT_LANG=fr ~/.hammerspoon/test_stt.sh ~/some_clip.wav
set -u
WAV="${1:-/tmp/hs-dictate.wav}"
LANG_HINT="${STT_LANG:-en}"
if [[ ! -f "$WAV" ]]; then
  print -u2 "No audio at $WAV — dictate once (hold Fn), then re-run."
  exit 1
fi

OUT=/tmp/stt-test; mkdir -p "$OUT"
PARAKEET="$HOME/.local/bin/parakeet-mlx"
MLXA_PY="$HOME/.local/share/uv/tools/mlx-audio/bin/python"
base="$(basename "${WAV%.*}")"

run_parakeet() {  # $1 = repo, $2 = label
  printf '\n### %s\n' "$2"
  local t0=$EPOCHREALTIME
  "$PARAKEET" --model "$1" --output-format txt --output-dir "$OUT" "$WAV" >/dev/null 2>&1
  printf '%s\n' "$(cat "$OUT/$base.txt" 2>/dev/null)"
  printf '   (%.1fs)\n' "$(( EPOCHREALTIME - t0 ))"
}

printf '================ STT comparison: %s ================\n' "$WAV"
run_parakeet "mlx-community/parakeet-tdt-0.6b-v3" "parakeet v3 · multilingual (your current)"
run_parakeet "mlx-community/parakeet-tdt-1.1b"    "parakeet 1.1b · English (larger)"

printf '\n### Qwen3-ASR-1.7B-4bit · SOTA multilingual (lang=%s)\n' "$LANG_HINT"
t0=$EPOCHREALTIME
"$MLXA_PY" -m mlx_audio.stt.generate \
  --model mlx-community/Qwen3-ASR-1.7B-4bit \
  --audio "$WAV" --output-path "$OUT/qwen3" --format txt --language "$LANG_HINT" >/dev/null 2>&1
{ cat "$OUT"/qwen3*.txt 2>/dev/null } || true
printf '   (%.1fs)\n' "$(( EPOCHREALTIME - t0 ))"
printf '======================================================\n'
