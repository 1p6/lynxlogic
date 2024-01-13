-- global mod table
lynxlogic = {}

local persist_path = minetest.get_worldpath() .. '/lynxlogic_persist.txt'
local function loadpersist()
    local f = io.open(persist_path, 'r')
    if not f then return {} end
    local t = f:read('a')
    f:close()
    if not t or t == '' then return {} end
    return minetest.deserialize(t)
end
local persist = loadpersist()
minetest.register_on_shutdown(function()
    minetest.safe_file_write(persist_path, minetest.serialize(persist))
end)

--[[
wire = {
    ctr = 0 --number of sources currently powering this wire
    idx = 0 to 16 -- palette index, lsb should be 0
    pos = {pos1, pos2} -- array of position hashes
    -- the following can be nil to represent that they should be recomputed from pos array
    downstream = {wire = true, wire = true} -- set of wire indices, wires that are powered by this wire
    upstream = {wire = true, ...} --set of wire indices, wires that power this wire
    sinks = {pos = true, ...} --set of adjacent sink pos
}
source = {
    state = {true, false, etc} -- array of eight outputs for the 8 channels
    wires = {wire = true, ...} --set of adjacent wire indices, can be nil to be recomputed
}
sink = {
    update_fn = string --name of update function in registry
    wires = {wire = true, ...} --set of adjacent wire indices, can be nil to be recomputed
}
--]]
if not persist.target_tps then persist.target_tps = 0.2 end
if not persist.tick_delta then persist.tick_delta = 0 end
--TODO convert persist.lag_thresh into a proper mod setting
if not persist.lag_thresh then persist.lag_thresh = 0.3 end -- in seconds

lynxlogic.all_dirs = {
    vector.new(1, 0, 0),
    vector.new(0, 1, 0),
    vector.new(0, 0, 1),
    vector.new(-1, 0, 0),
    vector.new(0, -1, 0),
    vector.new(0, 0, -1),
}
local wire_cache = {}

dofile(minetest.get_modpath('lynxlogic') .. '/vm_cache.lua')
dofile(minetest.get_modpath('lynxlogic') .. '/wirenet.lua')(persist, wire_cache)
dofile(minetest.get_modpath('lynxlogic') .. '/debug.lua')

minetest.register_globalstep(function(dtime)
    local target_tps = persist.target_tps
    local lag_thresh = persist.lag_thresh
    if dtime > lag_thresh and target_tps > 0 then
        --reduce target_tps in case of lag
        -- cant div by zero, since dtime > lag_thresh > 0
        target_tps = target_tps * lag_thresh / dtime
        persist.target_tps = target_tps
    end
    local tick_delta = persist.tick_delta + dtime * target_tps
    local ticks = math.floor(tick_delta)
    persist.tick_delta = tick_delta - ticks
    lynxlogic.do_n_steps(ticks)
end)

minetest.register_chatcommand('lynxlogic_settps', {
    description = "Set target circuit ticks per second (0 = no ticks, ie stopped).",
    privs = {
        interact = true,
    },
    func = function(name, param)
        persist.target_tps = tonumber(param)
        return true, 'Target tps set to ' .. persist.target_tps .. '.'
    end,
})

minetest.register_chatcommand('lynxlogic_tick', {
    description = "Tick the circuits n (default 0) times.",
    privs = {
        interact = true,
    },
    func = function(name, param)
        --if persist.target_tps ~= 0 then return false, 'Circuits already running' end
        local n = tonumber(param)
        if not n then n = 1 end
        lynxlogic.do_n_steps(n)
        return true, 'Successfully performed ' .. n .. ' ticks.'
    end,
})

minetest.register_chatcommand('lynxlogic_debug', {
    description = "Print persistent info.",
    privs = {
        interact = true,
    },
    func = function(name, param)
        local source_change_count = 0
        for k in pairs(persist.wirenet.source_changes) do
            source_change_count = source_change_count+1
        end
        return true, minetest.serialize(persist) .. '\nsource change count = ' ..
                source_change_count
    end,
})

