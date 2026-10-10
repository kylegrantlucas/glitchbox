// Boundary-only cross-mosh.
// Pass source motion vectors through unchanged EXCEPT in a window centered at
// `boundary_frame`. Inside the window, apply mv_average smearing with a divisor
// that ramps down (stronger smear) toward the boundary center, then back up.
//
// Use for datamoshing a scene transition — the loop_end plays clean, a brief
// smear happens across the seam, then the second clip resolves.

const total_frames = 4020;     // 30fps * 134s
const boundary_frame = 2010;   // 30fps * 67s = concat seam
const window_half = 45;        // ±45 frames = ±1.5s smear window
const max_tail = 12;
const min_divisor = 2;         // strongest amplification at the boundary center

let prev_fwd_mvs = [];
let total_sum;
let frame_idx = 0;

export function setup(args) {
  args.features = ["mv"];
}

export function glitch_frame(frame) {
  const fwd_mvs = frame.mv?.forward;
  if (!fwd_mvs) { frame_idx++; return; }
  frame.mv.overflow = "truncate";

  const dc = fwd_mvs.dup();
  prev_fwd_mvs.push(dc);

  if (!total_sum) total_sum = new MV2DArray(fwd_mvs.width, fwd_mvs.height);
  if (prev_fwd_mvs.length > max_tail) {
    total_sum.sub(prev_fwd_mvs[0]);
    prev_fwd_mvs = prev_fwd_mvs.slice(1);
  }
  total_sum.add(dc);

  const local_idx = frame_idx;
  frame_idx++;

  const dist = Math.abs(local_idx - boundary_frame);
  if (dist > window_half) return;               // outside window: pass through
  if (prev_fwd_mvs.length < max_tail) return;   // history not primed yet

  // Divisor curve: max_tail at window edges (light), min_divisor at boundary (heavy)
  const proximity = 1 - (dist / window_half);   // 0 at edges, 1 at center
  const divisor = Math.max(min_divisor,
    Math.round(max_tail - (max_tail - min_divisor) * proximity));

  fwd_mvs.assign(total_sum);
  fwd_mvs.div(MV(divisor, divisor));
}
