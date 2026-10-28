# Time-budgeted repetition of one benchmark evaluation and robust summary statistics.

"""
    SamplingPolicy(; min_sampling_time_s, min_samples, max_samples, max_point_seconds)

Stopping rule of [`sample_timings`](@ref): sampling continues until at least
`min_samples` evaluations have consumed at least `min_sampling_time_s`, stops at
`max_samples`, and stops early once the accumulated time exceeds `max_point_seconds`.
The last cap overrides `min_samples`, so a slow point may stop after one evaluation.
"""
struct SamplingPolicy
    min_sampling_time_s::Float64
    min_samples::Int
    max_samples::Int
    max_point_seconds::Float64

    function SamplingPolicy(;
        min_sampling_time_s::Real,
        min_samples::Integer,
        max_samples::Integer,
        max_point_seconds::Real,
    )
        min_sampling_time_s > 0 || throw(
            ArgumentError("min_sampling_time_s must be > 0, got $min_sampling_time_s"),
        )
        min_samples >= 1 ||
            throw(ArgumentError("min_samples must be >= 1, got $min_samples"))
        max_samples >= min_samples || throw(
            ArgumentError(
                "max_samples must be >= min_samples, got $max_samples < $min_samples",
            ),
        )
        max_point_seconds > 0 ||
            throw(ArgumentError("max_point_seconds must be > 0, got $max_point_seconds"))
        return new(
            Float64(min_sampling_time_s),
            Int(min_samples),
            Int(max_samples),
            Float64(max_point_seconds),
        )
    end
end

"""
    TimingSummary

Statistics of the sampled evaluation times in seconds: sample count, minimum, median
and median absolute deviation (`NaN` for a single sample).
"""
struct TimingSummary
    samples::Int
    min_s::Float64
    median_s::Float64
    mad_s::Float64
end

"""
    sample_timings(evaluate, policy::SamplingPolicy) -> Vector{Float64}

Wall-clock durations in seconds of repeated calls to `evaluate()` (which must include
any device synchronization), following `policy`. The caller performs warm-up. The cap
`max_point_seconds` on the accumulated time is checked before `min_samples`.
"""
function sample_timings(evaluate::F, policy::SamplingPolicy) where {F}
    times = Float64[]
    t_begin = time_ns()
    while true
        t0 = time_ns()
        evaluate()
        t1 = time_ns()
        push!(times, (t1 - t0) / 1e9)
        elapsed = (t1 - t_begin) / 1e9
        n = length(times)
        n >= policy.max_samples && break
        elapsed >= policy.max_point_seconds && break
        (n >= policy.min_samples && elapsed >= policy.min_sampling_time_s) && break
    end
    return times
end

"""
    summarize_timings(times::AbstractVector{<:Real}) -> TimingSummary

Minimum, median and median absolute deviation of `times`. The deviation is defined
from two samples on and is `NaN` for a single one.
"""
function summarize_timings(times::AbstractVector{<:Real})
    isempty(times) && throw(ArgumentError("cannot summarize an empty sample"))
    values = Float64.(times)
    center = median(values)
    mad_s = length(values) >= 2 ? median(abs.(values .- center)) : NaN
    return TimingSummary(length(values), minimum(values), center, mad_s)
end
