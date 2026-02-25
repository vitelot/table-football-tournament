"""
foosball_scheduler.jl
=====================
Generates a fair foosball (table soccer) tournament schedule from a CSV file.

Usage:
    julia --threads auto foosball_scheduler.jl players.csv

Or set threads explicitly:
    JULIA_NUM_THREADS=8 julia foosball_scheduler.jl players.csv

CSV format (required columns):
    name  - player name (String)
    elo   - player Elo rating (Float or Int)

Rules:
    Each player plays exactly 4 games, one in each position:
        RA (Red Attacker), RD (Red Defender),
        BA (Blue Attacker), BD (Blue Defender).
    With n players this yields exactly n games.

Optimization:
    Runs 1,000,000 candidate schedules in parallel and selects the one
    with the minimum "Fairness Score" (sum of per-game Elo tension).

    Team Elo   = sqrt(Player1_Elo x Player2_Elo)
    Tension    = |TeamRed_Elo - TeamBlue_Elo|
    Fairness   = sum(Tension) over all games  <- minimize this
"""

using CSV
using DataFrames
using Statistics
using Random
using Printf

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
const POSITIONS = ["RA", "RD", "BA", "BD"]
const N_POS     = 4
const N_ITER    = 1_000_000

# ---------------------------------------------------------------------------
# Elo objective helpers
# ---------------------------------------------------------------------------

@inline team_elo(e1::Float64, e2::Float64) = sqrt(e1 * e2)

@inline function game_tension(e::NTuple{4,Float64})
    return abs(team_elo(e[1], e[2]) - team_elo(e[3], e[4]))
end

function schedule_score(schedule::Vector{Vector{Int}}, elos::Vector{Float64})
    total = 0.0
    for game in schedule
        t = (elos[game[1]], elos[game[2]], elos[game[3]], elos[game[4]])
        total += game_tension(t)
    end
    return total
end

# ---------------------------------------------------------------------------
# Schedule generation
# ---------------------------------------------------------------------------

"""
    is_valid_schedule(schedule, n_players) -> Bool

A schedule is valid when:
  (a) every game has 4 distinct players, and
  (b) each position column is a permutation of 1..n_players.
"""
function is_valid_schedule(schedule::Vector{Vector{Int}}, n_players::Int)::Bool
    length(schedule) == n_players || return false
    for game in schedule
        length(unique(game)) == N_POS || return false
    end
    for pos in 1:N_POS
        sort([game[pos] for game in schedule]) == collect(1:n_players) || return false
    end
    return true
end

"""
    generate_schedule(n_players, rng) -> Vector{Vector{Int}}

Build a valid candidate schedule using the urn + swap approach.

Algorithm:
    1. Start with four independent random permutations of 1..n_players,
       one per position. Zipping them gives n games where every player
       appears exactly once per position by construction.
    2. The only constraint left to satisfy is that the four players in each
       game are distinct. When game g has a duplicate in position p, we swap
       pools[p][g] with a randomly chosen slot j != g in the same pool,
       then re-sync games[j] to reflect the swap.
    3. We iterate until all games are conflict-free or the retry cap is hit,
       in which case we restart from fresh permutations.
    4. The caller can retry generate_schedule until is_valid_schedule passes;
       in practice a valid result is found on the first or second attempt.
"""
function generate_schedule(n_players::Int, rng::AbstractRNG)::Vector{Vector{Int}}
    max_restarts = 200
    for _ in 1:max_restarts
        # Four independent random permutations
        pools = [randperm(rng, n_players) for _ in 1:N_POS]

        # Build games array directly from pools
        games = [[pools[p][g] for p in 1:N_POS] for g in 1:n_players]

        # Fix duplicate-player conflicts game by game
        changed = true
        max_passes = n_players * 10
        pass = 0
        while changed && pass < max_passes
            changed = false
            pass += 1
            for g in 1:n_players
                length(unique(games[g])) == N_POS && continue

                # Find a duplicated position in this game
                seen = Dict{Int,Int}()
                dup_pos = 0
                for p in 1:N_POS
                    pid = games[g][p]
                    if haskey(seen, pid)
                        dup_pos = p
                        break
                    end
                    seen[pid] = p
                end
                dup_pos == 0 && continue

                # Pick a random swap partner (any other game slot)
                j = rand(rng, 1:n_players-1)
                j = j >= g ? j + 1 : j   # skip self

                # Swap in the pool and re-sync both affected games
                pools[dup_pos][g], pools[dup_pos][j] =
                    pools[dup_pos][j], pools[dup_pos][g]
                games[g][dup_pos] = pools[dup_pos][g]
                games[j][dup_pos] = pools[dup_pos][j]
                changed = true
            end
        end

        is_valid_schedule(games, n_players) && return games
    end

    # Fallback: brute-force a valid schedule via repeated Fisher-Yates
    # (guaranteed to terminate for n >= 4)
    return _fallback_schedule(n_players, rng)
end

"""
    _fallback_schedule(n_players, rng) -> Vector{Vector{Int}}

Last-resort scheduler: repeatedly shuffle one pool and check for
conflicts, using rejection sampling. Slow but always correct.
"""
function _fallback_schedule(n_players::Int, rng::AbstractRNG)::Vector{Vector{Int}}
    pools = [randperm(rng, n_players) for _ in 1:N_POS]
    while true
        games = [[pools[p][g] for p in 1:N_POS] for g in 1:n_players]
        if is_valid_schedule(games, n_players)
            return games
        end
        # Reshuffle the most-conflicted pool
        shuffle!(rng, pools[rand(rng, 1:N_POS)])
    end
