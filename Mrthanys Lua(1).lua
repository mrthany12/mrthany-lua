--[[
    Mrthanys Lua
    Lua-primary adaptive resolver

    Behavior:
      * Disables the built-in resolver while enabled.
      * Learns per-player yaw-angle clusters.
      * Uses hit outcomes to favor successful candidates.
      * Cycles candidates after resolver misses.
      * Supports STATIC, JITTER, 3-WAY, 4-WAY, 5-WAY, and RANDOM states.
      * Restores built-in resolver and per-player overrides on disable/unload.
]]

local tab = menu.new_tab("Mrthanys Lua", "rbxassetid://10734975692")
local resolver_sec = tab:new_section("Adaptive Resolver", "Left")
local display_sec = tab:new_section("Diagnostics", "Right")

local enabled = resolver_sec:new_toggle("Enable resolver", true)
local history_size = resolver_sec:new_slider("History samples", 16, 64, 40, 0, " ticks")
local tolerance = resolver_sec:new_slider("Cluster tolerance", 4, 20, 10, 0, "°")
local miss_cycle_delay = resolver_sec:new_slider("Miss cycle delay", 0, 250, 80, 0, " ms")
local random_candidate_limit = resolver_sec:new_slider("Random candidates", 2, 10, 6, 0, "")

local aa_sec = tab:new_section("Anti-Aim", "Left")
local enable_7way = aa_sec:new_toggle("Enable 7-Way AA", false)
local seven_way_speed = aa_sec:new_slider("7-Way speed", 1, 12, 2, 0, " ticks")
local enable_head_sway = aa_sec:new_toggle("Enable head sway", false)
local head_sway_speed = aa_sec:new_slider("Head sway speed", 1, 12, 2, 0, " ticks")
local head_sway_angle = aa_sec:new_slider("Head sway angle", 10, 70, 40, 0, "°")
local fake_flick_enabled = aa_sec:new_toggle("Enable fake flick", false)
local fake_flick_method = aa_sec:new_combobox(
    "Fake flick method",
    { "Yaw Offset", "Fake Desync", "Limits" },
    "Yaw Offset"
)
local fake_flick_speed = aa_sec:new_slider("Fake flick speed", 2, 64, 8, 0, "t")
local fake_flick_ticks = aa_sec:new_slider("Flick ticks", 1, 8, 2, 0, "t")
local fake_flick_angle = aa_sec:new_slider("Flick angle", 0, 180, 180, 0, "°")
local fake_flick_velocity_check = aa_sec:new_toggle("Velocity check", true)
local fake_flick_max_velocity = aa_sec:new_slider("Max velocity", 0, 320, 90, 0, "")
local fake_flick_only_choked = aa_sec:new_toggle("Only while choking", true)
local fake_flick_unchoke = aa_sec:new_toggle("Unchoke on flick", true)
local fake_flick_manage_base = aa_sec:new_toggle("Manage base AA", true)
local show_indicator = display_sec:new_toggle("Show resolver indicator", true)
local show_stats = display_sec:new_toggle("Show hit / miss stats", true)

local autostop_sec = tab:new_section("Auto Stop", "Right")
local autostop_enabled = autostop_sec:new_toggle("Enable auto stop", false)
local autostop_mode = autostop_sec:new_combobox(
    "Stop mode",
    { "None", "FullStop", "SlowdownOnly", "OppositeDirection" },
    "FullStop"
)
local autostop_strength = autostop_sec:new_slider("Brake strength", 10, 160, 55, 0, " studs/s²")
local autostop_delay = autostop_sec:new_slider("Pre-stop delay", 0, 300, 40, 0, " ms")
local autostop_release_delay = autostop_sec:new_slider("Release delay", 0, 300, 100, 0, " ms")
local autostop_min_speed = autostop_sec:new_slider("Minimum speed", 0, 10, 1, 1, " studs/s")
local autostop_horizontal_only = autostop_sec:new_toggle("Horizontal only", true)

local states_by_player = {}
local next_update_phase = 0
local shots_by_id = {}
local shots_by_target = {}
local MAX_SHOT_HISTORY = 32
local shot_history = {}

local native_resolver_initial = rage.is_resolver_enabled()

local function sync_native_resolver()
    local desired = native_resolver_initial
    if enabled:get() then
        desired = false
    end

    if rage.is_resolver_enabled() ~= desired then
        rage.set_resolver_enabled(desired)
    end
