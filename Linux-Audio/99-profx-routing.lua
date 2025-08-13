-- File: 99-profx-routing.lua
-- Generated with help of 
-- Final, robust, and configurable script for automatic ProFX routing.

-- Configuration variables --
-- Set this to 'true' to send a copy of the audio to both the main mix (3/4) and monitor bus (1/2).
-- Set this to 'false' to send audio ONLY to the main mix (3/4).
local send_to_channels_1_and_2 = true

-- Define the target channels using variables for easy modification
local DEFAULT_PORT_LEFT = "Playback_1"
local DEFAULT_PORT_RIGHT = "Playback_2"
local TARGET_PORT_LEFT = "Playback_3"
local TARGET_PORT_RIGHT = "Playback_4"

----------------------------


-- Get the core WirePlumber object
local core = wireplumber.core

function connect_streams(source, sink)
    if not source or not sink then
        return
    end

    -- Disconnect any existing default links to channels 1 and 2 if the flag is false
    if not send_to_channels_1_and_2 then
        local default_link_left = core:find_link(source:get_port(0), sink:get_port_by_name(DEFAULT_PORT_LEFT))
        local default_link_right = core:find_link(source:get_port(1), sink:get_port_by_name(DEFAULT_PORT_RIGHT))
        if default_link_left then
            core:destroy_link(default_link_left)
        end
        if default_link_right then
            core:destroy_link(default_link_right)
        end
    end

    -- Get the target ports.
    local target_port_left = sink:get_port_by_name(TARGET_PORT_LEFT)
    local target_port_right = sink:get_port_by_name(TARGET_PORT_RIGHT)

    -- If the target ports exist, create the links
    if target_port_left and target_port_right then
        core:create_link(source:get_port(0), target_port_left)
        core:create_link(source:get_port(1), target_port_right)
    end
    
    -- If the flag is true, also link to channels 1 and 2
    if send_to_channels_1_and_2 then
        local default_port_left = sink:get_port_by_name(DEFAULT_PORT_LEFT)
        local default_port_right = sink:get_port_by_name(DEFAULT_PORT_RIGHT)
        if default_port_left and default_port_right then
            core:create_link(source:get_port(0), default_port_left)
            core:create_link(source:get_port(1), default_port_right)
        end
    end

    print("WirePlumber: Routing completed for new stream.")
end

core.on_core_state_changed = function(state)
    if state == "running" then
        local profx_sink = core.get_objects({"node", "name", "ProFX"})[1]

        if profx_sink then
            wireplumber.hook.connect("new-stream", function(stream)
                profx_sink = core.get_objects({"node", "name", "ProFX"})[1]

                if not stream:get_is_linked() and stream:get_n_channels() == 2 then
                    connect_streams(stream, profx_sink)
                end
            end)
        end
    end
end