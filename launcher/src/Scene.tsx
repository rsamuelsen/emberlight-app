import { memo } from "react";

export type RoadState = "dark" | "idle" | "synced" | "syncing" | "error";

type Pt = [number, number];
type Seg = [Pt, Pt, Pt, Pt];

// The road from the crest: it leaves the lantern's feet and winds up into the mountain pass.
const PASS: Pt = [405, 431];
const ROAD: Seg[] = [
  [[300, 600], [360, 592], [430, 572], [388, 532]],
  [[388, 532], [360, 500], [352, 478], [384, 462]],
  [[384, 462], [408, 450], [414, 440], PASS],
];

const bez = (s: Seg, t: number): Pt => {
  const u = 1 - t;
  const f = (i: 0 | 1) => u * u * u * s[0][i] + 3 * u * u * t * s[1][i] + 3 * u * t * t * s[2][i] + t * t * t * s[3][i];
  return [f(0), f(1)];
};
const tangent = (s: Seg, t: number): Pt => {
  const u = 1 - t;
  const f = (i: 0 | 1) => 3 * u * u * (s[1][i] - s[0][i]) + 6 * u * t * (s[2][i] - s[1][i]) + 3 * t * t * (s[3][i] - s[2][i]);
  return [f(0), f(1)];
};

function roadShape() {
  const steps = 48;
  const left: Pt[] = [];
  const right: Pt[] = [];
  const total = ROAD.length * steps;
  ROAD.forEach((seg, si) => {
    for (let i = si === 0 ? 0 : 1; i <= steps; i++) {
      const t = i / steps;
      const progress = (si * steps + i) / total;
      const half = (2 + 58 * Math.pow(1 - progress, 1.6)) / 2;
      const [x, y] = bez(seg, t);
      const [dx, dy] = tangent(seg, t);
      const len = Math.hypot(dx, dy) || 1;
      const nx = -dy / len;
      const ny = dx / len;
      left.push([x + nx * half, y + ny * half]);
      right.push([x - nx * half, y - ny * half]);
    }
  });
  const pts = [...left, ...right.reverse()];
  const fill = "M" + pts.map(([x, y]) => `${x.toFixed(1)} ${y.toFixed(1)}`).join(" L") + " Z";
  const center = `M${ROAD[0][0].join(" ")} ` + ROAD.map((s) => `C${s[1].join(" ")} ${s[2].join(" ")} ${s[3].join(" ")}`).join(" ");
  return { fill, center };
}

function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const random = rng(1790);
const DUST = Array.from({ length: 130 }, () => ({ x: random() * 1200, y: random() * 420, r: 0.35 + random() * 0.9, o: 0.2 + random() * 0.6 }));
const BRIGHT: [number, number, number][] = [
  [150, 118, 5], [214, 64, 5], [318, 176, 5], [440, 96, 6], [128, 262, 4], [176, 330, 4], [452, 228, 4],
];
const GUIDE: [number, number, number] = [PASS[0], 300, 15];
const { fill: ROAD_FILL, center: ROAD_CENTER } = roadShape();

/** A layered pine silhouette standing on (x, base). */
const pine = (x: number, base: number, h: number) => {
  const w = h * 0.36;
  const tiers = [0, 0.3, 0.55];
  return (
    tiers
      .map((t) => {
        const top = base - h + h * t * 0.9;
        const bottom = base - h * (0.18 + (0.55 - t) * 0.55);
        const half = w * (0.45 + t);
        return `M${x} ${top} L${x + half} ${bottom} L${x - half} ${bottom} Z`;
      })
      .join(" ") + ` M${x - 2} ${base} V${base - h * 0.2} H${x + 2} V${base} Z`
  );
};
const PINES = [
  [118, 604, 84], [146, 600, 62], [172, 606, 96], [200, 602, 58], [470, 604, 70], [494, 600, 52],
].map(([x, b, h]) => pine(x, b, h)).join(" ");

const star = (x: number, y: number, r: number) =>
  `M${x} ${y - r} Q${x + r * 0.16} ${y - r * 0.16} ${x + r} ${y} Q${x + r * 0.16} ${y + r * 0.16} ${x} ${y + r} Q${x - r * 0.16} ${y + r * 0.16} ${x - r} ${y} Q${x - r * 0.16} ${y - r * 0.16} ${x} ${y - r}Z`;