end

local function normalize_angle(angle)
    return ((angle + 180) % 360) - 180
end

local function angle_delta(a, b)
    return normalize_angle(a - b)
end

local function get_state(player)
    if player == nil then
        return nil
    end

    local state = states_by_player[player]
    if not state then
        state = {
            player = player,
            samples = {},
            candidates = {},
            candidate_hits = {},
            candidate_misses = {},
            pattern = "LEARNING",
            choice = 1,
            misses = 0,
            hits = 0,
            applied = nil,
            applied_choice = nil,
            sample_count = 0,
            update_phase = next_update_phase,
            last_miss_time = -math.huge,
            owns_override = false,
            previous_force = nil,
            previous_offset = nil,
            sample_source = "unavailable",
            last_sample = nil,
        }

        next_update_phase = (next_update_phase + 1) % 2
        states_by_player[player] = state
    end

    return state
end

local function find_state_for_event(target_ref)
    if target_ref == nil then
        return nil
    end

    local state = states_by_player[target_ref]
    if state then
        return state
    end

    local active = rage.get_target()
    if active and active.player and active.slot == target_ref then
        return states_by_player[active.player]
    end

    return nil
end

local function get_sample(enemy)
    local anim = entity.get_anim_state(enemy)
    if anim
        and anim.goal_feet_yaw ~= nil
        and anim.eye_angles_y ~= nil
    then
        return angle_delta(
            anim.goal_feet_yaw,
            anim.eye_angles_y
        ), "animstate"
    end

    local info = entity.get_info(enemy)
    if info
        and info.lby ~= nil
        and info.yaw ~= nil
    then
        return angle_delta(info.lby, info.yaw), "snapshot"
    end

    return nil, "unavailable"
end

local function add_sample(state, sample)
    local cap = math.max(1, math.floor(history_size:get()))

    table.insert(state.samples, sample)

    while #state.samples > cap do
        table.remove(state.samples, 1)
    end

    state.sample_count = #state.samples
end

