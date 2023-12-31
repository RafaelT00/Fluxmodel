using Flux

"""
Channelshuffle(channels, groups)

Channel shuffle operation from 'ShuffleNet: An Extremely Efficient Convolutional Neural Network for Mobile Devices
([reference](https://arxiv.org/abs/1707.01083)).

# Arguments

  - `channels`: number of channels
  - `groups`: number of groups
"""
function ChannelShuffle(x::Array{Float32, 4}, g::Int)
    width, height, channels, batch = size(x)
    channels_per_group = channels÷g
    if (channels % g) == 0
        x = reshape(x, (width, height, g, channels_per_group, batch))
        x = permutedims(x,(1,2,4,3,5))
        x = reshape(x, (width, height, channels, batch))
    end
    return x
end


function ShuffleUnit(in_channels::Integer, out_channels::Integer, grps::Integer, downsample::Bool, ignore_group::Bool)
    mid_channels = out_channels ÷ 4
    grps = ignore_group ? 1 : grps
    strd = downsample ? 2 : 1

    if downsample
        out_channels -= in_channels
    end

    m = Chain(Conv((1,1), in_channels => mid_channels; groups=grps,pad=SamePad()),
              BatchNorm(mid_channels),
              NNlib.relu,
              x -> ChannelShuffle(x, grps),
              DepthwiseConv((3,3),  mid_channels => mid_channels; bias=false, stride=strd, pad=SamePad()),
              BatchNorm(mid_channels),
              NNlib.relu,
              Conv((1,1), mid_channels => out_channels; groups=grps, pad=SamePad()),
              BatchNorm(out_channels),
              NNlib.relu)
    
    if downsample
        m = Parallel((mx, x) -> cat(mx, x, dims=3),m, MeanPool((3,3); pad=SamePad(), stride=2))
    else
        m = SkipConnection(m, +)
    end
    return m
end

function ShuffleInitBlock(in_channels::Integer, out_channels::Integer)
    m = Chain(Conv((3,3), in_channels => out_channels, relu; stride=2, pad=SamePad()),
              BatchNorm(out_channels),
              MaxPool((3,3); stride=2, pad=SamePad())
    )
    return m
end


function ShuffleNet(channels, init_block_channels::Integer, groups; in_channels=3, num_classes=1000)
    features = []

    append!(features, [Conv((3,3), in_channels => init_block_channels; stride=2, pad=SamePad()),
    BatchNorm(init_block_channels),
    NNlib.relu,
    MaxPool((3,3); stride=2, pad=SamePad())])

    in_channels::Integer = init_block_channels
  
    for (i, num_channels) in enumerate(channels)
        stage = []
        for (j, out_channels) in enumerate(num_channels)
            downsample = j==1
            ignore_group = i==1 && j==1
            out_ch::Integer = trunc(out_channels)
            push!(stage, ShuffleUnit(in_channels, out_ch, groups, downsample, ignore_group))
            in_channels = out_ch
        end
        append!(features, stage)
    end
  
    model = Chain(features...)
  
    return Chain(model, GlobalMeanPool(), Flux.flatten, Dense(in_channels => num_classes))
end

function get_shufflenet(groups, width_scale; in_channels=3, num_classes=1000)
    init_block_channels = 24
    layers = [4, 8, 4]

    if groups == 1
        channels_per_layers = [144, 288, 576]
    elseif groups == 2
        channels_per_layers = [200, 400, 800]
    elseif groups == 3
        channels_per_layers = [240, 480, 960]
    elseif groups == 4
        channels_per_layers = [272, 544, 1088]
    elseif groups == 8
        channels_per_layers = [384, 768, 1536]
    else
        return error("The number of groups is not supported. Groups = ", groups)
    end

    channels = []
    for i in eachindex(layers)
        char = [channels_per_layers[i]]
        new = repeat(char, layers[i])
        push!(channels, new)
    end

    if width_scale != 1.0
        channels = channels*width_scale

        init_block_channels::Integer = trunc(init_block_channels * width_scale)
    end

    net = ShuffleNet(
        channels,
        init_block_channels,
        groups; 
        in_channels=in_channels, 
        num_classes=num_classes)

    return net
end
