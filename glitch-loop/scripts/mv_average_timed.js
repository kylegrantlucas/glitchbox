// mv_average with a time gate: pass source MVs unchanged until frame `mosh_start`,
// then ramp in mv_average over `ramp_frames`, then apply every frame.

const total_frames = 3363;
const fps = 30;
const mosh_start = 40 * fps;                          // 40s
const ramp_frames = 8 * fps;                          // 8s ramp
const amplify_start = mosh_start + ramp_frames;       // 48s: begin amplifying
const tail_length = 10;
const min_divisor = 3;                                // full amplification (~3.3× true avg)

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

  const deep_copy = fwd_mvs.dup();
  prev_fwd_mvs.push(deep_copy);

  if (!total_sum) total_sum = new MV2DArray(fwd_mvs.width, fwd_mvs.height);

  if (prev_fwd_mvs.length > tail_length) {
    total_sum.sub(prev_fwd_mvs[0]);
    prev_fwd_mvs = prev_fwd_mvs.slice(1);
  }
  total_sum.add(deep_copy);

  const local_idx = frame_idx;
  frame_idx++;

  if (prev_fwd_mvs.length < tail_length) return;
  if (local_idx < mosh_start) return; // pre-mosh: leave source MVs alone

  // ramp: apply_every 30 → 1 over [mosh_start, amplify_start)
  let apply_every;
  if (local_idx >= amplify_start) {
    apply_every = 1;
  } else {
    const t = (local_idx - mosh_start) / ramp_frames;
    apply_every = Math.max(1, Math.round(30 - 29 * t));
  }
  if (local_idx % apply_every !== 0) return;

  // Divisor shrinks from tail_length → min_divisor across [amplify_start, total_frames)
  // Smaller divisor => MVs > true average => motion amplified => faster decay
  let divisor = tail_length;
  if (local_idx > amplify_start) {
    const back_frac = Math.min(1, (local_idx - amplify_start) / (total_frames - amplify_start));
    divisor = Math.max(min_divisor, Math.round(tail_length - (tail_length - min_divisor) * back_frac));
  }

  fwd_mvs.assign(total_sum);
  fwd_mvs.div(MV(divisor, divisor));
}
