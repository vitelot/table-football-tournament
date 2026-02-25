#!/usr/bin/env julia
# serve.jl
# Minimal static file server — run from the tournament folder.
#
# Usage:
#   julia serve.jl
#   julia serve.jl 9000        # custom port
#
# Then open: http://localhost:8080/biliardino_tracker.html

using Sockets

const PORT    = length(ARGS) > 0 ? parse(Int, ARGS[1]) : 8080
const ROOTDIR = @__DIR__

const MIME_TYPES = Dict(
    ".html" => "text/html; charset=utf-8",
    ".css"  => "text/css; charset=utf-8",
    ".js"   => "application/javascript; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".csv"  => "text/csv; charset=utf-8",
    ".png"  => "image/png",
    ".jpg"  => "image/jpeg",
    ".ico"  => "image/x-icon",
)

function mime(path)
    _, ext = splitext(path)
    get(MIME_TYPES, lowercase(ext), "application/octet-stream")
end

function handle(conn)
    try
        request = readline(conn)
        # Drain remaining headers
        while true
            line = readline(conn)
            isempty(strip(line)) && break
        end

        # Parse: "GET /path HTTP/1.1"
        parts = split(request)
        if length(parts) < 2
            write(conn, "HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        end

        rawpath = parts[2]
        # Strip query string
        urlpath = split(rawpath, '?')[1]
        # Default index
        urlpath == "/" && (urlpath = "/biliardino_tracker.html")

        # Prevent path traversal
        filepath = normpath(joinpath(ROOTDIR, lstrip(urlpath, '/')))
        if !startswith(filepath, ROOTDIR)
            write(conn, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        end

        if isfile(filepath)
            body = read(filepath)
            headers = """HTTP/1.1 200 OK\r
Content-Type: $(mime(filepath))\r
Content-Length: $(length(body))\r
Cache-Control: no-cache\r
Connection: close\r
\r
"""
            write(conn, headers)
            write(conn, body)
        else
            msg = "404 Not Found: $urlpath"
            headers = """HTTP/1.1 404 Not Found\r
Content-Type: text/plain\r
Content-Length: $(length(msg))\r
Connection: close\r
\r
"""
            write(conn, headers)
            write(conn, msg)
        end
    catch e
        # Silently ignore broken pipe / connection reset errors
    finally
        close(conn)
    end
end

println("Biliardino server running at http://localhost:$PORT")
println("Serving files from: $ROOTDIR")
println("Press Ctrl+C to stop.\n")

server = listen(PORT)
while true
    conn = accept(server)
    @async handle(conn)
end
