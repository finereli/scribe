import React from 'react';
import {
  AbsoluteFill,
  continueRender,
  delayRender,
  Easing,
  Img,
  interpolate,
  interpolateColors,
  staticFile,
  useCurrentFrame,
} from 'remotion';

// The hero window from site/public/index.html, played once, then an end card.
// Values are copied from site/public/styles.css; departures are commented.

export const FPS = 30;
export const DURATION = 15 * FPS; // hold the end card ~5 s

// Seconds before the site's animation clock starts, so the window registers first.
const LEAD = 0.4;
// When the window gives way to the end card.
const OUTRO = 9.0;
// The window is laid out at 440px, the width it has on a phone-sized page
// (the CSS caps it at 520px), and zoomed so the transcript reads on a phone.
const ZOOM = 2.25;

type Theme = 'dark' | 'light';

const TOKENS: Record<Theme, Record<string, string>> = {
  light: {
    '--paper': '#F2F3F5',
    '--surface': '#FFFFFF',
    '--ink': '#1D1D1F',
    '--muted': '#5F6168',
    '--faint': '#8A8C93',
    '--line': '#DADCE1',
    '--me': '#0A84FF',
    '--them': '#FF9F0A',
    '--me-text': '#0062CC',
    '--them-text': '#A35700',
    '--window-shadow':
      '0 1px 1px rgba(0, 0, 0, 0.04), 0 12px 32px -8px rgba(30, 40, 60, 0.18), 0 40px 80px -24px rgba(30, 40, 60, 0.20)',
    '--segment-off': 'rgba(60, 60, 67, 0.16)',
  },
  dark: {
    '--paper': '#161618',
    '--surface': '#232326',
    '--ink': '#F2F2F4',
    '--muted': '#A6A7AD',
    '--faint': '#7D7E84',
    '--line': '#36363A',
    '--me': '#0A84FF',
    '--them': '#FF9F0A',
    '--me-text': '#5AABFF',
    '--them-text': '#FFB340',
    '--window-shadow': '0 0 0 1px rgba(255, 255, 255, 0.06), 0 24px 60px -20px rgba(0, 0, 0, 0.7)',
    '--segment-off': 'rgba(235, 235, 245, 0.14)',
  },
};

// SF Pro Rounded, which the page gets from ui-rounded in Safari. Chrome has no
// ui-rounded, so load the system copy (npm run fonts) and wait for it.
const fontHandle = delayRender('Loading SF Pro Rounded');
new FontFace('Scribe Rounded', `url(${staticFile('fonts/SFNSRounded.ttf')}) format("truetype")`, {weight: '1 1000'})
  .load()
  .then((face) => {
    document.fonts.add(face);
    continueRender(fontHandle);
  })
  .catch(() => continueRender(fontHandle));

