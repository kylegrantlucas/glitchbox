// glitchbox — deterministic motion-vector displacement for `mv-mangle`.
//
// Seeded xorshift32, never Math.random(). QuickJS exposes no way to seed the
// global PRNG, so a Math.random()-based script is unreproducible by
// construction. Every draw here derives from `seed`.
//
// Params arrive as args.params (NOT as top-level keys on args — ffedit nests
// the -sp JSON under `params`; reading args.seed silently yields undefined and
// pins every run to the default seed while the manifest claims otherwise):
//
//   ffedit -sp '{"seed":42,"amount":8}'
//     seed    integer, default 1   pinned + logged in the run manifest
//     amount  integer, default 8   max per-axis displacement, in MV units
//
// Motion vectors are clamped to the codec's legal range, derived from the
// frame's fcode. Without this, ffedit warns per-MV ("value 32 outside of range
// [-32,31]") and truncates, which collapses distinct seeds toward identical
// saturated output.

let rng_state;
let amount;

function xorshift32() {
  rng_state ^= (rng_state << 13); rng_state >>>= 0;
  rng_state ^= (rng_state >>> 17);
  rng_state ^= (rng_state << 5);  rng_state >>>= 0;
  return rng_state / 4294967296;
}

function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

export function setup(args) {
  args.features = [ "mv" ];
  const p = args.params || {};
  const seed = (p.seed !== undefined) ? p.seed : 1;
  amount = (p.amount !== undefined) ? p.amount : 8;
  rng_state = (seed >>> 0) || 1;
}

export function glitch_frame(frame, stream) {
  const mvs = frame["mv"];
  if ( !mvs ) return;
  const fwd = mvs["forward"];
  if ( !fwd ) return;

  // Legal MV range for this frame, per libavcodec's fcode encoding.
  const fcode = mvs["fcode"] ? mvs["fcode"][0] : 1;
  const shift = (stream && stream.codec === "mpeg2video") ? 5 : 6;
  const bound = 1 << (shift + (fcode - 1) - 1);
  const min_val = -bound;
  const max_val = bound - 1;

  for ( let i = 0; i < fwd.length; i++ ) {
    const row = fwd[i];
    if ( !row ) continue;
    for ( let j = 0; j < row.length; j++ ) {
      const mv = row[j];
      if ( !mv ) continue;
      mv[0] = clamp(mv[0] + Math.round((xorshift32() * 2 - 1) * amount), min_val, max_val);
      mv[1] = clamp(mv[1] + Math.round((xorshift32() * 2 - 1) * amount), min_val, max_val);
    }
  }
}
