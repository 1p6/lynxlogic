local persist
local wirenet
local wire_cache
local function setup_fn(per, wire_cache_in)
    persist = per
    wire_cache = wire_cache_in
    if not persist.wirenet then persist.wirenet = {} end
    wirenet = persist.wirenet
    --if not wirenet.sources then wirenet.sources = {} end
    if not wirenet.source_changes then wirenet.source_changes = {} end
end

function lynxlogic.remove_updaters_around(pos)
    local hash = minetest.hash_node_position(pos)
    for i=1,6 do
        local pos2 = vector.add(pos, lynxlogic.all_dirs[i])
        local hash2 = minetest.hash_node_position(pos2)
        local wire = wire_cache[hash2]
        if wire then
            wire.updaters[hash] = nil
        end
    end
end

function lynxlogic.add_updaters_around(pos)
    local hash = minetest.hash_node_position(pos)
    local node = minetest.get_node(pos) --not vm_cache!! called from on_destruct
    local node_def = minetest.registered_nodes[node.name]
    local updaterr = node_def.lynxlogic.on_update
    if not updaterr then error('aaaaaaaaaa') end
    for i=1,6 do
        local pos2 = vector.add(pos, lynxlogic.all_dirs[i])
        local hash2 = minetest.hash_node_position(pos2)
        local wire = wire_cache[hash2]
        if wire then
            wire.updaters[hash] = updaterr
        end
    end
end

--NOTE: must call vm_cache.commit after!!
function lynxlogic.get_wire_at(pos)
    local hash = minetest.hash_node_position(pos)
    local wire = wire_cache[hash]
    if wire then return wire end
    --BEGIN WIRE TRAVERSAL
    wire = {
        pos = {},
        updaters = {},
    }
    local checked = {}
    local stack = {{pos, nil}}
    while #stack > 0 do
        local pos2 = stack[#stack]
        local prev_node_def = pos2[2]
        pos2 = pos2[1]
        stack[#stack] = nil
        local hash2 = minetest.hash_node_position(pos2)
        if not checked[hash2] then
            local node = lynxlogic.vm_cache.get_node(pos2)
            local node_def = minetest.registered_nodes[node.name]
            local node_def_ll = node_def.lynxlogic
            if node_def_ll then
                --oh if only lua had continue statements, perhaps goto could help
                local node_def_wire = node_def_ll.wire
                local our_wire
                if node_def_wire then
                    if not wire.wire_def then
                        wire.wire_def = node_def_wire
                        wire.wire_def.init(wire, pos2, node, node_def)
                        our_wire = true
                    else if wire.wire_def.connects_to(wire, pos2, node, node_def, prev_node_def) then
                        our_wire = true
                    end end
                    if our_wire then
                        for i = 1,6 do
                            stack[#stack+1] = {vector.add(pos2, lynxlogic.all_dirs[i]),
                                    node_def}
                        end
                        wire.pos[hash2] = true
                        wire_cache[hash2] = wire
                        checked[hash2] = true
                    end
                else
                    if not wire.wire_def then
                        break
                    end
                end
                if not our_wire then
                    local node_def_updater = node_def_ll.on_update
                    if node_def_updater then
                        wire.updaters[hash2] = node_def_updater
                    end
                    local node_def_get_source = node_def_ll.get_source
                    if node_def_get_source then
                        wire.wire_def.add_source(wire, pos2, node, node_def, prev_node_def,
                            node_def_get_source(pos2, node, node_def))
                    end
                end
            end
        end
    end
    if wire.wire_def then
        print('HEY WHAT GGET WIRE AT THATS WHAT')
        wire.wire_def.finish_init(wire)
        return wire
    else
        return nil
    end
end
--used when breaking a wire
function lynxlogic.invalidate_wire_cache_at(pos, disable_cache_commit)
    print('invalid ur mom!!!!!!')
    local hash = minetest.hash_node_position(pos)
    wirenet.source_changes[hash] = 1
    local wire = wire_cache[hash]
    if not wire then return end
    for hash2 in pairs(wire.pos) do
        wire_cache[hash2] = nil
    end
    for hash2,updater in pairs(wire.updaters) do
        updater(minetest.get_position_from_hash(hash2))
    end
    if not disable_cache_commit then
        for i=1,6 do
            lynxlogic.source_change(vector.add(pos, lynxlogic.all_dirs[i]))
        end
        lynxlogic.vm_cache.commit()
    end
end
--used when placing a wire
function lynxlogic.invalidate_wire_cache_around(pos)
    print('invalid ur mom!!!!!!')
    lynxlogic.invalidate_wire_cache_at(pos, true)
    for i=1,6 do
        lynxlogic.invalidate_wire_cache_at(vector.add(pos, lynxlogic.all_dirs[i]), true)
    end
    lynxlogic.vm_cache.commit()
end

-- performs n steps of the logic simulation
function lynxlogic.do_n_steps(n)
    if n <= 0 then return end
    print('doing ' .. n .. ' ticks :D')
    for i = 1,n do
        local changed_wires = {}
        for hash in pairs(wirenet.source_changes) do
            local pos = minetest.get_position_from_hash(hash)
            local node = lynxlogic.vm_cache.get_node(pos)
            local node_def = minetest.registered_nodes[node.name]
            local source = (node_def.lynxlogic and node_def.lynxlogic.get_source
                and node_def.lynxlogic.get_source(pos, node, node_def)) or {}
            for i = 1,6 do
                local offset_pos = vector.add(pos, lynxlogic.all_dirs[i])
                local wire_node = lynxlogic.vm_cache.get_node(offset_pos)
                local wire_node_def = minetest.registered_nodes[wire_node.name]
                local wire = lynxlogic.get_wire_at(offset_pos)
                if wire then
                    wire.wire_def.update_wire(wire, pos, node, node_def, wire_node_def, source)
                    changed_wires[wire] = true
                end
            end
        end
        wirenet.source_changes = {}
        for wire in pairs(changed_wires) do
            wire.wire_def.set_nodes(wire)
        end
    end
    lynxlogic.vm_cache.commit()
end

function lynxlogic.source_change(pos)
    local hash = minetest.hash_node_position(pos)
    wirenet.source_changes[hash] = 1
end

--[[function lynxlogic.set_source(pos, vals)
    local hash = minetest.hash_node_position(pos)
    if next(vals) then wirenet.sources[hash] = vals
    else wirenet.sources[hash] = nil end
    wirenet.source_changes[hash] = true
end
function lynxlogic.get_source(pos)
    local s = wirenet.sources[minetest.hash_node_position(pos)]
    if s then return s else return {} end
end]]

return setup_fn