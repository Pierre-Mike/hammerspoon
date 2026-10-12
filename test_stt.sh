#!/bin/zsh
# Side-by-side speech-to-text comparison on a single recording.
#
# Benches every model the menubar picker offers — the same scan apps/dictation
# runs, so what you compare here is exactly what you can select there. Download a
# model (`hf download <repo>`) and it joins both lists; nothing here needs editing.
#
# How to test your own voice:
#   1. Dictate once (hold Fn and speak) — this leaves the clip at /tmp/hs-dictate.wav
#   2. Run:  ~/.hammerspoon/test_stt.sh
#   3. Compare the transcripts of the SAME audio, with wall-clock cost per model.
#
# Optional: pass a wav path as $1, and set the language hint via STT_LANG (en|fr|…).
#   STT_LANG=fr ~/.hammerspoon/test_stt.sh ~/some_clip.wav
set -u
zmodload zsh/datetime
WAV="${1:-/tmp/hs-dictate.wav}"
LANG_HINT="${STT_LANG:-en}"
if [[ ! -f "$WAV" ]]; then
  print -u2 "No audio at $WAV — dictate once (hold Fn), then re-run."
  exit 1
fi

OUT=/tmp/stt-test; mkdir -p "$OUT"
HF_HUB="$HOME/.cache/huggingface/hub"
CACTUS_CACHE="$HOME/.cache/cactus-needle"
PARAKEET="$HOME/.local/bin/parakeet-mlx"
MLXA_PY="$HOME/.local/share/uv/tools/mlx-audio/bin/python"
CACTUS_PY="$HOME/.hammerspoon/.venv-cactus/bin/python"
FFPROBE=/opt/homebrew/bin/ffprobe
base="$(basename "${WAV%.*}")"
DUR=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null)
DUR=${DUR:-0}

# mlx-audio STT architectures (mlx_audio/stt/models/*) plus the "parakeet" marker
# the scan below synthesises for NeMo configs. Keep in step with ENGINES in
# lib/stt_server.lua — that table is the one the picker reads.
TYPES=(parakeet qwen3_asr mega_asr cohere_asr granite_speech granite_speech_nar
       whisper glm glmasr voxtral voxtral_realtime nemotron_asr fun_asr_nano
       fireredasr2 sensevoice canary moonshine vibevoice)

# Emit "repo<TAB>engine" for every fully-downloaded speech model in the HF cache.
scan_models() {
  local d s ty t; local -a inc
  for d in "$HF_HUB"/models--*(N); do
    [[ -d "$d" ]] || continue
    inc=("$d"/blobs/*.incomplete(N)); (( ${#inc} )) && continue   # download still in flight
    s=(${~d}/snapshots/*(N/)); [[ -n "${s[1]:-}" ]] || continue; s="${s[1]%/}"
    [[ -f "$s/config.json" ]] || continue
    [[ -e "$s/model.safetensors" || -e "$s/model.safetensors.index.json" ]] || continue
    ty=$(grep -o '"model_type"[^,}]*' "$s/config.json" | grep -o '"[A-Za-z0-9_]*"$' | tr -d '"')
    grep -q 'nemo\.collections\.asr\.models' "$s/config.json" && ty=$'parakeet\n'"$ty"
    for t in ${(f)ty}; do
      if (( ${TYPES[(Ie)$t]} )); then
        printf '%s\t%s\n' "${${d:t}#models--}" "$([[ $t == parakeet ]] && echo parakeet || echo mlxa)"
        break
      fi
    done
  done
  # Whistle lives outside the hub: a lone .cact file, no config.json to read an
  # engine off, so it is globbed by name the way apps/dictation globs it. The
  # sibling v2/ and v3/ folders hold Needle, a tool-calling LLM, and stay out.
  local c
  for c in "$CACTUS_CACHE"/whistle/*/whistle.cact(N); do
    printf '%s\t%s\n' "$c" cactus
  done
}

report() {  # $1 = seconds, $2 = transcript file glob
  printf '   (%.1fs' "$1"
  (( DUR > 0 )) && printf ', %.1fx realtime' "$(( DUR / $1 ))"
  printf ')\n'
  cat ${~2}(N) 2>/dev/null | fold -s -w 96 | sed 's/^/   /'
}

run_parakeet() {  # $1 = repo
  rm -f "$OUT/$base.txt"
  local t0=$EPOCHREALTIME
  "$PARAKEET" --model "$1" --output-format txt --output-dir "$OUT" "$WAV" >"$OUT/err.log" 2>&1
  local rc=$?
  (( rc )) && { printf '   FAILED (rc=%d)\n' $rc; sed 's/^/   | /' <<<"$(tail -3 "$OUT/err.log")"; return; }
  report "$(( EPOCHREALTIME - t0 ))" "$OUT/$base.txt"
}

run_mlxa() {  # $1 = repo
  rm -f "$OUT"/batch*.txt
  local t0=$EPOCHREALTIME
  "$MLXA_PY" -m mlx_audio.stt.generate --model "$1" --audio "$WAV" \
    --output-path "$OUT/batch" --format txt --language "$LANG_HINT" >"$OUT/err.log" 2>&1
  local rc=$?
  (( rc )) && { printf '   FAILED (rc=%d)\n' $rc; sed 's/^/   | /' <<<"$(tail -4 "$OUT/err.log")"; return; }
  report "$(( EPOCHREALTIME - t0 ))" "$OUT/batch*.txt"
}

run_cactus() {  # $1 = path to whistle.cact
  local t0=$EPOCHREALTIME
  NEEDLE_TELEMETRY=0 "$CACTUS_PY" -c '
import sys, needle
w = needle.Whistle(weights=sys.argv[1])
langs = ("en","de","fr","es","it","nl","pl")
lang = sys.argv[3] if sys.argv[3] in langs else None
print((w.transcribe(sys.argv[2], language=lang).get("text") or "").strip())
' "$1" "$WAV" "$LANG_HINT" >"$OUT/cactus.txt" 2>"$OUT/err.log"
  local rc=$?
  (( rc )) && { printf '   FAILED (rc=%d)\n' $rc; sed 's/^/   | /' <<<"$(tail -4 "$OUT/err.log")"; return; }
  report "$(( EPOCHREALTIME - t0 ))" "$OUT/cactus.txt"
}

printf '================ STT comparison: %s (%.1fs) ================\n' "$WAV" "$DUR"
scan_models | while IFS=$'\t' read -r dir engine; do
  case "$engine" in
    # A cactus row carries the weights path, not a repo directory name.
    cactus)   printf '\n### %s  [%s]\n' "Cactus-Compute/whistle" "$engine"; run_cactus "$dir" ;;
    parakeet) printf '\n### %s  [%s]\n' "${dir//--//}" "$engine"; run_parakeet "${dir//--//}" ;;
    *)        printf '\n### %s  [%s]\n' "${dir//--//}" "$engine"; run_mlxa "${dir//--//}" ;;
  esac
done
printf '\n============================================================\n'
printf 'Cold-load times: the picker keeps a parakeet model warm, so in the app a\n'
printf 'streaming model costs ~0.2s where these numbers show seconds.\n'
