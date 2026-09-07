"""
Human-readable formatting of byte counts, durations and throughputs.
"""
module Formatting

using Printf: @sprintf

export format_bytes, format_seconds, format_throughput

"""
    format_bytes(bytes::Real) -> String

Format a byte quantity in IEC units (B, KiB, MiB, GiB, TiB) with two decimals.
"""
function format_bytes(bytes::Real)
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    value = Float64(bytes)
    index = 1
    while value >= 1024.0 && index < length(units)
        value /= 1024.0
        index += 1
    end
    return @sprintf("%.2f %s", value, units[index])
end

"""
    format_seconds(seconds::Real) -> String

Format a duration as `S.sss s` below one second and `MMm SSs` otherwise; `--:--` for
negative or non-finite input.
"""
function format_seconds(seconds::Real)
    (isfinite(seconds) && seconds >= 0) || return "--:--"
    seconds < 1.0 && return @sprintf("%.3f s", seconds)
    minutes = floor(Int, seconds / 60)
    remainder = floor(Int, seconds % 60)
    return @sprintf("%02dm %02ds", minutes, remainder)
end

"""
    format_throughput(gops::Real, ::Type{T}) -> String

Format a throughput given in 10⁹ operations per second: GFLOP/s or TFLOP/s for
floating-point and complex floating-point element types, GOP/s or TOP/s for integers.
"""
function format_throughput(gops::Real, ::Type{T}) where {T}
    is_float = T <: AbstractFloat || T <: Complex{<:AbstractFloat}
    unit = is_float ? "FLOP/s" : "OP/s"
    gops >= 1000.0 && return @sprintf("%.2f T%s", gops / 1000.0, unit)
    return @sprintf("%.2f G%s", gops, unit)
end

end
