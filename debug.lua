--[[
    debug entites inspired by the minetest worldedit mod:
    https://github.com/Uberi/Minetest-WorldEdit/blob/b90eeb1e6882a779f3dd5226a7d097be0397dc46/worldedit_commands/mark.lua#L126
]]

minetest.register_entity("lynxlogic:debug_box", {
    initial_properties = {
        visual = 'cube',
        visual_size = {x=1.01,y=1.01},
        textures = {"lynxlogic_debug_box.png","lynxlogic_debug_box.png",
        "lynxlogic_debug_box.png","lynxlogic_debug_box.png",
        "lynxlogic_debug_box.png","lynxlogic_debug_box.png",},
        physical = false,
        pointable = false,
        static_save = false,
    },
})

lynxlogic.debug_boxes = {}

function lynxlogic.show_debug_box(pos)
    lynxlogic.debug_boxes[minetest.add_entity(pos, "lynxlogic:debug_box")] = 1
end

function lynxlogic.remove_all_debug_boxes()
    for ent in pairs(lynxlogic.debug_boxes) do
        ent:remove()
    end
    lynxlogic.debug_boxes = {}
end