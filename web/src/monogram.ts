// The two letters of a workspace's monogram, as the app's WorkspaceMonogram (HerdrKit) makes them.

/** "[ME] Meadow · Migration" -> "MM", "OpenAtlas" -> "OA" (the app's Monogram). */
export function monogram(raw: string): string {
  let s = raw.replace(/^\[[^\]]*\]\s*/, "") || raw;
  let words = s.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  if (words.length === 1) words = words[0].split(/(?=\p{Lu})/u);
  return (words.length >= 2 ? words[0][0] + words[1][0] : s.slice(0, 2)).toUpperCase();
}
