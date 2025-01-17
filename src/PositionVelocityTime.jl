module PositionVelocityTime
using CoordinateTransformations,
    DocStringExtensions,
    Geodesy,
    GNSSDecoder,
    GNSSSignals,
    LinearAlgebra,
    Parameters,
    AstroTime,
    LsqFit,
    StaticArrays,
    Tracking,
    Unitful,
    Statistics,
    PrecompileTools

using Unitful: s, Hz

const SPEEDOFLIGHT = 299792458.0

export calc_pvt,
    PVTSolution,
    SatelliteState,
    get_LLA,
    get_num_used_sats,
    calc_satellite_position,
    calc_satellite_position_and_velocity,
    get_sat_enu,
    get_gdop,
    get_pdop,
    get_hdop,
    get_vdop,
    get_tdop,
    get_frequency_offset

"""
Struct of decoder, code- and carrierphase of satellite
"""
@with_kw struct SatelliteState{CP<:Real}
    decoder::GNSSDecoder.GNSSDecoderState
    system::AbstractGNSS
    code_phase::CP
    carrier_doppler::typeof(1.0Hz)
    carrier_phase::CP = 0.0
end

function SatelliteState(
    decoder::GNSSDecoder.GNSSDecoderState,
    tracking_results::Tracking.TrackingResults,
)
    SatelliteState(
        decoder,
        get_system(tracking_results),
        get_code_phase(tracking_results),
        get_carrier_doppler(tracking_results),
        get_carrier_phase(tracking_results),
    )
end

"""
Dilution of Precision (DOP)
"""
struct DOP
    GDOP::Float64
    PDOP::Float64
    VDOP::Float64
    HDOP::Float64
    TDOP::Float64
end

struct SatInfo
    position::ECEF
    time::Float64
end

"""
PVT solution including DOP, used satellites and satellite
positions.
"""
@with_kw struct PVTSolution
    position::ECEF = ECEF(0, 0, 0)
    velocity::ECEF = ECEF(0, 0, 0)
    time_correction::Float64 = 0
    time::Union{TAIEpoch{Float64},Nothing} = nothing
    relative_clock_drift::Float64 = 0
    dop::Union{DOP,Nothing} = nothing
    sats::Dict{Int, SatInfo} = Dict{Int, SatInfo}()
end

function get_num_used_sats(pvt_solution::PVTSolution)
    length(pvt_solution.used_sats)
end

#Get methods for single DOP values
function get_gdop(pvt_sol::PVTSolution)
    return pvt_sol.dop.GDOP
end

function get_pdop(pvt_sol::PVTSolution)
    return pvt_sol.dop.PDOP
end

function get_vdop(pvt_sol::PVTSolution)
    return pvt_sol.dop.VDOP
end

function get_hdop(pvt_sol::PVTSolution)
    return pvt_sol.dop.HDOP
end

function get_tdop(pvt_sol::PVTSolution)
    return pvt_sol.dop.TDOP
end



function Base.show(io::IO, ::MIME"text/plain", res::PVTSolution)
    lla = get_LLA(res)
    println(io, "PVT solution at $(res.time): ")
    println(io, "Position: lat=$(lla.lat)° lon=$(lla.lon)° alt=$(lla.alt) m")
    println(io, "(GDOP: $(res.dop.GDOP))")
    println(io, "Velocity: x=$(res.velocity[1]) m/s y=$(res.velocity[2]) m/s z=$(res.velocity[3]) m/s")
    println(io, "Satellites used for this navigation solution: $(length(res.sats))")
    println(io, "Relative clock drift: $(res.relative_clock_drift)")
end

"""
Calculates East-North-Up (ENU) coordinates of satellite in spherical
form (azimuth and elevation).

$SIGNATURES
user_pos_ecef: user position in ecef coordinates
sat_pos_ecef: satellite position in ecef coordinates
"""
function get_sat_enu(user_pos_ecef::ECEF, sat_pos_ecef::ECEF)
    sat_enu = ENUfromECEF(user_pos_ecef, wgs84)(sat_pos_ecef)
    SphericalFromCartesian()(sat_enu)
end