export const Scene = memo(function Scene({ road }: { road: RoadState }) {
  return (
    // Drawn for the sidebar: the view is centred on the road's start, where the lantern stands.
    <svg className={`scene road-${road}`} viewBox="100 0 400 720" preserveAspectRatio="xMidYMax slice" aria-hidden="true">
      <defs>
        <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#02050c" />
          <stop offset="0.34" stopColor="#0a1638" />
          <stop offset="0.58" stopColor="#1b3274" />
          <stop offset="0.72" stopColor="#152a62" />
          <stop offset="1" stopColor="#0a1328" />
        </linearGradient>
        <radialGradient id="pass-glow" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#5f7fd6" stopOpacity="0.42" />
          <stop offset="1" stopColor="#5f7fd6" stopOpacity="0" />
        </radialGradient>
        <linearGradient id="far" x1="0" y1="0.55" x2="0" y2="0.72">
          <stop offset="0" stopColor="#2b4796" />
          <stop offset="1" stopColor="#15285a" />
        </linearGradient>
        <linearGradient id="near" x1="0" y1="0.45" x2="0" y2="0.85">
          <stop offset="0" stopColor="#172a62" />
          <stop offset="1" stopColor="#070d1d" />
        </linearGradient>
        <linearGradient id="road-fill" gradientUnits="userSpaceOnUse" x1="0" y1="600" x2="0" y2="430">
          <stop offset="0" stopColor="#2c3a62" />
          <stop offset="0.55" stopColor="#5a6c9e" />
          <stop offset="1" stopColor="#b9c6ea" />
        </linearGradient>
        <radialGradient id="guide-glow" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#fff1c2" stopOpacity="0.55" />
          <stop offset="1" stopColor="#fff1c2" stopOpacity="0" />
        </radialGradient>
        <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
          <feGaussianBlur stdDeviation="7" />
        </filter>
        <filter id="mist" x="-20%" y="-100%" width="140%" height="300%">
          <feGaussianBlur stdDeviation="14" />
        </filter>
        <radialGradient id="ember-end" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" stopColor="#ff7a4a" stopOpacity="0.95" />
          <stop offset="0.35" stopColor="#c2412d" stopOpacity="0.55" />
          <stop offset="1" stopColor="#c2412d" stopOpacity="0" />
        </radialGradient>
        <clipPath id="road-clip">
          <path d={ROAD_FILL} />
        </clipPath>
        <filter id="soft" x="-20%" y="-20%" width="140%" height="140%">
          <feGaussianBlur stdDeviation="3" />
        </filter>
      </defs>

      <rect width="1200" height="720" fill="url(#sky)" />
      <g className="dust">
        {DUST.map((d, i) => (
          <circle key={i} cx={d.x} cy={d.y} r={d.r} fill="#dfe6ff" opacity={d.o} />
        ))}
      </g>
      <g className="bright-stars">
        {BRIGHT.map(([x, y, r], i) => (
          <path key={i} d={star(x, y, r)} fill="#e7c875" style={{ animationDelay: `${i * 1.7}s` }} />
        ))}
      </g>

      <ellipse cx={PASS[0]} cy={PASS[1] - 16} rx="360" ry="110" fill="url(#pass-glow)" />
      <g className="guide">
        <circle cx={GUIDE[0]} cy={GUIDE[1]} r="46" fill="url(#guide-glow)" />
        <path d={star(...GUIDE)} fill="#f7e2a4" />
      </g>
      <path fill="url(#far)" d="M0 452 L48 420 L96 392 L140 402 L190 372 L236 396 L290 380 L340 402 L384 414 L405 404 L432 386 L470 400 L520 372 L570 392 L640 380 L720 398 L820 384 L940 402 L1060 390 L1200 404 L1200 720 L0 720 Z" />
      <path fill="url(#near)" d="M-30 590 L20 516 L58 448 L96 380 L120 344 L142 370 L168 334 L210 398 L258 424 L310 424 L352 428 L380 426 L405 431 L405 720 L-30 720 Z" />
      <path fill="url(#near)" d="M405 431 L432 404 L456 368 L478 330 L500 356 L528 316 L566 372 L610 412 L680 440 L760 452 L860 446 L980 462 L1200 456 L1200 720 L405 720 Z" />
      <g className="ridges" fill="none" stroke="#a9bdf0" strokeOpacity="0.22" strokeWidth="1.3" strokeLinejoin="round">
        <path d="M120 344 L100 386 L80 420 L58 448" />
        <path d="M168 334 L156 370 L140 396" />
        <path d="M478 330 L466 364 L450 390" />
        <path d="M528 316 L516 352 L500 378" />
      </g>
      <g className="mist" filter="url(#mist)">
        <ellipse cx="200" cy="470" rx="260" ry="16" fill="#9fb4ea" opacity="0.1" />
        <ellipse cx="560" cy="452" rx="220" ry="12" fill="#9fb4ea" opacity="0.08" />
      </g>
      <path fill="#070c18" d={PINES} />
      <path fill="#05080f" d="M0 600 C140 578 300 606 520 594 S980 612 1200 598 L1200 720 L0 720 Z" />

      <g className="road">
        <path className="road-glow" d={ROAD_CENTER} fill="none" stroke="#e7c875" strokeWidth="26" strokeLinecap="round" filter="url(#glow)" />
        <path className="road-stone" d={ROAD_FILL} fill="url(#road-fill)" stroke="#0a1226" strokeOpacity="0.5" strokeWidth="1" />
        <g clipPath="url(#road-clip)">
          <path className="road-pulse" d={ROAD_CENTER} pathLength={1000} fill="none" stroke="#fff1c2" strokeWidth="60" filter="url(#soft)" />
        </g>
        <path className="road-sparks" d={ROAD_CENTER} fill="none" stroke="#fff1c2" strokeWidth="2.4" strokeLinecap="round" />
        <circle className="road-ember" cx={PASS[0]} cy={PASS[1]} r="20" fill="url(#ember-end)" />
      </g>
    </svg>
  );
});
