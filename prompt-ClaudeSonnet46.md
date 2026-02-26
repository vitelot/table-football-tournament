# Biliardino Tournament System — Reconstruction Prompt

Build a two-part foosball (table soccer) tournament management system: a Julia schedule optimizer (`foosball_scheduler.jl`) and a single-file HTML/CSS/JS tracker (`biliardino_tracker.html`).

---

## Part 1: `foosball_scheduler.jl`

### Setup

**Libraries:** `CSV`, `DataFrames`, `Statistics`, `Random`, `Printf`, `ProgressMeter`

**Constants:**
```julia
const POSITIONS = ["RA", "RD", "BA", "BD"]
const N_POS     = 4
const N_ITER    = 1_000_000
```

**Usage:**
```bash
julia --threads auto foosball_scheduler.jl elos.csv
```

The input CSV (`elos.csv`) has columns `name` and `elo`.

---

### Rules

- Each player plays exactly **4 games**, one per position: RA (Red Attacker), RD (Red Defender), BA (Blue Attacker), BD (Blue Defender).
- With *n* players this yields exactly *n* games.
- No unordered team pair may appear more than once across all games (i.e. the pair Dubhe–Alcor is the same as Alcor–Dubhe).

---

### Helpers

```julia
@inline team_elo(e1, e2) = sqrt(e1 * e2)   # geometric mean

@inline function game_tension(e::NTuple{4,Float64})
    abs(team_elo(e[1], e[2]) - team_elo(e[3], e[4]))
end
# positions in e: (RA, RD, BA, BD)

@inline team_key(a::Int, b::Int) = a < b ? (a, b) : (b, a)
# canonical unordered pair — used to detect duplicate teams
```

**Fairness score** (minimize this):
```
F = Σ_g | sqrt(Elo_RA * Elo_RD) - sqrt(Elo_BA * Elo_BD) |
```

---

### `is_valid_schedule(schedule, n_players) -> Bool`

Returns `true` when ALL of:
- `length(schedule) == n_players`
- Every game has 4 distinct players
- Each position column is a permutation of `1..n_players`
- No unordered team key `(min,max)` appears more than once across all games (check both Red team `game[1],game[2]` and Blue team `game[3],game[4]`)

---

### `generate_schedule(n_players, rng) -> Vector{Vector{Int}}`

**Algorithm (urn + swap):**

1. Build four independent `randperm(rng, n_players)` pools, one per position. Game *g* = `[pools[p][g] for p in 1:4]`. Every player appears exactly once per position by construction.
2. Fix violations in a `while changed && pass < n_players * 20` loop:
   - Rebuild `seen_teams::Set{Tuple{Int,Int}}` from current games at the start of each pass.
   - For each game *g*, detect: (a) duplicate player, (b) Red team key already seen in another game, (c) Blue team key already seen in another game.
   - Determine `dup_pos`: player duplicate takes priority; otherwise pick a random position within the offending team (1:2 for Red, 3:4 for Blue).
   - Try swap partners in a **shuffled** order. For each candidate *j*: do the pool swap tentatively, compute new game *g* and *j*, accept if game *g* now has 4 distinct players AND its Red and Blue team keys do not appear in any other game AND Red key ≠ Blue key. If not accepted, undo the swap.
3. If `is_valid_schedule` passes, return. Otherwise restart from fresh permutations (up to 200 restarts).
4. Fallback (`_fallback_schedule`): rejection-sample by reshuffling one random pool at a time until valid.

---

### `optimise(n_players, elos; n_iter) -> (best_schedule, best_score, all_scores)`

- Split `n_iter` evenly across `Threads.nthreads()` threads.
- Each thread: own `MersenneTwister(t * 31337)`, tracks local best schedule and collects ALL scores in a `Float64[]` (use `sizehint!`).
- Progress bar via **ProgressMeter.jl**: `Progress(n_iter; dt=0.2, barlen=40, color=:cyan, desc="  Optimising: ")`, call `next!(prog)` each iteration (thread-safe), `finish!(prog)` after the loop.
- Merge: `reduce(vcat, thread_all_scores)`, `argmin(thread_best_scores)`.
- Return best schedule, best score, and the full `all_scores` vector.

---

### `validate_schedule!(schedule, n_players)`

Assert all position permutations, all games have 4 distinct players, and no team key repeats. Print confirmation.

---

### `print_schedule(schedule, players, elos)`

Print a formatted table with columns in order: **Game, RD, RA, BD, BA, Tension**.

After the table print:
```
  Fairness Score (minimised): X.XX
```

In `main`, after calling `optimise`, also print:
```
  Best  (min) fairness score : X.XX
  Worst (max) fairness score : X.XX   ← maximum(all_scores)
  Median      fairness score : X.XX   ← median(all_scores)
```

---

### `save_table_csv(schedule, players, elos; path="table.csv")`

Write to `table.csv` with columns in this exact order:
```
game,RD,RA,BD,BA,score_red,score_blue,tension
```
- `game[1]`=RA, `game[2]`=RD, `game[3]`=BA, `game[4]`=BD (internal order), so map accordingly.
- `score_red` and `score_blue` left blank.
- `tension` = `round(game_tension(...); digits=1)`.