const CSS = `
.stage {
  --rounded: "Scribe Rounded", ui-rounded, "SF Pro Rounded", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  --text: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  background: var(--paper);
  color: var(--ink);
  font-family: var(--text);
  font-size: 17px;
  line-height: 1.6;
  -webkit-font-smoothing: antialiased;
}
.stage *, .stage *::before, .stage *::after { box-sizing: border-box; }

.window {
  margin: 0;
  background: var(--surface);
  border-radius: 14px;
  box-shadow: var(--window-shadow);
  overflow: hidden;
  font-family: var(--text);
  width: 440px;
}
.titlebar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 13px 16px;
  border-bottom: 1px solid var(--line);
}
.titlebar > span:not(.send) { width: 12px; height: 12px; border-radius: 50%; }
.titlebar > span:nth-child(1) { background: #FF5F57; }
.titlebar > span:nth-child(2) { background: #FEBC2E; }
.titlebar > span:nth-child(3) { background: #28C840; }
.titlebar .send { margin-left: auto; display: flex; gap: 6px; }
.titlebar .ai {
  display: inline-flex; align-items: center;
  padding: 4px 6px;
  border-radius: 7px; background: var(--segment-off);
  color: var(--ink);
}
.titlebar .ai svg { width: 16px; height: 16px; display: block; }

.callhead {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 16px;
  padding: 16px 20px 14px;
  border-bottom: 1px solid var(--line);
}
.callhead strong { display: block; font-size: 17px; font-weight: 600; line-height: 1.3; }
.callhead small {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 13px;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}
.rec { width: 8px; height: 8px; border-radius: 50%; background: #FF3B30; }

.meters {
  display: grid;
  grid-template-columns: auto 92px;
  align-items: center;
  gap: 5px 8px;
  font-size: 10px;
  font-weight: 500;
  color: var(--muted);
}
.meter {
  position: relative;
  height: 6px;
  --segments: repeating-linear-gradient(90deg, #000 0 calc(5% - 2px), transparent calc(5% - 2px) 5%);
  -webkit-mask: var(--segments);
  mask: var(--segments);
  background: var(--segment-off);
}
.meter i {
  position: absolute;
  inset: 0;
  background: linear-gradient(90deg, #34C759 0 65%, #FFCC00 65% 85%, #FF3B30 85%);
}

.turns {
  list-style: none;
  margin: 0;
  padding: 8px 20px 22px;
  font-size: 14px;
  line-height: 1.55;
}
.turn {
  display: grid;
  grid-template-columns: 44px 1fr;
  column-gap: 14px;
  padding-top: 14px;
}
.who b { display: block; font-size: 12px; font-weight: 700; line-height: 1.6; }
.who time { display: block; font-size: 10px; color: var(--faint); font-variant-numeric: tabular-nums; }
.turn.me b { color: var(--me-text); }
.turn.them b { color: var(--them-text); }
.turn p { margin: 0; }

/* End card */
.card {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
}
.card .icon { width: 252px; height: 252px; display: block; filter: drop-shadow(0 8px 20px rgba(0, 0, 0, 0.18)); }
.card .name {
  font-family: var(--rounded);
  font-weight: 700;
  font-size: 80px;
  line-height: 1.15;
  letter-spacing: -0.012em;
  margin-top: 2px;
}
.headline {
  font-family: var(--rounded);
  font-weight: 700;
  font-size: 52px;
  letter-spacing: -0.022em;
  line-height: 1.08;
  display: grid;
  gap: 0.28em;
  margin: 56px 0 0;
}
.voice {
  display: grid;
  grid-template-columns: auto 1fr;
  align-items: start;
  column-gap: 0.42em;
}
.voice.them .said { color: var(--muted); }
.bars { display: flex; align-items: center; gap: 0.075em; height: 1.08em; }
.bars i { display: block; width: 0.1em; border-radius: 0.05em; background: var(--me); }
.them .bars i { background: var(--them); }
.card .url {
  margin-top: 60px;
  font-family: var(--text);
  font-weight: 500;
  font-size: 36px;
  color: var(--me-text);
  letter-spacing: -0.005em;
}
`;

const CLAUDE_PATH =
  'm19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z';
