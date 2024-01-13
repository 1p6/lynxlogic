--[[
-- vm_cache code inspired by mesecons's vm_cache:
-- https://github.com/minetest-mods/mesecons/blob/7418d5cb6139b6eb31d403175184a8e04aa3ee06/mesecons/util.lua#L354
--]]

lynxlogic.vm_cache = {}

local BLOCK_SIZE = 16

local function hash_block_pos(pos)
    return minetest.hash_node_position({
        x = bit.arshift(pos.x, 4),
        y = bit.arshift(pos.y, 4),
        z = bit.arshift(pos.z, 4),
    })
end

local vm_cache = {}
local wr_dirty = {}
local vm_read = {}

function lynxlogic.vm_cache.set_node(pos, node)
    local hash = hash_block_pos(pos)
    local ent = vm_cache[hash]
    if not ent then
        ent = {
            pos = pos,
            vm = VoxelManip(pos, pos),
        }
        vm_cache[hash] = ent
        vm_read[ent] = 1
    end
    if not vm_read[ent] then
        ent.vm = VoxelManip(ent.pos, ent.pos)
        --ent.vm:read_from_map(ent.pos, ent.pos)
        vm_read[ent] = 1
    end
    wr_dirty[ent] = 1
    ent.vm:set_node_at(pos, node)
end

function lynxlogic.vm_cache.get_node(pos)
    local hash = hash_block_pos(pos)
    local ent = vm_cache[hash]
    --print('get_node 1')
    if not ent then
        print('get_node 2')
        ent = {
            pos = pos,
            vm = VoxelManip(pos, pos),
        }
        vm_cache[hash] = ent
        vm_read[ent] = 1
    end
    if not vm_read[ent] then
        print('get_node 3')
        ent.vm = VoxelManip(ent.pos, ent.pos)
        --ent.vm:read_from_map(ent.pos, ent.pos)
        vm_read[ent] = 1
    end
    return ent.vm:get_node_at(pos)
end

function lynxlogic.vm_cache.commit()
    print('COMMIT MEOW')
    for ent in pairs(wr_dirty) do
        ent.vm:write_to_map(false)
    end
    wr_dirty = {}
    vm_read = {}
end
