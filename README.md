# Darts-Score-System

Web app scoreboard for the Bellbrook Darts Club, played at the Bellbrook Hotel (Macleay Valley, NSW).

## Pages

- `index.html` — the scoreboard. Game modes:
  - **x01** (101 / 201 / 301) with Straight In or Double In, double-out finish, full bust handling, per-dart entry with undo/clear, turn history and downloadable match record.
  - **Killer** — unique claimed numbers, strikes for hitting opponents' numbers (single/double/triple = 1/2/3), self-hits remove strikes, elimination at 5 strikes, last player standing wins.
- `rules.html` — house rules and the club code of conduct.
- `live.html` — live scores viewer. The scorer taps "Start Live Sharing" on the scoreboard to get a room code; everyone else opens this page, enters the code, and watches scores and shot history update live (broadcast through several public MQTT websocket relays with automatic failover — needs internet on both ends). Optional turn alerts (vibrate/beep/notification) when a turn ends.
- `history.html` — club history. Every finished game is saved in the browser automatically; the winner screen's "Publish to Club History" opens GitHub with the match record pre-filled so an admin can commit it to `matches/`, where this page picks it up for everyone. Shows a player ladder (games, wins, win %, x01 averages) and recent matches.
- `matches/` — published match records (JSON, one per game).
- `legacy/bellbrook-darts-scorer-v1.1.html` — the original v1.1 app, preserved unmodified.

v1.2 is a visual re-theme of v1.1 (Bellbrook Hotel pub styling: timber, brass, chalk, dartboard red and green). Game logic is unchanged from v1.1.

No build step — plain HTML/CSS/JS, works offline once loaded. Serve the repo root as a static site (e.g. GitHub Pages).
