import type { ReactNode } from "react";

export type ChipSegment = { key: string; label: string; weight: number };

const TAU = Math.PI * 2;

function arc(cx: number, cy: number, r: number, a0: number, a1: number) {
  const p = (a: number) => [cx + r * Math.cos(a), cy + r * Math.sin(a)];
  const [x0, y0] = p(a0);
  const [x1, y1] = p(a1);
  return `M ${x0} ${y0} A ${r} ${r} 0 ${a1 - a0 > Math.PI ? 1 : 0} 1 ${x1} ${y1}`;
}

/**
 * A blue poker chip whose edge inserts are the index: each insert's length is a constituent's
 * weight. Hovering or focusing an insert names it.
 */
export function PokerChip({
  segments,
  active,
  onActive,
  children,
}: {
  segments: ChipSegment[];
  active?: string | null;
  onActive?: (key: string | null) => void;
  children?: ReactNode;
}) {
  const total = segments.reduce((s, x) => s + x.weight, 0) || 1;
  const gap = 0.035;
  let a = -Math.PI / 2;
  const arcs = segments.map((s, i) => {
    const span = (s.weight / total) * TAU;
    const d = arc(200, 200, 168, a + gap / 2, a + span - gap / 2);
    a += span;
    return { ...s, d, i };
  });

  return (
    <div className="relative aspect-square w-full max-w-[420px] overflow-hidden">
      <svg viewBox="0 0 400 400" className="chip-in h-full w-full" role="img" aria-label="Index weights shown as the edge of a poker chip">
        <circle cx="200" cy="200" r="198" fill="var(--blue)" />
        <circle cx="200" cy="200" r="190" fill="none" stroke="var(--blue-deep)" strokeOpacity="0.35" strokeWidth="2" />
        {arcs.map((s) => (
          <path
            key={s.key}
            d={s.d}
            fill="none"
            stroke={s.i % 2 ? "#b9ccff" : "#ffffff"}
            strokeOpacity={active && active !== s.key ? 0.35 : 1}
            strokeWidth={active === s.key ? 40 : 32}
            tabIndex={0}
            onMouseEnter={() => onActive?.(s.key)}
            onMouseLeave={() => onActive?.(null)}
            onFocus={() => onActive?.(s.key)}
            onBlur={() => onActive?.(null)}
            className="cursor-pointer outline-none transition-[stroke-width,stroke-opacity] duration-200"
          >
            <title>{s.label}</title>
          </path>
        ))}
        <circle cx="200" cy="200" r="132" fill="none" stroke="#ffffff" strokeOpacity="0.55" strokeWidth="2" strokeDasharray="6 10" />
        <circle cx="200" cy="200" r="118" fill="var(--blue-deep)" />
      </svg>
      <div className="pointer-events-none absolute inset-0 grid place-items-center text-center text-white">{children}</div>
    </div>
  );
}

/** Small static chip for the logo and favicon-sized uses. */
export function ChipMark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden>
      <circle cx="32" cy="32" r="31" fill="var(--blue)" />
      <circle cx="32" cy="32" r="25" fill="none" stroke="#fff" strokeWidth="8" strokeDasharray="9.8 9.8" />
      <circle cx="32" cy="32" r="17" fill="var(--blue-deep)" />
    </svg>
  );
}

/** A small, static chip whose edge inserts are the weights, for fund cards. */
export function MiniChip({ weights, size = 64 }: { weights: number[]; size?: number }) {
  const total = weights.reduce((s, w) => s + w, 0) || 1;
  const gap = 0.06;
  let a = -Math.PI / 2;
  const arcs = weights.map((w) => {
    const span = (w / total) * TAU;
    const d = arc(32, 32, 26, a + gap / 2, a + span - gap / 2);
    a += span;
    return d;
  });
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden className="shrink-0">
      <circle cx="32" cy="32" r="31.5" fill="var(--blue)" />
      {arcs.map((d, i) => (
        <path key={i} d={d} fill="none" stroke={i % 2 ? "#b9ccff" : "#ffffff"} strokeWidth="7" />
      ))}
      <circle cx="32" cy="32" r="18" fill="var(--blue-deep)" />
    </svg>
  );
}
