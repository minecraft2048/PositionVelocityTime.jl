#include("..//src//PVT.jl")
include("..//..//gnssdecoder.jl//src//GNSSDecoder.jl")

using Test, PVT, .GNSSDecoder
import .PVT: GNSSDecoderState, GPSData, GPSL1Constants


include("test_data.jl")
include("sat_position.jl")
include("user_position.jl")
include("PVT.jl")
include("sv_time.jl")