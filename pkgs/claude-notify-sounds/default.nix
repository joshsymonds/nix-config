# Two synthesized notification chimes for the ntfy → desktop popup path
# (see home-manager/ntfy-notify/). Generated at build time with sox so
# there's zero licensing, no fetched asset, and the timbre is tunable by
# editing the recipe below and rebuilding. Auditioned interactively
# before committing; the exact numbers ARE the design, don't "round".
#
#   done.wav      calm D5 sine with a soft swell-in + a faint octave and
#                 a little room — "clarifying and soothing", NOT a struck
#                 mallet. Plays on Stop / finished.
#   needs-you.wav fast ascending G5→A#5→D6 triple, bright glockenspiel
#                 (inharmonic partials + noise strike). Plays on the
#                 Notification event — Claude is parked waiting on you.
#
# The two are composed as a pair in G minor: needs-you is a rising
# G–B♭–D arpeggio (the "question"); done rests on D (the triad's fifth,
# two octaves below where the arpeggio resolves), so the cues sound
# like one matched key, not two coincidental beeps. Keep that
# relationship if you retune.
{
  lib,
  runCommand,
  sox,
  gawk,
}:
runCommand "claude-notify-sounds" {
  nativeBuildInputs = [sox gawk];
  meta = {
    description = "Synthesized done / needs-you notification chimes for the ntfy popup path";
    license = lib.licenses.cc0;
    platforms = lib.platforms.all;
  };
} ''
  mkdir -p "$out"

  # --- done: soothing sine, soft swell-in, faint octave, light room ---
  # No noise strike and a slow (30 ms) attack: that's what makes it read
  # as "clarifying" rather than a xylophone hit. F=D5, octave at 0.12.
  F=587; T=0.58; A=0.030; OA=0.12; RV=10
  sox -n c_f.wav synth $T sine $F \
    fade h $A $T "$(awk -v T=$T -v A=$A 'BEGIN{print T-A-0.01}')"
  sox -n c_o.wav synth $T sine "$(awk -v F=$F 'BEGIN{print F*2}')" \
    fade h $A "$(awk -v T=$T 'BEGIN{print T*0.75}')" \
                "$(awk -v T=$T 'BEGIN{print T*0.6}')" vol $OA
  sox -M c_f.wav c_o.wav -c 1 "$out/done.wav" remix - \
    reverb $RV 50 100 40 0 0 lowpass 7000 gain -n -10

  # --- needs-you: bright struck-metal triple, ascending G minor ---
  # strike <freq> <ring-s> <out> : inharmonic partial stack (higher
  # partials quieter and dying sooner, like a real bar) + a 3 ms
  # white-noise strike transient + a 5.43x sparkle partial and a higher
  # lowpass for glockenspiel brightness.
  strike(){
    local Fr=$1 Tr=$2 O=$3
    : > parts
    add(){
      local r=$1 a=$2 dk=$3 f n fo
      f=$(awk -v F=$Fr -v r=$r 'BEGIN{print F*r}')
      n=$(awk -v T=$Tr -v dk=$dk 'BEGIN{print T*dk}')
      fo=$(awk -v n=$n 'BEGIN{x=n-0.003; if(x<n*0.4)x=n*0.4; print x}')
      sox -n "s_$r.wav" synth "$n" sine "$f" fade h 0.001 "$n" "$fo" vol "$a"
      echo "s_$r.wav" >> parts
    }
    add 1.00 1.00 1.00
    add 2.01 0.45 0.60
    add 2.76 0.32 0.42
    add 4.07 0.16 0.26
    add 5.43 0.12 0.20
    sox -n sk.wav synth 0.003 whitenoise fade h 0 0.003 0.003 vol 0.28
    echo sk.wav >> parts
    sox -M $(cat parts) -c 1 "$O" remix - \
      reverb 9 50 100 60 0 0 lowpass 8500 gain -n -7
  }
  strike 784  0.13  u1.wav
  strike 932  0.13  u2.wav
  strike 1175 0.195 u3.wav
  sox -n ug.wav synth 0.018 sine 1 vol 0
  sox u1.wav ug.wav u2.wav ug.wav u3.wav "$out/needs-you.wav"
''
