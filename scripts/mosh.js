// mosh.js — parameterized motion-vector mosh for the Studio `mpeg2-mosh` plugin.
//
// Generalizes glitch-loop's length-independent scripts into one set of knobs,
// applied in this order on every frame's forward motion vectors:
//   tail     average each vector over the last N frames; 1 = off   (mv_average)
//   h_scale  horizontal components, percent; 0 = sink & rise       (mv_sink_and_rise)
//   v_scale  vertical components, percent
//   pan_x/y  add a constant drift                                  (mv_pan)
// Defaults (tail 10, scales 100, pan 0) behave exactly like mv_average.js.
//
// Params arrive via `ffedit -sp '{...}'` as args.params (NOT top-level args).
// ffedit's -sp parser rejects floating point, so scales are integer percents.
// No Math.random(): output is a pure function of input and params.

let tail = 10;
let h_scale = 1;
let v_scale = 1;
let pan_x = 0;
let pan_y = 0;

let history = [];
let total;

export function setup(args)
{
  args.features = [ "mv" ];
  const p = args.params || {};
  if ( p.tail !== undefined ) tail = Math.max(1, Math.round(p.tail));
  if ( p.h_scale !== undefined ) h_scale = p.h_scale / 100;
  if ( p.v_scale !== undefined ) v_scale = p.v_scale / 100;
  if ( p.pan_x !== undefined ) pan_x = Math.round(p.pan_x);
  if ( p.pan_y !== undefined ) pan_y = Math.round(p.pan_y);
}

export function glitch_frame(frame)
{
  const fwd_mvs = frame.mv?.forward;
  if ( !fwd_mvs )
    return;
  // Out-of-range vectors are clamped when written back to the bitstream.
  frame.mv.overflow = "truncate";

  if ( tail > 1 )
  {
    // Running sum over a sliding window of clean (pre-modification) vectors.
    const clean = fwd_mvs.dup();
    history.push(clean);
    if ( !total )
      total = new MV2DArray(fwd_mvs.width, fwd_mvs.height);
    if ( history.length > tail )
    {
      total.sub(history[0]);
      history = history.slice(1);
    }
    total.add(clean);
    if ( history.length == tail )
    {
      fwd_mvs.assign(total);
      fwd_mvs.div(MV(tail, tail));
    }
  }

  if ( h_scale === 0 && v_scale === 1 )
  {
    fwd_mvs.assign_h(0);
  }
  else if ( h_scale !== 1 || v_scale !== 1 )
  {
    for ( let i = 0; i < fwd_mvs.length; i++ )
    {
      const row = fwd_mvs[i];
      for ( let j = 0; j < row.length; j++ )
      {
        const mv = row[j];
        mv[0] = Math.round(mv[0] * h_scale);
        mv[1] = Math.round(mv[1] * v_scale);
      }
    }
  }

  if ( pan_x !== 0 || pan_y !== 0 )
    fwd_mvs.add(MV(pan_x, pan_y));
}
