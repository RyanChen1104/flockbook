// Flockbook PWA entry. Phase 3a: connects to the hub's socket and shows the state.
const app = document.getElementById("app") as HTMLElement;

function show(text: string): void {
  const p = document.createElement("p");
  p.className = "center muted";
  p.textContent = text;
  app.replaceChildren(p);
}

const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
ws.addEventListener("open", () => {
  ws.send(JSON.stringify({ v: 1, type: "ping", id: "p1" }));
});
let answered = false;
ws.addEventListener("message", (e: MessageEvent<string>) => {
  const m = JSON.parse(e.data) as { type: string; error?: { code: string } };
  // Without a device token the hub answers "unauthorized" and closes: it is reachable all the same.
  if (m.type === "reply") { answered = true; show("Hub reachable"); }
});
ws.addEventListener("close", () => { if (!answered) show("Not connected"); });
