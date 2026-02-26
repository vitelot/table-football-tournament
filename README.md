# Biliardino Tournament Manager

A two-part tool for running fair, competitive foosball (table soccer) tournaments among groups of players with heterogeneous skill levels.

---

## Overview

The system consists of two independent components:

- **`foosball_scheduler.jl`** — a Julia script that generates an optimised game schedule from a list of players and their Elo ratings.
- **`biliardino_tracker.html`** — a self-contained single-file web app for recording scores and tracking live standings during the tournament.

---

## How It Works

### Scheduling

Each player plays exactly **4 games**, one in each of the four positions: Red Defender (RD), Red Attacker (RA), Blue Defender (BD), Blue Attacker (BA). With *n* players this yields exactly *n* games.

The scheduler builds four independent random permutations of the player list (one per position) and zips them into games. This guarantees the position constraint by construction. A swap heuristic resolves any within-game player collisions and repeated team pairings while preserving the permutation structure globally.

Two constraints are enforced simultaneously:
- **Player uniqueness:** no player appears twice in the same game.
- **Team uniqueness:** no unordered team pair (e.g. Dubhe–Alcor is the same as Alcor–Dubhe) may appear more than once across the entire schedule.

Among 1,000,000 candidate schedules generated in parallel across all available CPU threads, the one minimising the **fairness score** is selected:

$$\mathcal{F} = \sum_{g} \left| \sqrt{\mathrm{Elo}_{\mathrm{RD}}^{(g)} \cdot \mathrm{Elo}_{\mathrm{RA}}^{(g)}} - \sqrt{\mathrm{Elo}_{\mathrm{BD}}^{(g)} \cdot \mathrm{Elo}_{\mathrm{BA}}^{(g)}} \right|$$

The geometric mean is used as the team strength estimator. Minimising $\mathcal{F}$ ensures that every game is as balanced as possible given the observed skill distribution. After optimisation the scheduler reports the best, worst, and median fairness scores observed across all candidates, giving a sense of how much the optimiser improved over a random draw.

### Scoring

| Goal difference | Winner | Loser |
|---|---|---|
| > 1 goal | 2 pts | 0 pts |
| = 1 goal | 2 pts | 1 pt |
| Draw | 1 pt | 1 pt |

Rankings are sorted by: **points → goal difference → goals scored → name**.

Games that end 0–0 are treated as **not played** unless explicitly marked otherwise in the tracker. They are excluded from the ranking until confirmed.

---

## Requirements

### Scheduler

- Julia ≥ 1.9
- Packages: `CSV.jl`, `DataFrames.jl`, `ProgressMeter.jl`

Install once:
```julia
using Pkg
Pkg.add(["CSV", "DataFrames", "ProgressMeter"])
```

### Tracker

- Any modern browser (Chrome, Firefox, Safari)
- No server, no build step, no dependencies to install
- Opens directly from `file://` — works fully offline

---

## Usage

### 1. Prepare your player list

Create `elos.csv` in your tournament folder:

```
name,elo
Sirio,2132
Alcor,1807
Mintaka,1680
Mizar,1950
```

### 2. Generate the schedule

```bash
cd /path/to/tournament
julia --project --threads auto foosball_scheduler.jl elos.csv
```

The scheduler prints a progress bar and the optimised schedule to the terminal, then writes **`table.csv`** to the same folder:

```
game,RD,RA,BD,BA,score_red,score_blue,tension
1,Sirio,Alcor,Mintaka,Mizar,,,42.3
2,...
```

The `score_red` and `score_blue` columns are intentionally blank — to be filled in during play. After optimisation, summary statistics are printed:

```
  Best  (min) fairness score : 142.30
  Worst (max) fairness score : 891.45
  Median      fairness score : 487.12
```

To use a fixed number of threads:
```bash
JULIA_NUM_THREADS=8 julia --project foosball_scheduler.jl elos.csv
```

### 3. Run the tracker

Open `biliardino_tracker.html` directly in your browser.

**Loading players:** paste the full contents of `elos.csv` into the Players box and click **Load**. The tracker auto-detects the format.

**Loading the schedule:** paste the full contents of `table.csv` into the same box and click **Load**. All games are imported automatically with scores initialised to 0–0 and marked as not played.

**Recording results:** the game entry form follows the same RD, RA, BD, BA column order as the schedule. Select the four players, enter the final score, and click **+ Add Result**. The ranking updates instantly.

**Editing results:** click **edit** on any game in the log. For a 0–0 result to count, tick the **Mark as played** checkbox in the edit modal.

**Session management:**
- **↓ Save** — downloads a full JSON snapshot with a timestamped filename.
- **↑ Load** — restores a previously saved JSON session.
- **Reset** — wipes all data after typing `YES!` to confirm.

---

## File Reference

| File | Description |
|---|---|
| `foosball_scheduler.jl` | Schedule optimiser (run once before the tournament) |
| `biliardino_tracker.html` | Score tracker (open in browser during the tournament) |
| `elos.csv` | Player names and Elo ratings (you provide this) |
| `table.csv` | Generated schedule (produced by the scheduler) |

---

## Background

The scheduling approach is a **randomised urn procedure** subject to two combinatorial constraints. Four position pools are constructed, each an independent uniformly random permutation of all *n* participants. The *g*-th game is formed by reading the *g*-th element from each pool, so every player appears in exactly one game per position. Conflicts — a player appearing twice in the same game, or the same unordered team pair appearing in more than one game — are resolved by a local swap heuristic. For each conflict, candidate swap partners are tried in random order; a swap is accepted only if it resolves the conflict in the affected game without introducing a new team repetition elsewhere. The best schedule among 10⁶ valid candidates, generated in parallel across all available CPU threads, is selected by minimising the aggregate Elo imbalance $\mathcal{F}$.

---

## License

MIT
