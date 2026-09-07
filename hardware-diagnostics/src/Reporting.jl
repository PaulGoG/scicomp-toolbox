"""
Report sinks (console and log file) and the in-terminal progress line.
"""
module Reporting

using Printf: @sprintf
using ..Formatting: format_seconds

export Reporter, emit, advance!, finish!

mutable struct ProgressState
    current::Int
    total::Int
    start_time::Float64
    label::String
end

"""
    Reporter(sinks::Vector{IO}; total::Int, console::IO = stdout)

Writes report lines to every sink and, when `console` is a terminal, maintains a
progress line with completion, elapsed time, estimated remaining time and the active
task. Log sinks never receive the progress line or any escape sequence.
"""
struct Reporter
    sinks::Vector{IO}
    console::IO
    interactive::Bool
    progress::ProgressState
end

function Reporter(sinks::Vector{IO}; total::Int, console::IO = stdout)
    interactive = console isa Base.TTY
    return Reporter(sinks, console, interactive, ProgressState(0, total, time(), ""))
end

"""
    emit(reporter::Reporter, text::AbstractString)

Print `text` as a line to every sink, keeping the progress line below it.
"""
function emit(reporter::Reporter, text::AbstractString)
    clear_progress(reporter)
    line = rstrip(text)
    for io in reporter.sinks
        println(io, line)
        flush(io)
    end
    render_progress(reporter)
    return nothing
end

"""
    advance!(reporter::Reporter, label::AbstractString, steps::Int = 1)

Advance the progress counter by `steps` and show `label` as the active task.
"""
function advance!(reporter::Reporter, label::AbstractString, steps::Int = 1)
    reporter.progress.current += steps
    reporter.progress.label = String(label)
    render_progress(reporter)
    return nothing
end

"""
    finish!(reporter::Reporter)

Remove the progress line.
"""
function finish!(reporter::Reporter)
    clear_progress(reporter)
    return nothing
end

function clear_progress(reporter::Reporter)
    reporter.interactive || return nothing
    print(reporter.console, "\r\033[K")
    return nothing
end

function render_progress(reporter::Reporter)
    reporter.interactive || return nothing
    state = reporter.progress
    state.total > 0 || return nothing
    fraction = clamp(state.current / state.total, 0.0, 1.0)
    width = 24
    filled = round(Int, fraction * width)
    bar = "█"^filled * "░"^(width - filled)
    elapsed = time() - state.start_time
    remaining = fraction > 0 ? elapsed / fraction - elapsed : NaN
    label = length(state.label) > 40 ? first(state.label, 37) * "..." : state.label
    print(
        reporter.console,
        @sprintf(
            "\r  [%s] %5.1f %%  elapsed %s  remaining %s  %s\033[K",
            bar,
            100 * fraction,
            format_seconds(elapsed),
            format_seconds(remaining),
            label
        )
    )
    flush(reporter.console)
    return nothing
end

end