const CHATGPT_PATH =
  'm297.06 130.97c7.26-21.79 4.76-45.66-6.85-65.48-17.46-30.4-52.56-46.04-86.84-38.68-15.25-17.18-37.16-26.95-60.13-26.81-35.04-.08-66.13 22.48-76.91 55.82-22.51 4.61-41.94 18.7-53.31 38.67-17.59 30.32-13.58 68.54 9.92 94.54-7.26 21.79-4.76 45.66 6.85 65.48 17.46 30.4 52.56 46.04 86.84 38.68 15.24 17.18 37.16 26.95 60.13 26.8 35.06.09 66.16-22.49 76.94-55.86 22.51-4.61 41.94-18.7 53.31-38.67 17.57-30.32 13.55-68.51-9.94-94.51zm-120.28 168.11c-14.03.02-27.62-4.89-38.39-13.88.49-.26 1.34-.73 1.89-1.07l63.72-36.8c3.26-1.85 5.26-5.32 5.24-9.07v-89.83l26.93 15.55c.29.14.48.42.52.74v74.39c-.04 33.08-26.83 59.9-59.91 59.97zm-128.84-55.03c-7.03-12.14-9.56-26.37-7.15-40.18.47.28 1.3.79 1.89 1.13l63.72 36.8c3.23 1.89 7.23 1.89 10.47 0l77.79-44.92v31.1c.02.32-.13.63-.38.83l-64.41 37.19c-28.69 16.52-65.33 6.7-81.92-21.95zm-16.77-139.09c7-12.16 18.05-21.46 31.21-26.29 0 .55-.03 1.52-.03 2.2v73.61c-.02 3.74 1.98 7.21 5.23 9.06l77.79 44.91-26.93 15.55c-.27.18-.61.21-.91.08l-64.42-37.22c-28.63-16.58-38.45-53.21-21.95-81.89zm221.26 51.49-77.79-44.92 26.93-15.54c.27-.18.61-.21.91-.08l64.42 37.19c28.68 16.57 38.51 53.26 21.94 81.94-7.01 12.14-18.05 21.44-31.2 26.28v-75.81c.03-3.74-1.96-7.2-5.2-9.06zm26.8-40.34c-.47-.29-1.3-.79-1.89-1.13l-63.72-36.8c-3.23-1.89-7.23-1.89-10.47 0l-77.79 44.92v-31.1c-.02-.32.13-.63.38-.83l64.41-37.16c28.69-16.55 65.37-6.7 81.91 22 6.99 12.12 9.52 26.31 7.15 40.1zm-168.51 55.43-26.94-15.55c-.29-.14-.48-.42-.52-.74v-74.39c.02-33.12 26.89-59.96 60.01-59.94 14.01 0 27.57 4.92 38.34 13.88-.49.26-1.33.73-1.89 1.07l-63.72 36.8c-3.26 1.85-5.26 5.31-5.24 9.06l-.04 89.79zm14.63-31.54 34.65-20.01 34.65 20v40.01l-34.65 20-34.65-20z';

// CSS `ease-out`.
const easeOut = Easing.bezier(0, 0, 0.58, 1);

// Progress (0..1, eased) of a CSS animation with fill-mode both.
const progress = (t: number, delay: number, dur: number) =>
  easeOut(Math.min(1, Math.max(0, (t - delay) / dur)));

// `turn-in 0.5s ease-out both` with the page's delays.
const TURN_DELAYS = [0.3, 1.3, 2.3, 3.6];

// `level 0.9s steps(1) 7 alternate`: each keyframe holds until the next one.
const LEVELS = [80, 55, 30, 65, 40, 75];
const meterOff = (t: number, delay: number, rest: number) => {
  const local = t - delay;
  if (local < 0 || local >= 0.9 * 7) return rest;
  const iter = Math.floor(local / 0.9);
  const p = (local - iter * 0.9) / 0.9;
  const directed = iter % 2 === 0 ? p : 1 - p;
  return LEVELS[Math.min(4, Math.floor(directed * 5))];
};

// `handoff 1.2s ease-out`: a ring that swells to 4px at 35% and fades.
const handoffRing = (t: number, delay: number) => {
  const p = (t - delay) / 1.2;
  if (p <= 0 || p >= 1) return 'none';
  const k = p < 0.35 ? easeOut(p / 0.35) : 1 - easeOut((p - 0.35) / 0.65);
  return `0 0 0 ${(4 * k).toFixed(3)}px rgba(10, 132, 255, ${(0.28 * k).toFixed(3)})`;
};

const TURNS: {who: 'me' | 'them'; name: string; time: string; text: string}[] = [
  {who: 'them', name: 'Dana', time: '21:52', text: 'The main thing for us is having everyone set up before the end of the quarter.'},
  {who: 'me', name: 'Me', time: '22:03', text: "That's doable. How many people are we talking about?"},
  {who: 'them', name: 'Dana', time: '22:09', text: 'Forty to start. And legal will want to see the contract before the 14th.'},
  {who: 'me', name: 'Me', time: '22:24', text: "Got it. I'll send it over tomorrow "},
];