for i=0,8 do
    local name_off = "lynxlogic:wire_"..i.."_off"
    local name_on = "lynxlogic:wire_"..i.."_on"
    local groups = {dig_immediate = 2}
    if i ~= 0 then groups.not_in_creative_inventory = 1 end
    local i_next = (i-1) % 8
    local wire_def = {
        --ticking
        update_wire = function(wire, pos, node, node_def, wire_node_def, source)
            local hash = minetest.hash_node_position(pos)
            if source[wire_node_def.lynxlogic.wire_color] then
                wire.sources[hash] = 1
            else
                wire.sources[hash] = nil
            end
        end,
        set_nodes = function(wire)
            local new_state = next(wire.sources) ~= nil
            if new_state ~= wire.initial_state then
                wire.initial_state = new_state
                local new_suffix = (new_state and '_on') or '_off'
                for hash in pairs(wire.pos) do
                    local pos = minetest.get_position_from_hash(hash)
                    local node = lynxlogic.vm_cache.get_node(pos)
                    local node_def = minetest.registered_nodes[node.name]
                    lynxlogic.vm_cache.set_node(pos, {name = "lynxlogic:wire_" ..
                            node_def.lynxlogic.wire_color .. new_suffix})
                    lynxlogic.source_change(pos)
                end
                for hash2,updater in pairs(wire.updaters) do
                    updater(minetest.get_position_from_hash(hash2))
                end
            end
        end,
        --traversal
        init = function(wire, pos, node, node_def)
            wire.initial_state = node_def.lynxlogic.wire_state
            print(minetest.serialize({'init wire! st: ', wire.initial_state, ' color: ',
                    node_def.lynxlogic.wire_color}))
            wire.sources = {}
        end,
        connects_to = function(wire, pos, node, node_def, prev_node_def)
            local our_color = prev_node_def.lynxlogic.wire_color
            local oth_color = node_def.lynxlogic.wire_color
            local connects = oth_color == our_color or
                our_color == 8 or oth_color == 8
            if connects and wire.initial_state ~= node_def.lynxlogic.wire_state then
                wire.initial_state = nil
            end
            return connects
        end,
        add_source = function(wire, pos2, node, node_def, prev_node_def, source)
            if source[prev_node_def.lynxlogic.wire_color] then
                local hash2 = minetest.hash_node_position(pos2)
                wire.sources[hash2] = 1
            end
        end,
        finish_init = function() end,
    }
    minetest.register_node(name_off, {
        description = "Wire " .. i,
        tiles = {"lynxlogic_wire_"..i.."_off.png"},
        groups = groups,
        light_source = minetest.LIGHT_MAX,
        on_construct = lynxlogic.invalidate_wire_cache_around,
        on_destruct = lynxlogic.invalidate_wire_cache_at,
        lynxlogic = {
            do_paint = function(pos, node, color_idx)
                local newnode = {name = "lynxlogic:wire_"..color_idx.."_off"}
                minetest.set_node(pos, newnode)
            end,
            get_source = function(pos, node, node_def)
                if i == 8 then return {}
                else return {[i_next] = false} end
            end,
            wire_color = i,
            wire_state = false,
            wire = wire_def,
        },
    })
    minetest.register_node(name_on, {
        description = "Wire " .. i,
        tiles = {"lynxlogic_wire_"..i.."_on.png"},
        groups = groups,
        light_source = minetest.LIGHT_MAX,
        on_construct = lynxlogic.invalidate_wire_cache_around,
        after_destruct = lynxlogic.invalidate_wire_cache_at,
        lynxlogic = {
            do_paint = function(pos, node, color_idx)
                local newnode = {name = "lynxlogic:wire_"..color_idx.."_on"}
                minetest.set_node(pos, newnode)
            end,
            get_source = function(pos, node, node_def)
                if i == 8 then return {}
                else return {[i_next] = true} end
            end,
            wire_color = i,
            wire_state = true,
            wire = wire_def,
        },
    })
    if minetest.global_exists('mesecon') and mesecon.register_mvps_stopper then
        mesecon.register_mvps_stopper(name_off)
        mesecon.register_mvps_stopper(name_on)
    end
end