local function build_candidates(samples, max_delta)
    local groups = {}

    for _, sample in ipairs(samples) do
        local match = nil

        for _, group in ipairs(groups) do
            if math.abs(angle_delta(sample, group.center)) <= max_delta then
                match = group
                break
            end
        end

        if match then
            match.count += 1
            match.center = normalize_angle(
                match.center
                + angle_delta(sample, match.center) / match.count
            )
        else
            table.insert(groups, {
                center = normalize_angle(sample),
                count = 1,
            })
        end
    end

    table.sort(groups, function(a, b)
        if a.count == b.count then
            return math.abs(a.center) < math.abs(b.center)
        end
        return a.count > b.count
    end)

    local candidates = {}
    local minimum_count = math.max(
        2,
        math.floor(#samples * 0.04)
    )

    for _, group in ipairs(groups) do
        if group.count >= minimum_count then
            table.insert(candidates, normalize_angle(group.center))
        end
    end

    if #candidates == 0 and #groups > 0 then
        table.insert(candidates, normalize_angle(groups[1].center))
    end

    return candidates
end

local function classify(candidate_count, sample_count)
    if sample_count < 10 or candidate_count == 0 then
        return "LEARNING"
    elseif candidate_count == 1 then
        return "STATIC"
    elseif candidate_count == 2 then
        return "JITTER"
    elseif candidate_count == 3 then
        return "3-WAY"
    elseif candidate_count == 4 then
        return "4-WAY"
    elseif candidate_count == 5 then
        return "5-WAY"
    else
        return "RANDOM"
    end
end

local function clear_player_override(player, state)
    if player == nil
        or state == nil
        or not state.owns_override
    then
        return
    end

    if state.previous_force ~= nil then
        plist.set(player, "Force body yaw", state.previous_force)
    else
        plist.set(player, "Force body yaw", false)
    end

    if state.previous_offset ~= nil then
        plist.set(player, "Override yaw offset", state.previous_offset)
    else
        plist.set(player, "Override yaw offset", 0)
    end

    state.owns_override = false
    state.applied = nil
    state.applied_choice = nil
    state.previous_force = nil
    state.previous_offset = nil
end

local function reset_all_tracked()
    for player, state in pairs(states_by_player) do
        clear_player_override(player, state)
    end
end

local function remember_shot(e)
    if e == nil then
        return nil
    end

    local state = find_state_for_event(e.target)
    local shot = {
        id = e.id,
        target = e.target,
        hitbox = e.hitbox,
        damage = e.damage,
        hitchance = e.hitchance,
        resolved_yaw = e.resolved_yaw,
        point = e.point,
        fired_at = globals.realtime(),
        state_choice = state and state.choice or nil,
        state_angle = state and state.applied or nil,
    }

    if e.id ~= nil and e.id ~= 0 then
        shots_by_id[e.id] = shot
    end

    if e.target ~= nil then
        shots_by_target[e.target] = shot
    end

    table.insert(shot_history, shot)
    while #shot_history > MAX_SHOT_HISTORY do
        table.remove(shot_history, 1)
    end

    return shot
end

local function get_shot_for_event(e)
    if e == nil then
        return nil
    end

    local shot = nil

    if e.id ~= nil and e.id ~= 0 then
        shot = shots_by_id[e.id]
    end

    if shot == nil and e.target ~= nil then
        shot = shots_by_target[e.target]
    end

    if shot ~= nil then
        local age = globals.realtime() - (shot.fired_at or 0)
        if age > 2 then
            return nil
        end
    end

    return shot
end

local function score_candidate(state, choice, was_hit)
    if state == nil or choice == nil then
        return
    end

    if was_hit then
        state.candidate_hits[choice] =
            (state.candidate_hits[choice] or 0) + 1
    else
        state.candidate_misses[choice] =
            (state.candidate_misses[choice] or 0) + 1
    end
end

local function select_learned_candidate(state)
    if #state.candidates == 0 then
        return nil
    end

    local best_choice = state.choice
    if best_choice < 1 or best_choice > #state.candidates then
        best_choice = 1
    end

    local best_score = -math.huge
    local best_hits = -1
    local best_misses = math.huge

    for choice = 1, #state.candidates do
        local hits = state.candidate_hits[choice] or 0
        local misses = state.candidate_misses[choice] or 0
        local score = hits * 3 - misses

        if score > best_score
            or (score == best_score and hits > best_hits)
            or (
                score == best_score
                and hits == best_hits
                and misses < best_misses
            )
        then
            best_choice = choice
            best_score = score
            best_hits = hits
            best_misses = misses
        end
    end

    return best_choice
end

client.set_event_callback("aim_fire", function(e)
    remember_shot(e)
end)

events.on_tick(function(tick)
    sync_native_resolver()

    if not enabled:get() then
        reset_all_tracked()
        return
    end

    local active_players = {}
    local enemies = entity.get_enemies()

    for _, enemy in ipairs(enemies) do
        if entity.is_alive(enemy) then
            active_players[enemy] = true
            local state = get_state(enemy)

            local sample, sample_source = get_sample(enemy)
            state.sample_source = sample_source
            state.last_sample = sample

            if sample ~= nil then
                add_sample(state, sample)

                local is_update_phase = (tick % 2) == state.update_phase
                if state.sample_count < 10 or is_update_phase then
                    state.candidates = build_candidates(
                        state.samples,
                        tolerance:get()
                    )

                    state.pattern = classify(
                        #state.candidates,
                        state.sample_count
                    )

                    if #state.candidates > random_candidate_limit:get()
                        and state.pattern == "RANDOM"
                    then
                        local trimmed = {}
                        for i = 1, random_candidate_limit:get() do
                            table.insert(trimmed, state.candidates[i])
                        end
                        state.candidates = trimmed
                    end

                    if state.choice > #state.candidates then
                        state.choice = 1
                    end
                end
            end

            if #state.candidates > 0 then
                local best_choice = select_learned_candidate(state)
                if best_choice then
                    state.choice = best_choice
                end

                local offset = state.candidates[state.choice]
                    or state.candidates[1]

                if not state.owns_override then
                    state.previous_force = plist.get(enemy, "Force body yaw")
                    state.previous_offset = plist.get(enemy, "Override yaw offset")
                    state.owns_override = true
                end

                state.applied = offset
                state.applied_choice = state.choice

                plist.set(enemy, "Force body yaw", true)
                plist.set(enemy, "Override yaw offset", offset)
            else
                clear_player_override(enemy, state)
            end
        end
    end

    for player, state in pairs(states_by_player) do
        if not active_players[player] then
            clear_player_override(player, state)
            states_by_player[player] = nil
        end
    end
end)

-- Custom Anti-Aim: seven yaw positions plus a four-direction head sway.
-- Pitch: negative = down, positive = up. Yaw: positive/right, negative/left.
local seven_way_offsets = { -90, -60, -30, 0, 30, 60, 90 }
local head_sway_pitches = { -35, 0, 0, 35 }
local aa_was_active = false
local fake_flick_was_enabled = false
local fake_flick_base_inverter = false

local function fake_flick_clamp(value, minimum, maximum)
    value = tonumber(value)
    if value == nil then
        return minimum
    end
    return math.max(minimum, math.min(maximum, value))
end

local function fake_flick_call_aa(name, ...)
    if aa and type(aa[name]) == "function" then
        return pcall(aa[name], ...)
    end
    return false
end

-- Velocity is read from the documented entity API. The character velocity
-- fallback keeps the feature working if the entity wrapper is unavailable.
local function fake_flick_get_velocity()
    if entity and type(entity.get_local_player) == "function"
        and type(entity.get_player_velocity) == "function"
    then
        local ok_player, local_player = pcall(entity.get_local_player)
        if ok_player and local_player then
            local ok_velocity, velocity = pcall(entity.get_player_velocity, local_player)
            if ok_velocity and velocity
                and type(velocity.X) == "number"
                and type(velocity.Z) == "number"
            then
                return math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z),
                    velocity.X,
                    velocity.Z
            end
        end
    end

    local ok, speed, vx, vz = pcall(function()
        local local_player = game:GetService("Players").LocalPlayer
        local character = local_player and local_player.Character
        local root = character and (
            character:FindFirstChild("HumanoidRootPart")
            or character:FindFirstChild("Collide")
            or character.PrimaryPart
        )
        if root and root:IsA("BasePart") then
            local velocity = root.AssemblyLinearVelocity
            return math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z),
                velocity.X,
                velocity.Z
        end
        return 0, 0, 0
    end)

    return ok and speed or 0, ok and vx or 0, ok and vz or 0
