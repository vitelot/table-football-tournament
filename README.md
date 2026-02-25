# Biliardino Tournament Manager

A two-part tool for running fair, competitive foosball (table soccer) tournaments among groups of players with heterogeneous skill levels.

---

## Overview

The system consists of two independent components:

- **`foosball_scheduler.jl`** — a Julia script that generates an optimised game schedule from a list of players and their Elo ratings.
- **`biliardino_tracker.html`** — a self-contained single-file web app for recording scores and tracking the live standings during the tournament.

---

## How It Works

### Scheduling

Each player plays exactly **4 games**, one in each of the four positions: Red Defender (RD), Red Attacker (RA), Blue Defender (BD), Blue Attacker (BA). With *n* players this yields exactly *n* games.

The scheduler builds four independent random permutations of the player list (one per position) and zips them into games. This guarantees the position constraint by construction. A swap heuristic resolves any within-game player collisions while preserving the permutation structure.

Among 1,000,000 candidate schedules (generated in parallel across all available CPU threads), the one minimising the **fairness score** is selected:

$$\mathcal{F} = \sum_{g} \left| \sqrt{\mathrm{Elo}_{\mathrm{RD}}^{(g)} \cdot \mathrm{Elo}_{\mathrm{RA}}^{(g)}} - \sqrt{\mathrm{Elo}_{\mathrm{BD}}^{(g)} \cdot \mathrm{Elo}_{\mathrm{BA}}^{(g)}} \right|$$

The geometric mean is used as the team strength estimator. Minimising $\mathcal{F}$ ensures that every game is as balanced as possible given the observed skill distribution.

### Scoring

| Goal difference | Winner | Loser |
|---|---|---|
| > 1 goal | 2 pts | 0 pts |
| = 1 goal | 2 pts | 1 pt  |
| Draw      | 1 pt  | 1 pt  |

Rankings are sorted by: **points → goal difference → goals scored → name**.

---

## Requirements

### Scheduler

- Julia ≥ 1.9
- Standard library only: `Sockets`, `Random`, `Printf`, `Statistics`
- Packages: `CSV.jl`, `DataFrames.jl`

Install packages once:
```julia
using Pkg
Pkg.add(["CSV", "DataFrames"])
```

### Tracker

- Any modern browser (Chrome, Firefox, Safari)
- No server, no build step, no dependencies to install

---

## Usage

### 1. Prepare your player list

Create `elos.csv` in your tournament folder:

```
name,elo
Sirio,2132
Antares,1807
Alcor,1680
Dubhe,1950
...
```

### 2. Generate the schedule

```bash
cd /path/to/tournament
julia --threads auto foosball_scheduler.jl elos.csv
```

This prints the optimised schedule to the terminal and writes **`table.csv`** to the same folder:

```
game,RD,RA,BD,BA,score_red,score_blue,tension
1,Sirio,Antares,Alcor,Dubhe,,,42.3
2,...
```

The `score_red` and `score_blue` columns are intentionally blank — to be filled in during play.

To use a specific number of threads:
```bash
JULIA_NUM_THREADS=8 julia foosball_scheduler.jl elos.csv
```

### 3. Run the tracker

Open `biliardino_tracker.html` directly in your browser (no server needed).

**Loading players:** paste the full contents of `elos.csv` into the Players box and click **Load**.

**Loading the schedule:** paste the full contents of `table.csv` into the same box and click **Load**. All games are imported automatically with scores initialised to 0–0.

**Recording results:** select the four players and enter the final score, then click **Add Result**. The ranking updates instantly.

**Saving:** click **↓ Save** to download a full JSON snapshot of the session. The filename includes the date and time.

**Resetting:** click **Reset** in the header. You must type `YES!` to confirm — this wipes all games and players from memory and localStorage.

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

The scheduling approach is a **randomised urn procedure** subject to a combinatorial fairness constraint. Four position pools are constructed, each consisting of an independent uniformly random permutation of all *n* participants. The *g*-th game is formed by reading the *g*-th element from each pool, so that every player appears in exactly one game per position. Collisions (a player appearing twice in the same game) are resolved by a local swap heuristic that preserves the permutation structure globally. The best schedule among 10⁶ independently sampled valid candidates — generated in parallel across available CPU threads — is selected by minimising the aggregate Elo imbalance $\mathcal{F}$ across all games.

For a more detailed description of the procedure suitable for sharing with participants, see the companion document `tournament_procedure.docx`.

---

## License

MIT