minetest.register_node("lynxlogic:not_gate", {
    description = "Not Gate",
    tiles = {"lynxlogic_not_gate.png"},
    groups = {dig_immediate = 2},
    light_source = minetest.LIGHT_MAX,
    on_construct = function(pos)
        lynxlogic.add_updaters_around(pos)
        lynxlogic.source_change(pos)
    end,
    after_destruct = function(pos)
        lynxlogic.remove_updaters_around(pos)
        lynxlogic.source_change(pos)
    end,
    lynxlogic = {
        get_source = function(pos, node, node_def)
            local or_ed = {}
            for i=1,6 do
                local pos2 = vector.add(pos, lynxlogic.all_dirs[i])
                local node = lynxlogic.vm_cache.get_node(pos2)
                local node_def = minetest.registered_nodes[node.name]
                local ndll = node_def.lynxlogic
                if ndll and ndll.wire_color and ndll.wire_color < 8 then
                    local color_out = (ndll.wire_color+1) % 8
                    or_ed[color_out] = or_ed[color_out] or ndll.wire_state
                end
            end
            local any = false
            for k,v in pairs(or_ed) do
                or_ed[k] = not v
                any = any or not v
            end
            or_ed[8] = any
            return or_ed
        end,
        --typical for gate-like nodes
        on_update = lynxlogic.source_change,
    },
})
if minetest.global_exists('mesecon') and mesecon.register_mvps_stopper then
    mesecon.register_mvps_stopper("lynxlogic:not_gate")
end

lynxlogic.all_on_source = {}
for i=0,8 do
    lynxlogic.all_on_source[i] = true
end

minetest.register_node("lynxlogic:switch_off", {
    description = "Switch",
    tiles = {"lynxlogic_switch_off.png"},
    groups = {dig_immediate = 2},
    light_source = minetest.LIGHT_MAX,
    on_construct = lynxlogic.source_change,
    after_destruct = lynxlogic.source_change,
    --[[lynxlogic = {
        get_source = function(pos, node, node_def)
            return {}
        end,
    },]]
    on_rightclick = function(pos)
        minetest.set_node(pos, {name="lynxlogic:switch_on"})
    end,
})
minetest.register_node("lynxlogic:switch_on", {
    description = "Switch On",
    tiles = {"lynxlogic_switch_on.png"},
    groups = {dig_immediate = 2},
    light_source = minetest.LIGHT_MAX,
    on_construct = lynxlogic.source_change,
    after_destruct = lynxlogic.source_change,
    lynxlogic = {
        get_source = function(pos, node, node_def)
            return lynxlogic.all_on_source
        end,
    },
    on_rightclick = function(pos)
        minetest.set_node(pos, {name="lynxlogic:switch_off"})
    end,
})

local paint_secondary = function(stack, user, pt)
    local offset = 1
    if user:get_player_control().sneak then offset = -1 end
    local meta = stack:get_meta()
    meta:set_int("palette_index", (offset + meta:get_int("palette_index")) % 9)
    return stack
end

minetest.register_craftitem("lynxlogic:paint", {
    description = "Paint\nUsed for coloring wires",
    inventory_image = "lynxlogic_paint.png",
    palette = "lynxlogic_palette.png",
    color = 0xFF760000,

    on_place = paint_secondary,
    on_secondary_use = paint_secondary,
    on_use = function(stack, user, pt)
        if pt.type ~= 'node' then return nil end
        local node = minetest.get_node(pt.under)
        local node_type = minetest.registered_nodes[node.name]
        if not node_type.lynxlogic or not node_type.lynxlogic.do_paint then return nil end
        node_type.lynxlogic.do_paint(pt.under, node, stack:get_meta():get_int("palette_index"))
        return nil
    end
})

minetest.register_craftitem("lynxlogic:updater", {
    description = "Updater\nUsed to force an update on a circuit block",
    inventory_image = "lynxlogic_updater.png",
    on_place = function(stack, user, pt)
        if pt.type ~= 'node' then return nil end
        lynxlogic.source_change(pt.under)
        return nil
    end,
})

local function ticker_click()
    lynxlogic.do_n_steps(1)
end
minetest.register_craftitem("lynxlogic:ticker", {
    description = "Ticker\nDo one circuit tick",
    inventory_image = "lynxlogic_ticker.png",
    on_place = ticker_click,
    on_secondary_use = ticker_click,
})

minetest.register_craftitem("lynxlogic:highlighter", {
    description = "Highlighter\nHighlight various nodes",
    inventory_image = "lynxlogic_highlighter.png",
    on_place = function(stack, user, pt)
        if pt.type ~= 'node' then return end
        local hash = minetest.hash_node_position(pt.under)
        local wire = wire_cache[hash]
        if not wire then return end
        for hash2 in pairs(wire.sources) do
            lynxlogic.show_debug_box(minetest.get_position_from_hash(hash2))
        end
    end,
    on_secondary_use = function()
        for hash in pairs(persist.wirenet.source_changes) do
            lynxlogic.show_debug_box(minetest.get_position_from_hash(hash))
        end
    end,
    on_use = function()
        lynxlogic.remove_all_debug_boxes()
    end,
})


