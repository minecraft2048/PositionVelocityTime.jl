# Use
#    @warnpcfail precompile(args...)
# if you want to be warned when a precompile directive fails
macro warnpcfail(ex::Expr)
    modl = __module__
    file = __source__.file === nothing ? "?" : String(__source__.file)
    line = __source__.line
    quote
        $(esc(ex)) || @warn """precompile directive
     $($(Expr(:quote, ex)))
 failed. Please report an issue in $($modl) (after checking for duplicates) or remove this directive.""" _file=$file _line=$line
    end
end


function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    @warnpcfail precompile(Tuple{typeof(PositionVelocityTime.calc_DOP), StaticArraysCore.SArray{Tuple{7, 4}, Float64, 2, 28}})
    @warnpcfail precompile(Tuple{typeof(PositionVelocityTime.calc_satellite_clock_drift), GNSSDecoder.GNSSDecoderState{GNSSDecoder.GPSL1Data, GNSSDecoder.GPSL1Constants, GNSSDecoder.GPSL1Cache, GNSSDecoder.UInt320}, Float64})
    @warnpcfail precompile(Tuple{typeof(PositionVelocityTime.calc_satellite_position_and_velocity), GNSSDecoder.GNSSDecoderState{GNSSDecoder.GPSL1Data, GNSSDecoder.GPSL1Constants, GNSSDecoder.GPSL1Cache, GNSSDecoder.UInt320}, Float64})
    @warnpcfail precompile(Tuple{typeof(PositionVelocityTime.correct_clock), GNSSDecoder.GNSSDecoderState{GNSSDecoder.GPSL1Data, GNSSDecoder.GPSL1Constants, GNSSDecoder.GPSL1Cache, GNSSDecoder.UInt320}, Float64})
    @warnpcfail precompile(Tuple{typeof(PositionVelocityTime.get_week), GNSSDecoder.GNSSDecoderState{GNSSDecoder.GPSL1Data, GNSSDecoder.GPSL1Constants, GNSSDecoder.GPSL1Cache, GNSSDecoder.UInt320}})
end
