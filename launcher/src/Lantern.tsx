import { useEffect, useRef, useState } from "react";

export type LanternMood = "cold" | "lit" | "busy" | "ingame";

interface Props {
  mood: LanternMood;
  label: string;
  hint: string | null;
  onPress: () => void;
}

const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Embers rising from the lantern's chimney. Small canvas, 30 fps, paused when hidden. */
function useEmbers(canvas: React.RefObject<HTMLCanvasElement | null>, rate: React.RefObject<number>) {
  useEffect(() => {
    const el = canvas.current;
    const ctx = el?.getContext("2d");
    if (!el || !ctx || reducedMotion()) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = el.clientWidth;
    const h = el.clientHeight;
    el.width = w * dpr;
    el.height = h * dpr;
    ctx.scale(dpr, dpr);
    type P = { x: number; y: number; vx: number; vy: number; life: number; max: number; size: number; phase: number };
    const parts: P[] = [];
    let frame = 0;
    let last = 0;
    let carry = 0;
    const tick = (time: number) => {
      frame = requestAnimationFrame(tick);
      if (document.hidden || time - last < 33) return;
      last = time;
      carry += rate.current ?? 0;
      while (carry >= 1 && parts.length < 90) {
        carry -= 1;
        parts.push({
          x: w / 2 + (Math.random() - 0.5) * 22,
          y: h * 0.56 + (Math.random() - 0.5) * 8,
          vx: (Math.random() - 0.5) * 0.5,
          vy: -(0.7 + Math.random() * 1.1),
          life: 0,
          max: 40 + Math.random() * 50,
          size: 0.8 + Math.random() * 1.8,
          phase: Math.random() * 6.28,
        });
      }
      ctx.clearRect(0, 0, w, h);
      ctx.globalCompositeOperation = "lighter";
      for (let i = parts.length - 1; i >= 0; i--) {
        const p = parts[i];
        p.life++;
        p.x += p.vx + Math.sin(p.phase + p.life * 0.12) * 0.35;
        p.y += p.vy;
        p.vy *= 0.992;
        const k = p.life / p.max;
        if (k >= 1) {
          parts.splice(i, 1);
          continue;
        }
        const alpha = k < 0.15 ? k / 0.15 : 1 - (k - 0.15) / 0.85;
        const r = p.size * (1 - k * 0.5);
        const g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, r * 3);
        g.addColorStop(0, `rgba(255, 226, 150, ${0.95 * alpha})`);
        g.addColorStop(0.4, `rgba(255, 150, 60, ${0.55 * alpha})`);
        g.addColorStop(1, "rgba(200, 70, 30, 0)");
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.arc(p.x, p.y, r * 3, 0, Math.PI * 2);
        ctx.fill();
      }
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [canvas, rate]);
}

export function Lantern({ mood, label, hint, onPress }: Props) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const [hover, setHover] = useState(false);
  const rate = useRef(0);
  rate.current = mood === "cold" ? 0 : mood === "busy" ? 1.6 : hover ? 0.9 : 0.3;
  useEmbers(canvas, rate);

  return (
    <div className={`lantern mood-${mood}${hover ? " is-hover" : ""}`}>
      <div className="lantern-halo" />
      <canvas ref={canvas} className="lantern-embers" />
      <button
        className="lantern-button"
        onClick={onPress}
        onMouseEnter={() => setHover(true)}
        onMouseLeave={() => setHover(false)}
        onFocus={() => setHover(true)}
        onBlur={() => setHover(false)}
        aria-label={hint ? `${label}. ${hint}` : label}
        aria-busy={mood === "busy"}
      >
        <svg className="lantern-art" viewBox="0 0 200 300" aria-hidden="true">
          <defs>
            <linearGradient id="brass" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stopColor="#fbe7a6" />
              <stop offset="0.45" stopColor="#d8aa4c" />
              <stop offset="1" stopColor="#7d5a1d" />
            </linearGradient>
            <linearGradient id="brass-dark" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stopColor="#b98a35" />
              <stop offset="1" stopColor="#5e4214" />
            </linearGradient>
            <radialGradient id="glass-lit" cx="0.5" cy="0.62" r="0.62">
              <stop offset="0" stopColor="#fff3c4" />
              <stop offset="0.35" stopColor="#ffbf57" />
              <stop offset="0.75" stopColor="#c9651f" />
              <stop offset="1" stopColor="#5c230d" />
            </radialGradient>
            <radialGradient id="glass-cold" cx="0.5" cy="0.35" r="0.8">
              <stop offset="0" stopColor="#2a3d78" />
              <stop offset="1" stopColor="#0a1230" />
            </radialGradient>
            <linearGradient id="side-glass" x1="0" y1="0" x2="1" y2="0">
              <stop offset="0" stopColor="#000" stopOpacity="0.55" />
              <stop offset="1" stopColor="#000" stopOpacity="0.15" />
            </linearGradient>
            <radialGradient id="flame" cx="0.5" cy="0.8" r="0.75">
              <stop offset="0" stopColor="#fffbe8" />
              <stop offset="0.35" stopColor="#ffe08a" />
              <stop offset="0.8" stopColor="#ff9b3a" />
              <stop offset="1" stopColor="#e0561c" />
            </radialGradient>
          </defs>

          <circle cx="100" cy="20" r="12" fill="none" stroke="url(#brass)" strokeWidth="5" />
          <path d="M100 32 L110 44 L100 56 L90 44 Z" fill="url(#brass)" stroke="#5e4214" strokeWidth="1" />
          <path d="M84 58 H116 L120 64 H80 Z" fill="url(#brass-dark)" />
          <path d="M80 64 H120 L146 106 H54 Z" fill="#16255a" stroke="url(#brass)" strokeWidth="4" strokeLinejoin="round" />
          <path d="M100 74 Q102 84 110 86 Q102 88 100 98 Q98 88 90 86 Q98 84 100 74 Z" fill="url(#brass)" />
          <rect x="44" y="104" width="112" height="12" rx="3" fill="url(#brass)" stroke="#5e4214" strokeWidth="1" />

          <g className="glass">
            <path d="M52 118 H70 V226 H52 Z" />
            <path d="M130 118 H148 V226 H130 Z" />
            <path className="glass-main" d="M72 226 V140 Q72 118 100 118 Q128 118 128 140 V226 Z" />
          </g>
          <path d="M52 118 H70 V226 H52 Z M130 118 H148 V226 H130 Z" fill="url(#side-glass)" />
          <g className="flame">
            <path d="M100 150 C112 168 126 184 119 206 C114 220 86 220 81 206 C76 188 90 176 93 162 C97 172 103 174 100 150 Z" fill="url(#flame)" />
            <path d="M100 176 C106 186 111 196 107 206 C104 213 96 213 93 206 C90 198 96 190 100 176 Z" fill="#fffbe8" opacity="0.9" />
          </g>
          <g fill="none" stroke="url(#brass)" strokeWidth="4" strokeLinejoin="round">
            <path d="M50 116 V228 M150 116 V228 M71 118 V228 M129 118 V228" />
            <path d="M72 226 V140 Q72 118 100 118 Q128 118 128 140 V226" strokeWidth="3" />
          </g>
          <path d="M44 226 H156 L144 246 H56 Z" fill="url(#brass)" stroke="#5e4214" strokeWidth="1" />
          <path d="M58 246 H142 V256 H58 Z" fill="url(#brass-dark)" />
          <path d="M100 256 L112 268 L100 282 L88 268 Z" fill="url(#brass)" stroke="#5e4214" strokeWidth="1" />
        </svg>
        <span className="plate">
          <span className="plate-label">{label}</span>
        </span>
      </button>
      {hint && <p className="lantern-hint">{hint}</p>}
    </div>
  );
}