---

## Part 2: `biliardino_tracker.html`

A **single self-contained HTML/CSS/JS file**. Opens directly from `file://`. No server, no build step, no external JS dependencies. Uses Google Fonts (Bebas Neue, DM Mono, DM Sans).

---

### Visual design

Dark theme with CSS variables:
```css
--bg: #0d0f14;  --surface: #141720;  --surface2: #1c2030;
--border: #2a2f45;  --text: #dde3f0;  --muted: #5a6278;
--red: #e84a4a;  --blue: #4a8fe8;  --accent: #e8c14a;
--gold: #e8c14a;  --silver: #b0bec5;  --bronze: #cd7f32;
```

Bebas Neue for headings/scores, DM Mono for data/labels, DM Sans for body text.

---

### Layout

Two-panel with sticky header:
- **Left panel:** live ranking table.
- **Right sidebar:** player setup section, game entry form, game log.

---

### State

```javascript
let state = {
  players: [],  // { name }
  games: []     // { id, redAtt, redDef, blueAtt, blueDef, scoreRed, scoreBlue, played, ts }
};
```

Persisted to `localStorage` on every change. Restored on `init()`.

The `played` field is a boolean. A game with `scoreRed === 0 && scoreBlue === 0 && played !== true` is considered **not played** and excluded from ranking.

---

### Header buttons (left to right)

- **Reset** (`btn-danger`): opens reset modal.
- **↑ Load** (`btn-ghost`): opens a JSON file picker (using `pickFile`) and restores a previously saved session.
- **↓ Save** (`btn-primary`): downloads JSON as `biliardino-YYYY-MM-DD_HH:MM:SS.json`.

---

### `pickFile(accept, onload)`

Creates a fresh `<input type="file">` element each call (positioned off-screen), appends to body, fires `.click()` after a 10ms `setTimeout`, reads the file as text, calls `onload(text, filename)`, then removes the element. This is the only reliable approach on `file://` URLs.

---

### Player setup section (top of sidebar)

Textarea + **Load** button. The same textarea accepts three formats, auto-detected by the header row:

- **`elos.csv`** format (header contains `name` column): extract names only.
- **`table.csv`** format (header contains both `rd` and `ra`): import all games, auto-register all players found, set `scoreRed`/`scoreBlue` to 0 if blank, set `played: false` if both scores are 0.
- **Plain text** (no commas): one name per line.

Show a badge `(N loaded)` next to the "Players" title, updated on every render.

---

### Game entry form (position order: RD, RA, BD, BA)

Two team blocks with labels and IDs:

Red team (left to right): `RD — Defender` → `id="red-def"`, then `RA — Attacker` → `id="red-att"`.
Blue team (left to right): `BD — Defender` → `id="blue-def"`, then `BA — Attacker` → `id="blue-att"`.

Score inputs below each team block. **+ Add Result** button.

Validation: all four players selected, all four distinct. On submit: push game with `played: (sr !== 0 || sb !== 0)`, reset scores to 0.

---

### Game log (below form)

Display games in **insertion order** (no reverse). Each entry shows:
- Header: `GAME N · HH:MM` + edit/del buttons.
- Score line: `RED_SCORE — BLUE_SCORE [X–Y pts]` or `[not played]` if 0-0 and `played !== true`.
- Players line (Red in red color, Blue in blue color): `RD / RA` and `BD / BA`.

---

### Edit modal

Same form layout as game entry (RD, RA, BD, BA order). Pre-fills all fields on open.

Add below the score inputs, above the action buttons:
```html
<input type="checkbox" id="e-played">
<label for="e-played">Mark as played (required for 0–0 results)</label>
```

`openEdit`: set `e-played` checked to `g.played !== false`.
`saveEdit`: write `g.played = document.getElementById('e-played').checked`.

Backdrop click closes modal.

---

### Reset modal

Requires typing `YES!` exactly. Flash input border red on wrong input. On confirm: `state = { players: [], games: [] }`, clear `localStorage`, re-render.

---

### Points system

| Goal difference | Winner | Loser |
|---|---|---|
| > 1 | 2 pts | 0 pts |
| = 1 | 2 pts | 1 pt |
| 0 (draw) | 1 pt | 1 pt |

---

### `computeRanking()`

Skip games where `scoreRed === 0 && scoreBlue === 0 && g.played !== true`.

Each player in a game gets their team's points plus GF/GA from that game regardless of position.

Sort: points → goal difference → goals scored → name (alphabetical).

---

### Ranking table

Columns: `#`, Player, GP, Pts, GF, GA, GD.

Row highlights:
- 1st: gold background + gold name.
- 2nd: steel/silver background + silver name.
- 3rd: bronze background + bronze name.
- Penultimate (only when `last > 2`, i.e. `i === last - 1` in 0-indexed): dark red background + red name (the shame spot).

---

### Toast notifications

Bottom-right, 2.8s auto-dismiss. Error variant has a red left border. Function: `toast(msg, isError=false)`.