end

local function fake_flick_is_choking()
    if aa and type(aa.is_fake_lag_choking) == "function" then
        local ok, choking = pcall(aa.is_fake_lag_choking)
        if ok then
            return choking
        end
    end
    return true
end

local function fake_flick_apply_desync(degrees, method)
    if method == "Fake Desync" then
        local fake_angle = fake_flick_clamp(degrees, -86, 86)
        local ok = fake_flick_call_aa("override_desync", 0, fake_angle)

        if not ok then
            if fake_angle >= 0 then
                fake_flick_call_aa("override_inverter", true)
                fake_flick_call_aa("override_desync_limits", 0, math.abs(fake_angle))
            else
                fake_flick_call_aa("override_inverter", false)
                fake_flick_call_aa("override_desync_limits", math.abs(fake_angle), 0)
            end
        end
    elseif method == "Limits" then
        local magnitude = fake_flick_clamp(math.abs(degrees), 0, 86)
        if degrees >= 0 then
            fake_flick_call_aa("override_inverter", true)
            fake_flick_call_aa("override_desync_limits", 0, magnitude)
        else
            fake_flick_call_aa("override_inverter", false)
            fake_flick_call_aa("override_desync_limits", magnitude, 0)
        end
    end
end

events.on_tick(function(tick)
    tick = math.floor(tonumber(tick) or 0)

    local seven_way_on = enable_7way:get()
    local head_sway_on = enable_head_sway:get()
    local fake_flick_on = fake_flick_enabled:get()

    if fake_flick_on and not fake_flick_was_enabled then
        local inverter = false
        if aa and type(aa.get_inverter) == "function" then
            local ok, value = pcall(aa.get_inverter)
            if ok then
                inverter = value
            end
        end
        fake_flick_base_inverter = inverter
        fake_flick_was_enabled = true
    elseif not fake_flick_on and fake_flick_was_enabled then
        -- Drop Fake Flick's temporary desync/fakelag overrides before the
        -- other AA modes are reapplied below.
        fake_flick_call_aa("reset")
        fake_flick_was_enabled = false
    end

    if not seven_way_on and not head_sway_on and not fake_flick_on then
        if aa_was_active then
            aa.reset()
            aa_was_active = false
        end
        return
    end

    aa_was_active = true

    local manage_base = fake_flick_on and fake_flick_manage_base:get()
    if manage_base then
        fake_flick_call_aa("override_pitch", "Down")
        fake_flick_call_aa("override_body_yaw", true)
        fake_flick_call_aa("override_desync_limits", 86, 86)
        fake_flick_call_aa("override_fake_lag", true)
        fake_flick_call_aa("override_fake_lag_limit", 14)
    elseif fake_flick_on and fake_flick_method:get() ~= "Yaw Offset" then
        fake_flick_call_aa("override_body_yaw", true)
    end

    -- Preserve the existing script's backward base yaw for 7-Way and
    -- Head Sway; Manage Base AA also enables it for Fake Flick by itself.
    if manage_base or seven_way_on or head_sway_on then
        fake_flick_call_aa("override_yaw", 180, "camera")
    end

    local yaw_offset = 0
    local pitch_value = manage_base and "Down" or nil

    if seven_way_on then
        local speed = math.max(1, math.floor(seven_way_speed:get()))
        local index = (math.floor(tick / speed) % #seven_way_offsets) + 1
        yaw_offset += seven_way_offsets[index]
    end

    if head_sway_on then
        local speed = math.max(1, math.floor(head_sway_speed:get()))
        local index = (math.floor(tick / speed) % 4) + 1
        local angle = head_sway_angle:get()

        -- Down -> right -> left -> up, repeating at the selected jitter speed.
        pitch_value = head_sway_pitches[index]

        if index == 2 then
            yaw_offset += angle
        elseif index == 3 then
            yaw_offset -= angle
        end
    end

    local flick_degrees = 0
    local flick_active = false
    local flick_method = fake_flick_method:get() or "Yaw Offset"

    if fake_flick_on then
        local velocity, velocity_x = fake_flick_get_velocity()
        local max_velocity = fake_flick_clamp(fake_flick_max_velocity:get(), 0, 320)
        local velocity_allowed = not fake_flick_velocity_check:get()
            or velocity <= max_velocity
        local choke_allowed = not fake_flick_only_choked:get()
            or fake_flick_is_choking()

        local speed = fake_flick_clamp(math.floor(fake_flick_speed:get()), 2, 64)
        local width = fake_flick_clamp(math.floor(fake_flick_ticks:get()), 1, speed)
        local cycle = tick % speed

        flick_active = velocity_allowed and choke_allowed and cycle < width

        -- Start from the inverter state captured when Fake Flick was enabled,
        -- then invert it while moving left (negative world-X velocity).
        local side = fake_flick_base_inverter and -1 or 1
        if velocity > 10 and velocity_x < -10 then
            side = -side
        end

        if flick_active then
            flick_degrees = fake_flick_angle:get() * side

            if fake_flick_unchoke:get() and cycle == 0 then
                fake_flick_call_aa("unchoke")
            end
        end

        -- Restore symmetrical base limits before applying a method-specific
        -- pulse. This prevents the Limits method from feeding its own inverter
        -- back into the next pulse's starting side.
        fake_flick_call_aa("override_inverter", fake_flick_base_inverter)
        fake_flick_call_aa("override_desync_limits", 86, 86)
    end

    if fake_flick_on and flick_method == "Yaw Offset" then
        yaw_offset += flick_degrees
    elseif fake_flick_on then
        if flick_active then
            fake_flick_apply_desync(flick_degrees, flick_method)
        else
            fake_flick_call_aa("override_desync", 0, 0)
            fake_flick_call_aa("override_inverter", fake_flick_base_inverter)
            fake_flick_call_aa("override_desync_limits", 86, 86)
        end
    end

    -- Write each composed angle once so Fake Flick doesn't fight 7-Way or
    -- Head Sway, and the normal composed angle is restored outside the pulse.
    fake_flick_call_aa("override_pitch", pitch_value)
    fake_flick_call_aa("override_yaw_offset", yaw_offset)
end)

-- Auto Stop: uses the active rage scan target as a pre-shot trigger.
-- A capped VectorForce brakes existing momentum smoothly without rewriting
-- the player's movement input or reacting to aim_fire after the shot.
local autostop_attachment = nil
local autostop_force = nil
local autostop_root = nil
local autostop_first_target_time = nil
local autostop_last_target_time = nil
local autostop_previous_velocity = nil
local autostop_previous_sample_time = nil
local autostop_knockback_until = 0
local autostop_error_logged = false

local function autostop_zero_force()
    if autostop_force then
        pcall(function()
            autostop_force.Force = Vector3.new(0, 0, 0)
        end)
    end
end

local function autostop_destroy_force()
    autostop_zero_force()

    if autostop_force then
        pcall(function() autostop_force:Destroy() end)
    end
    if autostop_attachment then
        pcall(function() autostop_attachment:Destroy() end)
    end

    autostop_force = nil
    autostop_attachment = nil
    autostop_root = nil
end

local function autostop_ensure_force(root)
    if autostop_root == root and autostop_force and autostop_attachment then
        return true
    end

    autostop_destroy_force()

    local ok, attachment, force = pcall(function()
        local new_attachment = Instance.new("Attachment")
        new_attachment.Name = "MrthanysAutoStopAttachment"
        new_attachment.Parent = root

        local new_force = Instance.new("VectorForce")
        new_force.Name = "MrthanysAutoStopForce"
        new_force.Attachment0 = new_attachment
        new_force.RelativeTo = Enum.ActuatorRelativeTo.World
        new_force.ApplyAtCenterOfMass = true
        new_force.Force = Vector3.new(0, 0, 0)
        new_force.Parent = root

        return new_attachment, new_force
    end)

    if not ok then
        return false
    end

    autostop_root = root
    autostop_attachment = attachment
    autostop_force = force
    return true
end

local function autostop_has_scanned_target()
    local target = rage.get_target()
    return target ~= nil
        and target.player ~= nil
        and entity.is_alive(target.player)
end

local function autostop_is_unsafe(humanoid, local_player, now)
    if humanoid.Sit or humanoid.PlatformStand or humanoid.SeatPart ~= nil then
        return true
    end

    local state = humanoid:GetState()
    local states = Enum.HumanoidStateType

    if state == states.Climbing
        or state == states.Swimming
        or state == states.Seated
        or state == states.Physics
        or state == states.PlatformStanding
        or state == states.FallingDown
        or state == states.Ragdoll
        or state == states.Dead
        or state == states.Jumping
        or state == states.Freefall
    then
        return true
    end

    -- Best-effort game-specific noclip flags; the public API has no universal
    -- noclip/knockback state query.
    local character = local_player.Character
    if character and (
        character:GetAttribute("Noclip") == true
        or humanoid:GetAttribute("Noclip") == true
    ) then
        return true
    end

    return not movement.is_grounded(local_player)
        or now < autostop_knockback_until
end

local function autostop_update()
    local now = globals.realtime()
    local mode = autostop_mode:get()

    if not autostop_enabled:get() or mode == "None" then
        autostop_zero_force()
        autostop_first_target_time = nil
        autostop_last_target_time = nil
        autostop_previous_velocity = nil
        autostop_previous_sample_time = nil
        autostop_knockback_until = 0
        return
    end

    -- Sample movement continuously while enabled, including during the
    -- pre-stop delay, so sudden external impulses can be detected.
    local local_player = entity.get_local_player()
    local character = local_player and local_player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not local_player or not humanoid or not root then
        autostop_zero_force()
        autostop_previous_velocity = nil
        autostop_previous_sample_time = nil
        return
    end

    local velocity = root.AssemblyLinearVelocity
    local sample_dt = globals.tickinterval()
    if autostop_previous_velocity ~= nil and autostop_previous_sample_time ~= nil then
        sample_dt = math.max(math.min(now - autostop_previous_sample_time, 0.05), 1 / 240)
        local acceleration = (velocity - autostop_previous_velocity).Magnitude / sample_dt
        if acceleration > 240 then
            autostop_knockback_until = now + 0.25
        end
    end
    autostop_previous_velocity = velocity
    autostop_previous_sample_time = now

    if autostop_is_unsafe(humanoid, local_player, now) then
        autostop_zero_force()
        return
    end

    -- rage.get_target() is the active scan result, so braking begins before
    -- aim_fire. No post-shot callback is used as the trigger.
    local target_found = autostop_has_scanned_target()
    local delay_seconds = autostop_delay:get() / 1000
    local release_seconds = autostop_release_delay:get() / 1000

    if target_found then
        if autostop_first_target_time == nil then
            autostop_first_target_time = now
        end
        autostop_last_target_time = now
    end

    local target_recent = target_found
        or (
            autostop_last_target_time ~= nil
            and now - autostop_last_target_time <= release_seconds
        )

    if not target_recent then
        autostop_zero_force()
        autostop_first_target_time = nil
        autostop_last_target_time = nil
        return
    end

    if autostop_first_target_time == nil
        or now - autostop_first_target_time < delay_seconds
    then
        autostop_zero_force()
        return
    end

    if now < autostop_knockback_until then
        autostop_zero_force()
        return
    end

    local brake_velocity
    if autostop_horizontal_only:get() then
        brake_velocity = Vector3.new(velocity.X, 0, velocity.Z)
    else
        brake_velocity = velocity
    end

    local speed = brake_velocity.Magnitude
    local min_speed = autostop_min_speed:get()
    if speed <= min_speed then
        autostop_zero_force()
        return
    end

    local direction = brake_velocity.Unit
    local mode_scale = 1

    if mode == "SlowdownOnly" then
        mode_scale = 0.4
    elseif mode == "OppositeDirection" then
        -- Counter only the component of velocity aligned with the player's
        -- current movement input. Perpendicular strafing is left untouched.
        local move_direction = humanoid.MoveDirection
        local input_dir = Vector3.new(move_direction.X, 0, move_direction.Z)
        if input_dir.Magnitude < 0.05 then
            autostop_zero_force()
            return
        end

        input_dir = input_dir.Unit
        local aligned_speed = brake_velocity:Dot(input_dir)
        if aligned_speed <= min_speed then
            autostop_zero_force()
            return
        end

        brake_velocity = input_dir * aligned_speed
        speed = math.abs(aligned_speed)
        direction = brake_velocity.Unit
    elseif mode ~= "FullStop" then
        autostop_zero_force()
        return
    end

    local engage_ramp = math.min(1, (now - (autostop_first_target_time + delay_seconds)) / 0.12)
    local release_fade = 1
    if not target_found and release_seconds > 0 then
        release_fade = math.max(0, 1 - (now - autostop_last_target_time) / release_seconds)
    end

    local deceleration = autostop_strength:get() * mode_scale * engage_ramp * release_fade
    local safe_dt = math.max(math.min(sample_dt, 0.05), 1 / 240)
    deceleration = math.min(deceleration, (speed / safe_dt) * 0.8)

    local mass = root.AssemblyMass
    if mass == nil or mass <= 0 then
        autostop_zero_force()
        return
    end

    if not autostop_ensure_force(root) then
        autostop_zero_force()
        return
    end

    local force_vector = direction * (-deceleration * mass)
    if autostop_horizontal_only:get() then
        force_vector = Vector3.new(force_vector.X, 0, force_vector.Z)
    end

    autostop_force.Force = force_vector
end

events.on_tick(function()
    local ok, err = pcall(autostop_update)
    if not ok then
        autostop_zero_force()
        if not autostop_error_logged then
            autostop_error_logged = true
            client.log("[Mrthanys Lua][AutoStop] " .. tostring(err))
        end
    end
end)

local MISS_REASON_TEXT = {
    resolver = "likely angle / resolver mismatch",
    spread = "spread or inaccuracy",
    occlusion = "blocked / occluded target",
    death = "target died before hit confirmation",
}

local function debug_value(value)
    if value == nil then
        return "n/a"
    end
    return tostring(value)
end

local function get_shot_field(e, shot, field)
    if shot and shot[field] ~= nil then
        return shot[field]
    end
    if e and e[field] ~= nil then
        return e[field]
    end
    return nil
end

client.set_event_callback("aim_miss", function(e)
    if not e then
        return
    end

    local state = find_state_for_event(e.target)
    local shot = get_shot_for_event(e)
    local reason = tostring(e.reason or "unknown")
    local explanation = MISS_REASON_TEXT[reason]
        or "unrecognized game-provided reason"

    local shot_id = get_shot_field(e, shot, "id")
    local hitbox = get_shot_field(e, shot, "hitbox")
    local damage = get_shot_field(e, shot, "damage")
    local hitchance = get_shot_field(e, shot, "hitchance")
    local resolved_yaw = get_shot_field(e, shot, "resolved_yaw")

    local old_choice = shot and shot.state_choice
        or (state and state.choice)
        or nil

    local old_angle = shot and shot.state_angle
        or (state and state.applied)
        or nil

    local next_choice = old_choice
    local next_angle = old_angle
    local now = globals.realtime()
    local cycle_delay = miss_cycle_delay:get() / 1000

    if state and reason == "resolver" then
        state.misses += 1
        score_candidate(state, old_choice, false)

        local can_cycle = (
            now - (state.last_miss_time or -math.huge)
        ) >= cycle_delay

        if can_cycle and #state.candidates > 1 then
            state.choice = (state.choice % #state.candidates) + 1
            state.applied = state.candidates[state.choice]
            state.applied_choice = state.choice
            state.last_miss_time = now
        end

        next_choice = state.choice
        next_angle = state.candidates[next_choice] or state.applied
    end

    client.log(string.format(
        "[Mrthanys Lua][MISS]"
        .. " reason=%s (%s)"
        .. " | hitbox=%s"
        .. " | shot_id=%s"
        .. " | damage=%s"
        .. " | hitchance=%s"
        .. " | shot_yaw=%s"
        .. " | pattern=%s"
        .. " | samples=%s"
        .. " | candidates=%s"
        .. " | candidate_angles=%s"
        .. " | sample_source=%s"
        .. " | last_sample=%s"
        .. " | old_choice=%s"
        .. " | old_angle=%s"
        .. " | next_choice=%s"
        .. " | next_angle=%s"
        .. " | miss_count=%s"
        .. " | shot_source=%s",

        reason,
        explanation,
        debug_value(hitbox),
        debug_value(shot_id),
        debug_value(damage),
        debug_value(hitchance),
        debug_value(resolved_yaw),
        state and state.pattern or "NO_STATE_MATCH",
        state and tostring(state.sample_count) or "n/a",
        state and tostring(state.candidates and #state.candidates or 0) or "n/a",
        state and json.stringify(state.candidates) or "[]",
        state and tostring(state.sample_source) or "n/a",
        state and debug_value(state.last_sample) or "n/a",
        debug_value(old_choice),
        debug_value(old_angle),
        debug_value(next_choice),
        debug_value(next_angle),
        state and tostring(state.misses) or "n/a",
        shot and "aim_fire" or "event_only"
    ))
end)

client.set_event_callback("aim_hit", function(e)
    if not e then
        return
    end

    local state = find_state_for_event(e.target)
    local shot = get_shot_for_event(e)
    local choice = shot and shot.state_choice
        or (state and state.choice)
        or nil

    if state then
        state.hits += 1
        state.misses = 0
        state.last_miss_time = -math.huge
        score_candidate(state, choice, true)
    end
end)

local hud_text = Drawing.new("Text")
hud_text.Text = "MRTHANYS LUA | SCANNING\np200 resolver ong"
hud_text.Position = vector(16, 316)
hud_text.Color = color(80, 220, 255)
hud_text.Size = 16
hud_text.Font = Drawing.Fonts.Plex or 2
hud_text.Visible = true

client.set_event_callback("paint", function()
    if not show_indicator:get() then
        hud_text.Visible = false
        return
    end

    hud_text.Visible = true

    if not enabled:get() then
        hud_text.Text = "MRTHANYS LUA | OFF"
        hud_text.Color = color(170, 170, 170)
        return
    end

    local target = rage.get_target()
    local state = target
        and target.player
        and states_by_player[target.player]
        or nil

    if state then
        local angle_text = state.applied
            and string.format("%.1f°", state.applied)
            or "--"

        local line = string.format(
            "MRTHANYS LUA | %s | ANGLE %s | MISS %d",
            state.pattern,
            angle_text,
            state.misses
        )

        if show_stats:get() then
            line = line .. string.format(
                " | HIT %d",
                state.hits
            )
        end

        hud_text.Text = line
    else
        hud_text.Text = "MRTHANYS LUA | SCANNING"
    end

    hud_text.Color = color(80, 220, 255)
end)

client.set_event_callback("shutdown", function()
    reset_all_tracked()
    rage.set_resolver_enabled(native_resolver_initial)
    if aa_was_active then
        aa.reset()
        aa_was_active = false
    end
    autostop_destroy_force()
    hud_text:Remove()
end)