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
local show_indicator = display_sec:new_toggle("Show resolver indicator", true)
local show_stats = display_sec:new_toggle("Show hit / miss stats", true)
local show_enemy_direction = display_sec:new_toggle("Show nearest enemy arrow", true)

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

-- Nearest-enemy direction indicator (camera-relative).
local function draw_nearest_enemy_direction()
    if not show_enemy_direction:get() then
        return
    end

    local local_player = entity.get_local_player()
    if not local_player or not entity.is_alive(local_player) then
        return
    end

    local local_pos = entity.get_player_position(local_player)
    if not local_pos then
        return
    end

    local _, camera_yaw = client.get_camera_angles_deg()
    if camera_yaw == nil then
        return
    end

    local nearest = nil
    local nearest_distance = math.huge

    for _, enemy in ipairs(entity.get_enemies()) do
        if entity.is_alive(enemy) then
            local enemy_pos = entity.get_player_position(enemy)
            if enemy_pos then
                local dx = enemy_pos.X - local_pos.X
                local dy = enemy_pos.Y - local_pos.Y
                local dz = enemy_pos.Z - local_pos.Z
                local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

                if distance < nearest_distance then
                    nearest_distance = distance
                    nearest = {
                        player = enemy,
                        dx = dx,
                        dz = dz,
                    }
                end
            end
        end
    end

    if not nearest then
        return
    end

    -- Roblox yaw 0 faces -Z; convert the enemy bearing to camera-relative yaw.
    local bearing = math.deg(math.atan2(-nearest.dx, -nearest.dz))
    local relative = ((bearing - camera_yaw + 180) % 360) - 180
    local radians = math.rad(relative)

    local screen_w, screen_h = render.screen_size()
    local cx, cy = screen_w * 0.5, screen_h * 0.5
    local radius = 105
    local dir_x = math.sin(radians)
    local dir_y = -math.cos(radians)

    local tip = vector(cx + dir_x * radius, cy + dir_y * radius)
    local back_x = cx + dir_x * (radius - 20)
    local back_y = cy + dir_y * (radius - 20)
    local perp_x = -dir_y * 9
    local perp_y = dir_x * 9
    local left = vector(back_x + perp_x, back_y + perp_y)
    local right = vector(back_x - perp_x, back_y - perp_y)

    local is_behind = math.abs(relative) > 90
    local arrow_color = is_behind
        and color(255, 85, 85)
        or color(80, 220, 255)

    render.triangle(tip, left, right, arrow_color, true, 1)
    render.circle(cx, cy, radius, color(100, 100, 100), 1)

    local info = entity.get_info(nearest.player)
    local enemy_name = info and info.name or "ENEMY"
    local direction_text = is_behind and "BEHIND" or "IN FRONT"
    local distance_text = string.format("%.0f studs", nearest_distance)
    local label = string.format("%s  |  %s  |  %s", direction_text, enemy_name, distance_text)

    render.text(cx, cy + 128, label, arrow_color, 14, true, true, Drawing.Fonts.Plex or 2)
end

local hud_text = Drawing.new("Text")
hud_text.Text = "MRTHANYS LUA | SCANNING
p200 resolver ong"
hud_text.Position = vector(16, 316)
hud_text.Color = color(80, 220, 255)
hud_text.Size = 16
hud_text.Font = Drawing.Fonts.Plex or 2
hud_text.Visible = true

client.set_event_callback("paint", function()
    draw_nearest_enemy_direction()
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
    hud_text:Remove()
end)