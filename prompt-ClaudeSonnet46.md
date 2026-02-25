Here's a comprehensive prompt that captures everything:

---

## Foosball Tournament Manager — System Prompt

Build a two-part foosball (table soccer) tournament management system: a Julia schedule optimizer and a single-file HTML/CSS/JS tracker app.

---

### Part 1: `foosball_scheduler.jl`

**Input:** a CSV file (`elos.csv`) with columns `name` and `elo`.

**Rules:**
- Each player plays exactly **4 games**, one in each position: Red Defender (RD), Red Attacker (RA), Blue Defender (BD), Blue Attacker (BA).
- With *n* players this yields exactly *n* games.

**Schedule generation (urn system):**
- Build four position pools, each a fresh random permutation of all *n* player indices.
- Game *g* is formed by zipping the *g*-th element of each pool.
- Enforce uniqueness (no player twice in the same game) with a targeted swap heuristic: when a collision is detected at position *p* of game *g*, swap `pools[p][g]` with a random slot *j ≠ g* in the same pool and update both affected games. Retry up to `n × 4` passes; restart from fresh permutations (up to 200 times) if unresolved. Include a `_fallback_schedule` rejection-sampling safety net.
- After generation, validate with `is_valid_schedule`: every position column must be a permutation of `1..n`, every game must have 4 distinct players.

**Objective:**
- Team Elo = `sqrt(Player1_Elo × Player2_Elo)` (geometric mean)
- Game tension = `|TeamRed_Elo − TeamBlue_Elo|`
- Fairness score = `sum(tension)` over all games — **minimize this**

**Optimization:** run **1,000,000** iterations using `Threads.@threads`. Each thread has its own `MersenneTwister` seeded by thread index. Per-thread bests are merged at the end with a linear reduction.

**Libraries:** `CSV.jl`, `DataFrames.jl`, `Statistics.jl`, `Random`, `Printf`.

**Usage:**
```bash
julia --threads auto foosball_scheduler.jl elos.csv
```

**Output:**
- Pretty-printed schedule table to stdout (columns: game, RD, RA, BD, BA, tension; plus fairness score).
- `table.csv` saved in the same folder with columns: `game, RD, RA, BD, BA, score_red, score_blue, tension`. The `score_red` and `score_blue` columns are left blank.

---

### Part 2: `biliardino_tracker.html`

A **single self-contained HTML/CSS/JS file** (no build step, no server, opens directly from `file://`). Use Google Fonts (Bebas Neue + DM Mono + DM Sans). Dark theme with CSS variables.

**Layout:** two-panel. Left panel: live ranking table. Right sidebar: player setup, game entry form, game log.

---

**Player loading (sidebar, top):**

A textarea + Load button. The same box accepts three formats, auto-detected by the header row:
- **`elos.csv`** format (`name,elo` header): extracts the `name` column.
- **`table.csv`** format (header contains `rd` and `ra`): imports all games, auto-registers players, initializes `score_red`/`score_blue` to 0 if blank.
- **Plain text**: one name per line or comma-separated.

Players persist in `localStorage`.

---

**Game entry form:**

Two team blocks (Red / Blue), each with Attacker and Defender dropdowns populated from the player list, plus a score input. Validation: all four players must be selected and must be distinct. On submit: record game, reset scores to 0.

---

**Points system:**

| Goal difference | Winner pts | Loser pts |
|---|---|---|
| > 1 | 2 | 0 |
| = 1 | 2 | 1 |
| = 0 (draw) | 1 | 1 |

Each player's stats (GP, Pts, GF, GA, GD) accumulate across all games they appear in regardless of position.

---

**Ranking table (left panel):**

Columns: `#`, Player, GP, Pts, GF, GA, GD.
Sort order: points → goal difference → goals scored → name.
Row highlights:
- 🥇 1st: gold background + gold name
- 🥈 2nd: steel background + silver name
- 🥉 3rd: bronze background + bronze name
- 💀 Penultimate (only if ≥ 5 players ranked): dark red background + red name

---

**Game log (sidebar, bottom):**

Reverse-chronological list. Each entry shows: game number, time, score, per-game points awarded, player names by team. Edit and delete buttons. Edit opens a modal with the same form pre-filled.

---

**Header buttons:**
- **Reset**: opens a confirmation modal requiring the user to type `YES!` exactly. Flashes the input border red on wrong input. Clears `localStorage` and in-memory state.
- **↓ Save**: downloads a JSON snapshot as `biliardino-YYYY-MM-DD_HH:MM:SS.json` (macOS-safe filename).

**State persistence:** auto-save to `localStorage` on every change.

---

**Style notes:**
- CSS variables for all colors; dark background (`#0d0f14`).
- Bebas Neue for headings/scores, DM Mono for data/labels, DM Sans for body.
- Sticky header; scrollable game log; modal backdrop closes on outside click.
- Toast notifications (bottom-right, 2.8s) for all actions; error variant with red left border.

---