"""
Calculates Position Velocity and Time (PVT).
Note: Estimation of velocity still needs to be implemented.

$SIGNATURES
`system`: GNSS system
`states`: Vector satellite states (SatelliteState)
`prev_pvt` (optionally): Previous PVT solution to accelerate calculation of next
    PVT.
"""
function calc_pvt(
    states::AbstractVector{<:SatelliteState},
    prev_pvt::PVTSolution = PVTSolution(),
)
    length(states) < 4 &&
        throw(ArgumentError("You'll need at least 4 satellites to calculate PVT"))
    all(state -> state.system == states[1].system, states) ||
        ArgumentError("For now all satellites need to be base on the same GNSS")
    system = first(states).system
    healthy_states = filter(x -> is_sat_healthy(x.decoder), states)
    if length(healthy_states) < 4
        return prev_pvt
    end
    prev_ξ = [prev_pvt.position; prev_pvt.time_correction]
    healthy_prns = map(state -> state.decoder.prn, healthy_states)
    times = map(state -> calc_corrected_time(state), healthy_states)
    sat_positions_and_velocities = map(
        (state, time) -> calc_satellite_position_and_velocity(state.decoder, time),
        healthy_states,
        times,
    )
    sat_positions = map(get_sat_position, sat_positions_and_velocities)
    pseudo_ranges, reference_time = calc_pseudo_ranges(times)
    ξ, rmse = user_position(sat_positions, pseudo_ranges)
    user_velocity_and_clock_drift =
        calc_user_velocity_and_clock_drift(sat_positions_and_velocities, ξ, healthy_states)
    position = ECEF(ξ[1], ξ[2], ξ[3])
    velocity = ECEF(
        user_velocity_and_clock_drift[1],
        user_velocity_and_clock_drift[2],
        user_velocity_and_clock_drift[3],
    )
    relative_clock_drift = user_velocity_and_clock_drift[4] / SPEEDOFLIGHT
    time_correction = ξ[4]
    corrected_reference_time = reference_time + time_correction / (-SPEEDOFLIGHT)

    week = get_week(first(healthy_states).decoder)
    start_time = get_system_start_time(first(healthy_states).decoder)
    time = TAIEpoch(
        week * 7 * 24 * 60 * 60 + floor(Int, corrected_reference_time) + start_time.second,
        corrected_reference_time - floor(Int, corrected_reference_time),
    )

    sat_infos = SatInfo.(
        sat_positions,
        times
    )

    dop = calc_DOP(calc_H(reduce(hcat, sat_positions), ξ))
    if dop.GDOP < 0
        return prev_pvt
    end

    PVTSolution(
        position,
        velocity,
        time_correction,
        time,
        relative_clock_drift,
        dop,
        Dict(healthy_prns .=> sat_infos)
    )
end

function get_frequency_offset(pvt::PVTSolution, base_frequency)
    pvt.relative_clock_drift * base_frequency
end

function get_system_start_time(
    decoder::GNSSDecoder.GNSSDecoderState{<:GNSSDecoder.GPSL1Data},
)
    TAIEpoch(1980, 1, 6, 0, 0, 19.0) # There were 19 leap seconds at 01/06/1999 compared to UTC
end

function get_system_start_time(
    decoder::GNSSDecoder.GNSSDecoderState{<:GNSSDecoder.GalileoE1BData},
)
    TAIEpoch(1999, 8, 22, 0, 0, (32 - 13.0)) # There were 32 leap seconds at 08/22/1999 compared to UTC
end

function get_week(decoder::GNSSDecoder.GNSSDecoderState{<:GNSSDecoder.GPSL1Data})
    2048 + decoder.data.trans_week #todo make this flexible
end

function get_week(decoder::GNSSDecoder.GNSSDecoderState{<:GNSSDecoder.GalileoE1BData})
    decoder.data.WN
end

function get_LLA(pvt::PVTSolution)
    LLAfromECEF(wgs84)(pvt.position)
end

include("user_position.jl")
include("sat_time.jl")
include("sat_position.jl")

#= @setup_workload begin
    # Putting some things in `@setup_workload` instead of `@compile_workload` can reduce the size of the
    # precompile file and potentially make loading faster.
    using BitIntegers, Test
    @compile_workload begin
        # all calls in this block will be precompiled, regardless of whether
        # they belong to your package or not (on Julia 1.8 and higher)
        include("../test/pvt.jl")
    end
end
 =#

 include("precompile.jl")
_precompile_()


end
