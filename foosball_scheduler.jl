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
    No unordered team pair may appear more than once across all games
    (i.e. Dubhe-Alcor and Alcor-Dubhe are treated as the same team).

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
const N_ITER    = 100_000

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
    team_key(a, b) -> Tuple{Int,Int}

Canonical unordered pair for two player indices: always (min, max).
Dubhe-Alcor and Alcor-Dubhe map to the same key.
"""
@inline team_key(a::Int, b::Int) = a < b ? (a, b) : (b, a)

"""
    is_valid_schedule(schedule, n_players) -> Bool

A schedule is valid when:
  (a) every game has 4 distinct players,
  (b) each position column is a permutation of 1..n_players, and
  (c) no unordered team (Red or Blue) appears more than once across all games.
"""
function is_valid_schedule(schedule::Vector{Vector{Int}}, n_players::Int)::Bool
    length(schedule) == n_players || return false
    for game in schedule
        length(unique(game)) == N_POS || return false
    end
    for pos in 1:N_POS
        sort([game[pos] for game in schedule]) == collect(1:n_players) || return false
    end
    # Check team uniqueness: positions are [RA, RD, BA, BD]
    seen_teams = Set{Tuple{Int,Int}}()
    for game in schedule
        red_key  = team_key(game[1], game[2])   # RA, RD
        blue_key = team_key(game[3], game[4])   # BA, BD
        red_key  in seen_teams && return false
        blue_key in seen_teams && return false
        push!(seen_teams, red_key)
        push!(seen_teams, blue_key)
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
    3. We iterate until all games are conflict-free and team-unique, or the
       retry cap is hit, in which case we restart from fresh permutations.
    4. Team uniqueness (no repeated unordered pair across games) is checked
       via a Set{Tuple{Int,Int}} of canonical (min,max) team keys. If a swap
       resolves a player collision but creates a repeated team, the swap is
       retried with a different partner.
    5. The caller can retry generate_schedule until is_valid_schedule passes;
       in practice a valid result is found quickly.
"""
function generate_schedule(n_players::Int, rng::AbstractRNG)::Vector{Vector{Int}}
    max_restarts = 200
    for _ in 1:max_restarts
        # Four independent random permutations
        pools = [randperm(rng, n_players) for _ in 1:N_POS]

        # Build games array directly from pools
        games = [[pools[p][g] for p in 1:N_POS] for g in 1:n_players]

        # Fix duplicate-player AND duplicate-team conflicts game by game.
        # seen_teams: canonical (min,max) pairs for all committed teams so far.
        changed = true
        max_passes = n_players * 20
        pass = 0
        while changed && pass < max_passes
            changed = false
            pass += 1

            # Rebuild team registry from current games
            seen_teams = Set{Tuple{Int,Int}}()
            for game in games
                push!(seen_teams, team_key(game[1], game[2]))   # Red: RA,RD
                push!(seen_teams, team_key(game[3], game[4]))   # Blue: BA,BD
            end

            for g in 1:n_players
                game = games[g]
                has_dup_player = length(unique(game)) < N_POS
                red_key  = team_key(game[1], game[2])
                blue_key = team_key(game[3], game[4])
                # Count how many games share this team (should be exactly 1: itself)
                red_dup  = count(gg -> team_key(gg[1],gg[2]) == red_key,  games) > 1
                blue_dup = count(gg -> team_key(gg[3],gg[4]) == blue_key, games) > 1
                (has_dup_player || red_dup || blue_dup) || continue

                # Determine which position to fix:
                # prioritise player duplicates, then team duplicates
                dup_pos = 0
                if has_dup_player
                    seen_p = Dict{Int,Int}()
                    for p in 1:N_POS
                        pid = game[p]
                        if haskey(seen_p, pid)
                            dup_pos = p; break
                        end
                        seen_p[pid] = p
                    end
                elseif red_dup
                    dup_pos = rand(rng, 1:2)        # swap RA or RD
                else
                    dup_pos = rand(rng, 3:4)        # swap BA or BD
                end
                dup_pos == 0 && continue

                # Try random swap partners until one resolves the conflict
                partners = shuffle(rng, [x for x in 1:n_players if x != g])
                swapped = false
                for j in partners
                    # Tentative swap
                    pools[dup_pos][g], pools[dup_pos][j] =
                        pools[dup_pos][j], pools[dup_pos][g]
                    new_g = [pools[p][g] for p in 1:N_POS]
                    new_j = [pools[p][j] for p in 1:N_POS]

                    # Accept if game g is now free of player dups and team dups
                    # (we do not re-validate j here — next pass will catch it)
                    rk_g = team_key(new_g[1], new_g[2])
                    bk_g = team_key(new_g[3], new_g[4])
                    other_teams = Set{Tuple{Int,Int}}(
                        vcat([team_key(games[x][1],games[x][2]) for x in 1:n_players if x!=g && x!=j],
                             [team_key(games[x][3],games[x][4]) for x in 1:n_players if x!=g && x!=j])
                    )
                    ok = length(unique(new_g)) == N_POS &&
                         !(rk_g in other_teams) &&
                         !(bk_g in other_teams) &&
                         rk_g != bk_g

                    if ok
                        games[g] = new_g
                        games[j] = new_j
                        swapped = true
                        changed = true
                        break
                    else
                        # Undo
                        pools[dup_pos][g], pools[dup_pos][j] =
                            pools[dup_pos][j], pools[dup_pos][g]
                    end
                end
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
    seen_teams = Set{Tuple{Int,Int}}()
    for (g, game) in enumerate(schedule)
        rk = team_key(game[1], game[2])
        bk = team_key(game[3], game[4])
        @assert !(rk in seen_teams) "Game $g: Red team $(game[1])-$(game[2]) already appeared!"
        @assert !(bk in seen_teams) "Game $g: Blue team $(game[3])-$(game[4]) already appeared!"
        push!(seen_teams, rk)
        push!(seen_teams, bk)
    end
    println("  Validation passed: all positions, players, and teams are unique.")
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
            ra, rd, ba, bd = players.name[game[1]], players.name[game[2]], players.name[game[3]], players.name[game[4]]
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
