data:extend({
  {
    type = "selection-tool",
    name = "sorter-mod-area-tool",
    icon = "__base__/graphics/icons/blueprint.png",
    icon_size = 64, icon_mipmaps = 4,
    subgroup = "tool",
    order = "z[sorter]-a[selection-tool]",
    stack_size = 1,
    flags = {"spawnable", "only-in-cursor"},
    select = {
      border_color = {1, 1, 0},
      cursor_box_type = "copy",
      mode = {"any-entity", "same-force", "friend"}
    },
    alt_select = {
      border_color = {1, 1, 0},
      cursor_box_type = "copy",
      mode = {"any-entity", "same-force", "friend"}
    }
  },  
  {
    type = "custom-input",
    name = "sorter-mod-spawn-tool",
    key_sequence = "SHIFT + Y",
    consuming = "game-only",
    action = "spawn-item",
    item_to_spawn = "sorter-mod-area-tool"
  },
  {
    type = "shortcut",
    name = "sorter-mod-area-tool-shortcut",
    localised_name = {"shortcut-name.sorter-mod-area-tool-shortcut"},
    localised_description = {"shortcut-description.sorter-mod-area-tool-shortcut"},
    action = "spawn-item",
    item_to_spawn = "sorter-mod-area-tool",
    associated_control_input = "sorter-mod-spawn-tool",
    style = "blue",
    icon = "__base__/graphics/icons/blueprint.png",
    small_icon = "__base__/graphics/icons/blueprint.png"
  }
  ,
  {
    type = "custom-input",
    name = "sorter-mod-sort",
    key_sequence = "Y",
    consuming = "none"
  }
})
