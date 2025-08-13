Mackie ProFX Mixer PipeWire Audio Routing Fix (Ubuntu)

This document outlines a persistent audio routing problem encountered with a Mackie ProFX (e.g., ProFX6v3) USB mixer on Ubuntu (using PipeWire), its diagnosis, and a robust solution implemented via a custom WirePlumber Lua script.
The Problem: No USB Audio to Main Mix

The primary issue was that audio sent from the computer via USB to the Mackie ProFX mixer (specifically to the USB 3/4 return, intended for main mix playback) was not producing any sound through the mixer's main outputs or being indicated on its main meters.

Expected Behavior:
According to the Mackie ProFXv3 manual and common understanding, when a computer's audio output is set to the mixer's USB 3-4, and the corresponding "USB 3-4" button on the mixer's last channel is engaged, the audio should be routed through that channel, affected by its EQ and fader, and ultimately sent to the main mix outputs.

Actual Initial Symptom:
Despite correctly setting the computer's output to the Mackie device and engaging the "USB 3-4" button on the mixer, no audio signal was reaching the main mix, and the main meters remained silent.
Deep Dive & Diagnosis

The debugging process involved systematically ruling out components of the audio stack, from the lowest level (ALSA drivers) to the highest (PipeWire's routing policies).
1. speaker-test Utility: Bypassing the Audio Server

The speaker-test utility (part of alsa-utils) allows direct testing of ALSA playback devices, effectively bypassing higher-level sound servers like PipeWire or PulseAudio. This was crucial for determining if the hardware itself was functioning correctly.

    Initial Attempt:

    speaker-test -D plughw:3,0 -c 4 -s 3

    (Where plughw:3,0 was identified as the Mackie ProFX device from aplay -l).

    Initial Error: Playback open error: -16, Device or resource busy

    Meaning of the Error: This error indicated that the ALSA device (plughw:3,0) was already in exclusive use by another process. On a modern Ubuntu system, this almost certainly meant that PipeWire (the system's default sound server) had claimed exclusive control of the device. This was a good sign, as it meant the kernel recognized the device.

    Resolution & Critical Finding:
    To free up the ALSA device for speaker-test, PipeWire services were temporarily stopped:

    systemctl --user stop pipewire
    systemctl --user stop pipewire.source
    systemctl --user stop pipewire-pulse


    After stopping PipeWire, running speaker-test -D plughw:3,0 -c 4 -s 3 successfully produced a test tone on the mixer's physical left rear channel, and speaker-test -D plughw:3,0 -c 4 -s 4 produced a tone on the physical right rear channel.

    Key Finding: The hardware (Mackie mixer) and its low-level ALSA drivers were functioning perfectly. The audio signal was correctly reaching the mixer's internal bus on channels 3 and 4, and the mixer was outputting it to the main mix. This proved the problem was entirely within the PipeWire audio server's routing or configuration.

    Channel Mapping Note: It was observed that speaker-test -s 2 (expected Front Right) actually produced sound on the physical "Rear Left" channel (USB Channel 3), and speaker-test -s 3 (expected Rear Left) produced sound on the physical "Rear Right" channel (USB Channel 4). This slight discrepancy in speaker-test's internal numbering vs. physical outputs was noted but did not affect the overall diagnosis; the crucial point was that some test tone was heard on the correct physical outputs. For clarity in subsequent steps, we decided to refer to the working channels as "Playback_3" (for physical Rear Left) and "Playback_4" (for physical Rear Right) based on qpwgraph port names in the "pro-audio" profile.

2. qpwgraph Visualizer: Understanding the Graph

qpwgraph is a graphical tool that visualizes the PipeWire audio graph, showing how applications (sources) are connected to output devices (sinks) and vice-versa.

    Initial Observation: When audio applications were playing, qpwgraph showed the Mackie ProFX primarily as an "input" device (sources flowing from ProFX to PulseAudio Volume Control), with no connections flowing from applications (like Spotify) to the ProFX as a playback device.

    Diagnosis: This confirmed that PipeWire was not exposing or recognizing the Mackie mixer as a proper audio output sink for general applications. The system was treating it as a capture-only device, despite its duplex capabilities.

    Temporary Fix (Manual Rerouting):
    After setting the Mackie's profile to "Pro Audio" in pavucontrol (which exposed the Playback_AUX0, Playback_AUX1, Playback_3, Playback_4 ports), it was possible to manually drag and drop connections in qpwgraph from application outputs (Spotify, Firefox) to Playback_3 and Playback_4 on the ProFX sink. This immediately resulted in audio on the main speakers, confirming the correct routing path. However, this manual rerouting was not persistent across application restarts or reboots.

The Solution: Persistent Automated Routing with WirePlumber Script

The root cause was PipeWire's default profile and linking policy for the Mackie ProFX mixer. To make the correct routing persistent for all applications, a custom WirePlumber Lua script was implemented. WirePlumber is the session manager for PipeWire, and it handles device discovery, profile selection, and automatic linking of audio streams.
Why a Custom Script?

    Overriding Defaults: WirePlumber loads configuration files hierarchically. User-specific files (~/.config/wireplumber/...) take precedence over system-wide defaults (/usr/share/wireplumber/...). This allows custom behavior without modifying core system files (which would be overwritten by updates).

    Automating qpwgraph: The script programmatically performs the same connections that were previously done manually in qpwgraph.

    Flexibility: A script allows for conditional logic and customizable parameters, such as controlling whether audio is duplicated to other channels.

The Script (~/.config/wireplumber/main.lua.d/99-profx-routing.lua)

This script monitors for new audio streams and, if the ProFX mixer is the active sink, automatically routes stereo audio to the desired channels (Playback_3 and Playback_4). It also includes a configurable boolean flag to control whether audio is additionally sent to Playback_1 and Playback_2.

-- File: 99-profx-routing.lua
-- Final, robust, and configurable script for automatic ProFX routing.

-- Configuration variables --
-- Set this to 'true' to send a copy of the audio to both the main mix (3/4) and monitor bus (1/2).
-- Set this to 'false' to send audio ONLY to the main mix (3/4).
local send_to_channels_1_and_2 = false -- Set to 'false' for main mix only

-- Define the target channels using variables for easy modification
-- These correspond to the port names seen in qpwgraph for the 'pro-audio' profile
local DEFAULT_PORT_LEFT = "Playback_1"  -- Often used for monitor outputs
local DEFAULT_PORT_RIGHT = "Playback_2" -- Often used for monitor outputs
local TARGET_PORT_LEFT = "Playback_3"   -- Confirmed main speaker left channel
local TARGET_PORT_RIGHT = "Playback_4"  -- Confirmed main speaker right channel

----------------------------


-- Get the core WirePlumber object
local core = wireplumber.core

---
-- Connects a source stream to specified sink ports.
-- Also handles disconnecting default links if 'send_to_channels_1_and_2' is false.
-- @param source The source node (e.g., application output stream).
-- @param sink The sink node (e.g., ProFX mixer).
---
function connect_streams(source, sink)
    if not source or not sink then
        print("WirePlumber: connect_streams received invalid source or sink.")
        return
    end

    -- If we DON'T want to send to channels 1/2, disconnect any existing default links
    if not send_to_channels_1_and_2 then
        local default_link_left = core:find_link(source:get_port(0), sink:get_port_by_name(DEFAULT_PORT_LEFT))
        local default_link_right = core:find_link(source:get_port(1), sink:get_port_by_name(DEFAULT_PORT_RIGHT))
        if default_link_left then
            core:destroy_link(default_link_left)
            print("WirePlumber: Disconnected default left link to Playback_1.")
        end
        if default_link_right then
            core:destroy_link(default_link_right)
            print("WirePlumber: Disconnected default right link to Playback_2.")
        end
    end

    -- Get the main target ports (channels 3 and 4)
    local target_port_left = sink:get_port_by_name(TARGET_PORT_LEFT)
    local target_port_right = sink:get_port_by_name(TARGET_PORT_RIGHT)

    -- If the target ports (Playback_3 and Playback_4) exist, create the links
    if target_port_left and target_port_right then
        core:create_link(source:get_port(0), target_port_left)
        core:create_link(source:get_port(1), target_port_right)
        print("WirePlumber: Successfully linked stream to ProFX main channels (" .. TARGET_PORT_LEFT .. ", " .. TARGET_PORT_RIGHT .. ").")
    else
        print("WirePlumber: ProFX sink found, but target main channels (" .. TARGET_PORT_LEFT .. ", " .. TARGET_PORT_RIGHT .. ") not available. Check active profile.")
    end
    
    -- If the 'send_to_channels_1_and_2' flag is true, also link to channels 1 and 2
    if send_to_channels_1_and_2 then
        local default_port_left = sink:get_port_by_name(DEFAULT_PORT_LEFT)
        local default_port_right = sink:get_port_by_name(DEFAULT_PORT_RIGHT)
        if default_port_left and default_port_right then
            core:create_link(source:get_port(0), default_port_left)
            core:create_link(source:get_port(1), default_port_right)
            print("WirePlumber: Also linked stream to ProFX monitor channels (" .. DEFAULT_PORT_LEFT .. ", " .. DEFAULT_PORT_RIGHT .. ").")
        else
             print("WirePlumber: Could not link to monitor channels (" .. DEFAULT_PORT_LEFT .. ", " .. DEFAULT_PORT_RIGHT .. "). Ports not found.")
        end
    end

    print("WirePlumber: Routing process completed for new stream.")
end

---
-- Monitors for the PipeWire core state to be running, then hooks into new stream events.
---
core.on_core_state_changed = function(state)
    if state == "running" then
        -- Find the ProFX sink node once the core is running
        -- Check if the device is connected by its node name (which should be "ProFX" in the 'pro-audio' profile)
        local profx_sink = core.get_objects({"node", "name", "ProFX"})[1]

        -- If the ProFX sink is found, monitor for new streams
        if profx_sink then
            print("WirePlumber: ProFX sink found. Monitoring for new audio streams.")
            -- This hook connects to every new stream that appears in the graph
            wireplumber.hook.connect("new-stream", function(stream)
                -- Re-fetch the sink in case its properties changed or it was re-added
                profx_sink = core.get_objects({"node", "name", "ProFX"})[1]

                -- Only connect if the new stream's output is not already linked
                -- and it's a stereo (2-channel) stream
                if profx_sink and not stream:get_is_linked() and stream:get_n_channels() == 2 then
                    print("WirePlumber: New stereo stream detected: " .. stream:get_name())
                    connect_streams(stream, profx_sink)
                end
            end)
        else
            print("WirePlumber: ProFX sink not found. Automatic routing will not occur.")
        end
    end
end

How to Implement and Activate

    Create the directory:

    mkdir -p ~/.config/wireplumber/main.lua.d/

    Create the script file:

    nano ~/.config/wireplumber/main.lua.d/99-profx-routing.lua

    (Paste the script code into this file).

    Adjust the send_to_channels_1_and_2 flag: In the script, set local send_to_channels_1_and_2 = false to your desired routing behavior.

    Restart WirePlumber:

    systemctl --user restart wireplumber

    After restarting, open your audio applications. The routing should now be automatic and consistent. You can verify this using qpwgraph to observe the links.

Side Explorations & Key Learnings

The debugging journey provided valuable insights into the Linux audio architecture:

    ALSA (Advanced Linux Sound Architecture): This is the lowest-level audio API in the Linux kernel. It provides direct access to sound card hardware. The speaker-test utility interacts directly with ALSA. The "Device or resource busy" error highlights that ALSA devices typically allow only one application to access them exclusively at a time without a software mixer.

    PipeWire (and PulseAudio): These are "sound servers" or "audio routing daemons" that sit on top of ALSA. Their primary functions are:

        Multiplexing: Allowing multiple applications to play sound simultaneously through a single ALSA device.

        Routing: Managing connections between applications (sources) and output devices (sinks).

        Device Profiling: Presenting different "profiles" (e.g., Stereo, Surround, Pro Audio) that expose different channel configurations of a single hardware device.

        Dynamic Management: Handling hot-plugging of devices, volume control, and stream redirection.

        PipeWire is the modern successor to PulseAudio, designed to handle professional audio (like JACK) and video streams as well.

    WirePlumber: This is the session manager for PipeWire. While PipeWire handles the audio processing graph itself, WirePlumber is responsible for policy decisions:

        Which devices to load.

        Which profiles to activate by default.

        How to automatically link application streams to devices.

        Its configuration is often done via Lua scripts, allowing for highly customized and intelligent routing behavior.

    Configuration Hierarchy: Linux audio configuration follows a strict hierarchy:

        /usr/share/pipewire/ & /usr/share/wireplumber/: System-wide default configurations (should not be edited).

        /etc/pipewire/ & /etc/wireplumber/: System-wide overrides (for administrators).

        ~/.config/pipewire/ & ~/.config/wireplumber/: User-specific overrides (the safest place for custom configurations, as they are persistent across updates).

    Key Debugging Tools:

        aplay -l: Lists all available ALSA playback devices and their card/device IDs.

        pactl list cards: Provides detailed information about PipeWire's understanding of your audio cards, including available profiles and their names.

        pactl set-card-profile [card_id] [profile_name]: Command-line tool to manually change a device's active PipeWire profile.

        speaker-test: Low-level ALSA utility to send test tones directly to device channels, invaluable for hardware verification.

        qpwgraph: A graphical "patchbay" that visualizes the PipeWire graph in real-time. Essential for understanding how streams are connected and for manual routing. It helped pinpoint the exact Playback_X port names for the Mackie mixer in pro-audio mode.

        systemctl --user restart wireplumber: Command to restart the WirePlumber session manager, necessary after making changes to its configuration scripts.

This deep dive into the Linux audio stack, driven by a seemingly simple problem, provided a comprehensive understanding of how these components interact and how to effectively customize them for specific hardware needs.