const Window: React.FC<{t: number; theme: Theme}> = ({t, theme}) => {
  const tok = TOKENS[theme];
  const settle = progress(t, 5.4, 0.6);
  const partialColor = interpolateColors(settle, [0, 1], [tok['--faint'], tok['--ink']]);

  return (
    <figure className="window" style={{zoom: ZOOM}}>
      <div className="titlebar">
        <span />
        <span />
        <span />
        <span className="send">
          <span className="ai" style={{boxShadow: handoffRing(t, 6.2)}}>
            <svg viewBox="0 0 100 100">
              <path fill="#D97757" d={CLAUDE_PATH} />
            </svg>
          </span>
          <span className="ai" style={{boxShadow: handoffRing(t, 6.45)}}>
            <svg viewBox="0 0 320 320">
              <path fill="currentColor" d={CHATGPT_PATH} />
            </svg>
          </span>
        </span>
      </div>
      <div className="callhead">
        <div>
          <strong>Call with Dana</strong>
          <small>
            <span className="rec" />
            Recording 22:41 {' '} English
          </small>
        </div>
        <div className="meters">
          <span>Me</span>
          <span className="meter">
            <i style={{clipPath: `inset(0 ${meterOff(t, 0, 70)}% 0 0)`}} />
          </span>
          <span>Dana</span>
          <span className="meter">
            <i style={{clipPath: `inset(0 ${meterOff(t, 0.15, 45)}% 0 0)`}} />
          </span>
        </div>
      </div>
      <ol className="turns">
        {TURNS.map((turn, i) => {
          const p = progress(t, TURN_DELAYS[i], 0.5);
          return (
            <li
              key={i}
              className={`turn ${turn.who}`}
              style={{opacity: p, transform: p < 1 ? `translateY(${6 * (1 - p)}px)` : undefined}}
            >
              <div className="who">
                <b>{turn.name}</b>
                <time>{turn.time}</time>
              </div>
              <p>
                {turn.text}
                {i === 3 && <span style={{color: partialColor}}>so they have the weekend.</span>}
              </p>
            </li>
          );
        })}
      </ol>
    </figure>
  );
};

const Bars: React.FC<{heights: number[]}> = ({heights}) => (
  <span className="bars">
    {heights.map((h, i) => (
      <i key={i} style={{height: `${h}em`}} />
    ))}
  </span>
);

const EndCard: React.FC<{s: number}> = ({s}) => {
  // Each piece rises 10px and fades in, a beat after the one above it.
  const rise = (delay: number): React.CSSProperties => {
    const p = progress(s, delay, 0.6);
    return {opacity: p, transform: `translateY(${10 * (1 - p)}px)`};
  };
  return (
    <AbsoluteFill className="card">
      <Img className="icon" src={staticFile('logo.svg')} style={rise(0)} />
      <div className="name" style={rise(0.06)}>
        Scribe
      </div>
      <h1 className="headline">
        <span className="voice me" style={rise(0.2)}>
          <Bars heights={[0.36, 0.68, 0.92, 0.52, 0.27]} />
          <span className="said">Transcribe your calls on your Mac.</span>
        </span>
        <span className="voice them" style={rise(0.32)}>
          <Bars heights={[0.27, 0.52, 0.92, 0.68, 0.36]} />
          <span className="said">Paste them into Claude or ChatGPT.</span>
        </span>
      </h1>
      <div className="url" style={rise(0.5)}>
        scribe.finereli.com
      </div>
    </AbsoluteFill>
  );
};

export const Scribe: React.FC<{theme: Theme}> = ({theme}) => {
  const frame = useCurrentFrame();
  const sec = frame / FPS;
  const t = sec - LEAD;

  const out = interpolate(sec, [OUTRO, OUTRO + 0.5], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });

  return (
    <AbsoluteFill className="stage" style={TOKENS[theme] as React.CSSProperties}>
      <style>{CSS}</style>
      {out < 1 && (
        <AbsoluteFill
          style={{
            alignItems: 'center',
            justifyContent: 'center',
            opacity: 1 - out,
            transform: `translateY(${-14 * out}px) scale(${1 - 0.02 * out})`,
          }}
        >
          <Window t={t} theme={theme} />
        </AbsoluteFill>
      )}
      {sec >= OUTRO + 0.45 && <EndCard s={sec - (OUTRO + 0.45)} />}
    </AbsoluteFill>
  );
};