end

# ---------------------------------------------------------------------------
# Threaded optimisation loop
# ---------------------------------------------------------------------------

"""
    optimise(n_players, elos; n_iter) -> (best_schedule, best_score)

Run `n_iter` schedule generations across all available threads.
Each thread keeps its own best; results are merged at the end.
"""
function optimise(n_players::Int, elos::Vector{Float64}; n_iter::Int = N_ITER)
    n_threads = Threads.nthreads()
    iter_per_thread = cld(n_iter, n_threads)

    thread_best_scores    = fill(Inf, n_threads)
    thread_best_schedules = Vector{Vector{Vector{Int}}}(undef, n_threads)

    Threads.@threads for t in 1:n_threads
        rng = MersenneTwister(t * 31337)
        local_best_score    = Inf
        local_best_schedule = Vector{Vector{Int}}()

        for _ in 1:iter_per_thread
            candidate = generate_schedule(n_players, rng)
            score     = schedule_score(candidate, elos)
            if score < local_best_score
                local_best_score    = score
                local_best_schedule = deepcopy(candidate)
            end
        end

        thread_best_scores[t]    = local_best_score
        thread_best_schedules[t] = local_best_schedule
    end

    best_idx = argmin(thread_best_scores)
    return thread_best_schedules[best_idx], thread_best_scores[best_idx]
end

# ---------------------------------------------------------------------------
# Validation (called once on the final result)
# ---------------------------------------------------------------------------

function validate_schedule!(schedule::Vector{Vector{Int}}, n_players::Int)
    for (pos_idx, pos_label) in enumerate(POSITIONS)
        col = sort([game[pos_idx] for game in schedule])
        @assert col == collect(1:n_players) "Position $pos_label is not a valid permutation!"
    end
    for (g, game) in enumerate(schedule)
        @assert length(unique(game)) == N_POS "Game $g has duplicate players: $game"
    end
    println("  Validation passed: every player plays exactly once per position.")
end

# ---------------------------------------------------------------------------
# Pretty-print results
# ---------------------------------------------------------------------------

function print_schedule(schedule::Vector{Vector{Int}},
                        players::DataFrame,
                        elos::Vector{Float64})
    col_w = 16
    sep   = " | "
    width = 6 + (col_w + length(sep)) * 5 + 10

    println("\n", "="^width)
    println("  OPTIMISED FOOSBALL SCHEDULE")
    println("  Each player plays exactly 4 games, one per position")
    println("="^width)

    header = lpad("Game", 6) * sep *
             lpad("RA", col_w) * sep *
             lpad("RD", col_w) * sep *
             lpad("BA", col_w) * sep *
             lpad("BD", col_w) * sep *
             rpad("Tension", 10)
    println(header)
    println("-"^width)

    total_tension = 0.0
    for (g, game) in enumerate(schedule)
        pnames = [rpad(players.name[i], col_w) for i in game]
        e      = Tuple(elos[i] for i in game)
        t      = game_tension(e)
        total_tension += t

        row = lpad(string(g), 6) * sep *
              pnames[1] * sep *
              pnames[2] * sep *
              pnames[3] * sep *
              pnames[4] * sep *
              lpad(@sprintf("%.1f", t), 10)
        println(row)
    end

    println("="^width)
    @printf "  Fairness Score (minimised): %.2f\n" total_tension
    println("="^width)
    println()
end

# ---------------------------------------------------------------------------
# Save schedule to CSV
# ---------------------------------------------------------------------------

"""
    save_table_csv(schedule, players, elos; path="table.csv")

Write the optimised schedule to a CSV with columns:
    game, RA, RD, BA, BD, score_red, score_blue, tension
score_red and score_blue are left blank to be filled in during the tournament.
"""
function save_table_csv(schedule::Vector{Vector{Int}},
                        players::DataFrame,
                        elos::Vector{Float64};
                        path::String = "table.csv")
    open(path, "w") do io
        println(io, "game,RD,RA,BD,BA,score_red,score_blue,tension")
        for (g, game) in enumerate(schedule)
            ra, rd, ba, bd = [players.name[i] for i in game]
            e = Tuple(elos[i] for i in game)
            t = game_tension(e)
            println(io, "$g,$rd,$ra,$bd,$ba,,,$(round(t; digits=1))")
        end
    end
    println("  Saved schedule to '$path'.")
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main()
    if length(ARGS) < 1
        println("Usage: julia --threads auto foosball_scheduler.jl <players.csv>")
        println("  CSV must have columns: name, elo")
        exit(1)
    end

    csv_path = ARGS[1]
    isfile(csv_path) || error("File not found: $csv_path")

    players = CSV.read(csv_path, DataFrame)
    @assert "name" in names(players) "CSV must contain a 'name' column"
    @assert "elo"  in names(players) "CSV must contain an 'elo' column"

    players.elo = Float64.(players.elo)
    n_players   = nrow(players)
    elos        = players.elo

    println("\nLoaded $n_players players from '$csv_path'.")
    println("Active threads   : $(Threads.nthreads())")
    println("Games to schedule: $n_players  (each player plays RA, RD, BA, BD once)")
    println("Iterations       : $N_ITER\n")

    t_start = time()
    best_schedule, _ = optimise(n_players, elos; n_iter = N_ITER)
    elapsed = time() - t_start

    @printf "Optimisation complete in %.1f seconds.\n" elapsed

    validate_schedule!(best_schedule, n_players)
    print_schedule(best_schedule, players, elos)
    save_table_csv(best_schedule, players, elos)
end

main()
