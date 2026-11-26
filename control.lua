-- Chest Sorter — control.lua (Factorio 2.0)
-- Final: event-driven, optimized, with trash->areas auto-dump and request refills.

-- === 2.0 storage/global alias =============================================
if storage and not global then global = storage end
if global and not storage then storage = global end

ChestSorter = ChestSorter or {}
local Requests

local REQUEST_REFRESH_FULL_DELAY_TICKS = 12
local REQUEST_REFRESH_ITEM_DELAY_TICKS = 1

-- === Init / migrations ======================================================
script.on_init(function()
  storage.areas = storage.areas or {}                  -- [player_index] = { list = { {area=..., surface_index=...}, ... } }
  storage.trash_guard = storage.trash_guard or {}      -- [player_index] = last_tick processed (re-entrancy guard)
  storage.chest_cache = storage.chest_cache or {}      -- [player_index] = { known = { [unit_number] = entity, ... }, dirty = bool }
  storage.requests_queue = storage.requests_queue or {} -- [player_index] = { due_tick = ..., full = bool, item_name = string?, force = bool }
  storage.cursor_refresh_guard = storage.cursor_refresh_guard or {} -- [player_index][item_name] = last_tick (re-entrancy guard)
  if Requests and Requests.on_init then
    Requests.on_init()
  end
end)

script.on_configuration_changed(function()
  storage.areas = storage.areas or {}
  storage.trash_guard = storage.trash_guard or {}
  storage.chest_cache = storage.chest_cache or {}
  storage.requests_queue = storage.requests_queue or {}
  storage.cursor_refresh_guard = storage.cursor_refresh_guard or {}
  if Requests and Requests.on_configuration_changed then
    Requests.on_configuration_changed()
  end
  if Requests and Requests.ensure_gui then
    for _, player in pairs(game.players) do
      if player and player.valid then
        Requests.ensure_gui(player)
      end
    end
  end
end)

-- === Small utils ============================================================
local function rect_size(area)
  local w = math.floor(area.right_bottom.x - area.left_top.x + 0.5)
  local h = math.floor(area.right_bottom.y - area.left_top.y + 0.5)
  return w, h
end

local function ensure_player_areas(player)
  storage.areas = storage.areas or {}
  local bucket = storage.areas[player.index]
  if not bucket then
    bucket = { list = {} }
    storage.areas[player.index] = bucket
  end
  return bucket
end

local function get_player_areas(player)
  local bucket = storage.areas and storage.areas[player.index] or nil
  if not bucket or not bucket.list or #bucket.list == 0 then return nil end
  return bucket.list -- { {area=..., surface_index=...}, ... }
end

local function position_in_area(area, position)
  return position.x >= area.left_top.x
    and position.x < area.right_bottom.x
    and position.y >= area.left_top.y
    and position.y < area.right_bottom.y
end

local function find_area_for_entity(areas, entity)
  if not (areas and entity and entity.valid and entity.surface and entity.position) then return nil end
  for _, rec in ipairs(areas) do
    if rec.surface_index == entity.surface.index and position_in_area(rec.area, entity.position) then
      return rec
    end
  end
end

local function ensure_player_chest_cache(player)
  storage.chest_cache = storage.chest_cache or {}
  local bucket = storage.chest_cache[player.index]
  if not bucket then
    bucket = { known = {}, dirty = true }
    storage.chest_cache[player.index] = bucket
  end
  bucket.known = bucket.known or {}
  return bucket
end

local function ensure_request_queue(player)
  storage.requests_queue = storage.requests_queue or {}
  local bucket = storage.requests_queue[player.index]
  if not bucket then
    bucket = { due_tick = 0, full = false, item_name = nil, force = false }
    storage.requests_queue[player.index] = bucket
  end
  return bucket
end

local function queue_request_refresh(player, item_name, force)
  if not (player and player.valid and player.character) then return end

  local bucket = ensure_request_queue(player)
  bucket.force = bucket.force or force == true

  if type(item_name) == "string" and item_name ~= "" then
    if bucket.full then
      return
    end
    if bucket.item_name == nil then
      bucket.item_name = item_name
    elseif bucket.item_name ~= item_name then
      bucket.item_name = nil
      bucket.full = true
    end
    if not bucket.full then
      -- Item-specific: schedule soon and never push the deadline later while placing.
      local new_due = game.tick + REQUEST_REFRESH_ITEM_DELAY_TICKS
      bucket.due_tick = bucket.due_tick and math.min(bucket.due_tick, new_due) or new_due
      return
    end
  end

  bucket.item_name = nil
  bucket.full = true
  bucket.due_tick = game.tick + REQUEST_REFRESH_FULL_DELAY_TICKS
end

local function flush_request_refresh_queue()
  local queue = storage.requests_queue
  if not queue then return end

  for player_index, bucket in pairs(queue) do
    if bucket and bucket.due_tick and bucket.due_tick <= game.tick then
      local player = game.get_player(player_index)
      if player and player.valid and player.character and Requests then
        if bucket.full or not bucket.item_name then
          if Requests.process then
            Requests.process(player, bucket.force)
          end
        elseif Requests.process_item then
          Requests.process_item(player, bucket.item_name, bucket.force)
        elseif Requests.process then
          Requests.process(player, bucket.force)
        end
      end
      queue[player_index] = nil
    end
  end
end

script.on_nth_tick(1, flush_request_refresh_queue)

local function mark_player_chest_cache_dirty(player)
  local bucket = ensure_player_chest_cache(player)
  bucket.known = {}
  bucket.dirty = true
end

local function is_cacheable_chest(e)
  if not (e and e.valid) then return false end
  if e.type ~= "container" and e.type ~= "logistic-container" then return false end
  return e.get_inventory(defines.inventory.chest) ~= nil
end

local collect_area_chests_in_areas

local function bootstrap_player_chest_cache(player)
  local bucket = ensure_player_chest_cache(player)
  local areas = get_player_areas(player)
  local known = {}

  if areas then
    for _, chest in ipairs(collect_area_chests_in_areas(player, areas)) do
      if chest and chest.valid and chest.unit_number then
        known[chest.unit_number] = chest
      end
    end
  end

  bucket.known = known
  bucket.dirty = false
  return bucket
end

local function cache_chest_for_player(player, chest)
  if not (player and player.valid and chest and chest.valid and chest.unit_number) then return end
  if not is_cacheable_chest(chest) then return end

  local areas = get_player_areas(player)
  if not areas or not find_area_for_entity(areas, chest) then return end

  local bucket = ensure_player_chest_cache(player)
  bucket.known[chest.unit_number] = chest
end

local function forget_chest_from_all_caches(chest)
  if not (chest and chest.valid and chest.unit_number and storage.chest_cache) then return end

  local unit_number = chest.unit_number
  for _, bucket in pairs(storage.chest_cache) do
    if bucket and bucket.known then
      bucket.known[unit_number] = nil
    end
  end
end

local function get_cached_area_chests(player, areas, exclude_entity)
  local bucket = ensure_player_chest_cache(player)
  if bucket.dirty then
    bootstrap_player_chest_cache(player)
  end

  areas = areas or get_player_areas(player)
  if not areas then return {} end

  local chests = {}
  local known = bucket.known or {}
  for unit_number, chest in pairs(known) do
    if not (chest and chest.valid and chest.unit_number == unit_number) then
      known[unit_number] = nil
    elseif chest ~= exclude_entity and chest.force == player.force then
      local area = find_area_for_entity(areas, chest)
      if not area then
        known[unit_number] = nil
      else
        local inv = chest.get_inventory(defines.inventory.chest)
        if inv and inv.valid then
          chests[#chests + 1] = chest
        end
      end
    end
  end

  return chests
end

local function player_main_inventory(player)
  if player and player.valid and player.character then
    return player.get_main_inventory()
  end
end

-- Count we currently have: inventory + (cursor, if same item)
local function inv_plus_cursor_count(player, item_name)
  local inv = player_main_inventory(player)
  local have = inv and inv.get_item_count(item_name) or 0
  local cs = player.cursor_stack
  if cs and cs.valid_for_read and cs.name == item_name then
    have = have + cs.count
  end
  return have
end

-- === Areas: find chests & grid placement ===================================
local CELL_W, CELL_H = 1, 1
local EXCLUDED_CHEST_ITEM_NAMES = {
  ["memory-unit"] = true,
}

local function with_grid(area, fn)
  local x0 = math.floor(area.left_top.x)
  local y0 = math.floor(area.left_top.y)
  local x1 = math.floor(area.right_bottom.x - 1)
  local y1 = math.floor(area.right_bottom.y - 1)
  for y = y0, y1, CELL_H do
    for x = x0, x1, CELL_W do
      if fn(x + 0.5, y + 0.5) == true then return true end
    end
  end
end

local function first_free_grid_cell_in_areas(areas, entity_name, player)
  local player_surface_index = (player and player.surface and player.surface.index) or -1
  for _,rec in ipairs(areas) do
    local surface = game.surfaces[rec.surface_index]
    local area = rec.area
    local found = nil
    with_grid(area, function(cx, cy)
      -- keep small distance if same surface (avoid placing under player)
      if rec.surface_index == player_surface_index then
        local dx,dy = cx - player.position.x, cy - player.position.y
        if (dx*dx + dy*dy) < (2.5*2.5) then return false end
      end
      local pos = surface.find_non_colliding_position(entity_name, {x=cx, y=cy}, 0.1, 0.05)
      if pos then found = pos; return true end
    end)
    if found then return found, surface end
  end
  return nil, nil
end

local function is_chest_entity(e)
  if not (e and e.valid) then return false end
  if e.type ~= "container" and e.type ~= "logistic-container" then return false end
  return e.get_inventory(defines.inventory.chest) ~= nil
end

-- Collect all simple chests inside player's areas (all surfaces), de-duplicated
collect_area_chests_in_areas = function(player, areas, exclude_entity)
  if not areas then return {} end
  local chests, seen = {}, {}
  for _,rec in ipairs(areas) do
    local surface = game.surfaces[rec.surface_index]
    if surface then
      local found = surface.find_entities_filtered{
        area = rec.area,
        type = {"container", "logistic-container"},
        force = player.force
      }
      for _,e in ipairs(found) do
        if e ~= exclude_entity and e.valid and e.unit_number and not seen[e.unit_number]
           and e.get_inventory(defines.inventory.chest) then
          seen[e.unit_number] = true
          table.insert(chests, e)
        end
      end
    end
  end
  return chests
end

local function collect_area_chests(player)
  return get_cached_area_chests(player)
end

-- Pick the highest-capacity chest item from player's inventory (supports modded chests)
local function pick_best_chest_from_inventory(inv)
  if not inv then return nil end
  local best, best_slots = nil, -1
  for i = 1, #inv do
    local stack = inv[i]
    if stack and stack.valid_for_read and stack.count > 0 and not EXCLUDED_CHEST_ITEM_NAMES[stack.name] then
      local item_proto = stack.prototype
      if item_proto then
        local ent_proto = item_proto.place_result
        if ent_proto and ent_proto.type == "container" then
          local slots = ent_proto.get_inventory_size(defines.inventory.chest) or 0
          if slots > best_slots then
            best_slots = slots
            best = { item = stack.name, entity = ent_proto.name, slots = slots }
          end
        end
      end
    end
  end
  return best -- or nil
end

-- === Pools for single-item rule ============================================
local function insertable_count(chest, item_name)
  local inv = chest.get_inventory(defines.inventory.chest)
  if not (inv and inv.valid) then return 0 end
  if inv.can_insert{name=item_name, count=1} then
    return inv.get_insertable_count(item_name)
  end
  return 0
end

local function chest_first_item_name(chest)
  local inv = chest.get_inventory(defines.inventory.chest)
  if not (inv and inv.valid) then return nil end
  for i=1,#inv do
    local s = inv[i]
    if s and s.valid_for_read then
      return s.name
    end
  end
  return nil
end

local function is_empty_chest(chest)
  local inv = chest.get_inventory(defines.inventory.chest)
  return inv and inv.valid and inv.is_empty()
end

local function build_pools(chests)
  local pools = { by_item = {}, empty = {} }
  for _,c in ipairs(chests) do
    if is_empty_chest(c) then
      table.insert(pools.empty, c)
    else
      local it = chest_first_item_name(c)
      if it then
        pools.by_item[it] = pools.by_item[it] or {}
        if insertable_count(c, it) > 0 then
          table.insert(pools.by_item[it], c)
        end
      end
    end
  end
  return pools
end

local function add_new_target_to_pools(pools, item_name, chest)
  pools.by_item[item_name] = pools.by_item[item_name] or {}
  table.insert(pools.by_item[item_name], chest)
end

local function pop_empty_chest(pools)
  return table.remove(pools.empty)
end

local function get_non_source_target(pools, item_name, source_chest)
  local list = pools.by_item[item_name]
  if not list then return nil end
  for i=#list,1,-1 do
    local c = list[i]
    if not (c and c.valid) then
      table.remove(list, i)
    elseif c == source_chest then
      -- skip source
    else
      local can = insertable_count(c, item_name)
      if can > 0 then return c end
      table.remove(list, i)
    end
  end
  return nil
end

local function place_new_chest_for_item(pools, item_name, player, placement_areas)
  local areas = placement_areas or get_player_areas(player)
  if not areas then return nil end

  local inv = player_main_inventory(player)
  local cand = pick_best_chest_from_inventory(inv)
  if not cand then return nil end

  local pos, target_surface = first_free_grid_cell_in_areas(areas, cand.entity, player)
  if not pos or not target_surface then
    player.print({"message.areas-full"})
    return nil
  end

  if inv.remove{name=cand.item, count=1} ~= 1 then return nil end
  local chest = target_surface.create_entity{
    name = cand.entity,
    position = pos,
    force = player.force,
    player = player,
    raise_built = true
  }
  if not chest then
    inv.insert{name=cand.item, count=1}
    return nil
  end

  player.create_local_flying_text{position=pos, text={"message.placed", item_name}}
  add_new_target_to_pools(pools, item_name, chest)
  return chest
end

local function find_or_make_target(pools, item_name, source_chest, player, allow_place, placement_areas)
  local dst = get_non_source_target(pools, item_name, source_chest)
  if dst then return dst end

  local empty = pop_empty_chest(pools)
  if empty and empty ~= source_chest then
    add_new_target_to_pools(pools, item_name, empty)
    return empty
  end

  if allow_place then
    return place_new_chest_for_item(pools, item_name, player, placement_areas)
  end

  return nil
end

local function move_some(stack, dst, name)
  if not (stack and stack.valid_for_read) then return 0 end
  local count = stack.count
  if count <= 0 then return 0 end
  local inv = dst.get_inventory(defines.inventory.chest)
  if not (inv and inv.valid) then return 0 end
  local can = inv.get_insertable_count(name)
  if can <= 0 then return 0 end
  local put = math.min(count, can)

  -- Preserve metadata for stack_size=1 items (blueprints, planners, item-with-tags, etc.)
  local stack_size = (stack.prototype and stack.prototype.stack_size) or count
  if stack_size == 1 then
    local ok_dst, dst_stack = pcall(function()
      return inv.find_empty_stack({ name = name })
    end)
    if ok_dst and dst_stack and dst_stack.valid then
      local ok_transfer, transferred = pcall(function()
        return dst_stack.transfer_stack(stack)
      end)
      if ok_transfer and transferred then
        return 1
      end
    end
  end

  local inserted = inv.insert{ name = name, count = put }
  if inserted > 0 then
    stack.count = count - inserted
  end
  return inserted
end

-- === Pull from Areas into player (prefer cursor) ===========================
local function pull_from_areas_into_player_preferring_cursor(player, item_name, want_count, precollected_chests)
  if want_count <= 0 then return 0 end
  local inv = player_main_inventory(player)
  if not inv then return 0 end

  local moved = 0
  local cs = player.cursor_stack
  local holding = (cs and cs.valid_for_read and cs.name == item_name)
  local cursor_free = 0
  if holding then
    local stack_size = (cs.prototype and cs.prototype.stack_size) or 100
    cursor_free = math.max(0, stack_size - cs.count)
  end

  local chest_list = precollected_chests or collect_area_chests(player)

  for _, ch in ipairs(chest_list) do
    if moved >= want_count then break end
    local c_inv = ch.get_inventory(defines.inventory.chest)
    if not (c_inv and c_inv.valid) then goto next_chest end

    local avail = c_inv.get_item_count(item_name)
    if avail <= 0 then goto next_chest end

    -- (1) into cursor first
    if holding and cursor_free > 0 then
      local to_take = math.min(avail, cursor_free, want_count - moved)
      if to_take > 0 then
        local removed = c_inv.remove{ name = item_name, count = to_take }
        if removed > 0 then
          cs = player.cursor_stack
          if cs and cs.valid_for_read and cs.name == item_name then
            cs.count = cs.count + removed
            moved = moved + removed
            cursor_free = cursor_free - removed
            avail = avail - removed
          else
            local inserted = inv.insert{ name = item_name, count = removed }
            if inserted < removed then
              local rem = removed - inserted
              player.surface.spill_item_stack(player.position, {name=item_name, count=rem}, true, player.force, false)
            end
            moved = moved + inserted
            avail = avail - removed
          end
        end
      end
    end

    -- (2) remainder into inventory
    local remaining = want_count - moved
    if remaining > 0 and avail > 0 then
      local can_insert = inv.get_insertable_count(item_name)
      if can_insert > 0 then
        local to_try = math.min(remaining, can_insert, avail)
        if to_try > 0 then
          local inserted = inv.insert{ name = item_name, count = to_try }
          if inserted > 0 then
            c_inv.remove{ name = item_name, count = inserted }
            moved = moved + inserted
          end
        end
      end
    end

    ::next_chest::
  end

  return moved
end

local function push_from_player_into_areas(player, item_name, want_count, precollected_chests)
  if want_count <= 0 then return 0 end
  local inv = player_main_inventory(player)
  if not inv then return 0 end

  local chest_list = precollected_chests or collect_area_chests(player)
  if not chest_list or #chest_list == 0 then return 0 end

  local pools = build_pools(chest_list)
  local allow_place = player.mod_settings["sorter-mod-place-new-chest"].value
  local moved = 0

  local remaining = want_count
  while remaining > 0 do
    local dst = find_or_make_target(pools, item_name, nil, player, allow_place)
    if not dst then break end

    local dst_inv = dst.get_inventory(defines.inventory.chest)
    if not (dst_inv and dst_inv.valid) then break end

    local can_insert = dst_inv.get_insertable_count(item_name)
    if can_insert <= 0 then break end

    local stack_size = (prototypes and prototypes.item and prototypes.item[item_name] and prototypes.item[item_name].stack_size) or nil
    if stack_size == 1 then
      local src_stack = inv.find_item_stack({ name = item_name })
      local dst_stack = dst_inv.find_empty_stack({ name = item_name })
      if not (src_stack and src_stack.valid_for_read and dst_stack and dst_stack.valid) then break end
      if not dst_stack.transfer_stack(src_stack) then break end
      moved = moved + 1
      remaining = want_count - moved
    else
      local to_take = math.min(remaining, can_insert, inv.get_item_count(item_name))
      if to_take <= 0 then break end

      local removed = inv.remove{ name = item_name, count = to_take }
      if removed <= 0 then break end

      local inserted = dst_inv.insert{ name = item_name, count = removed }
      if inserted < removed then
        local returned = inv.insert{ name = item_name, count = removed - inserted }
        if returned < (removed - inserted) then
          player.surface.spill_item_stack(player.position, { name = item_name, count = removed - inserted - returned }, true, player.force, false)
        end
      end

      moved = moved + inserted
      remaining = want_count - moved
    end
  end

  local cs = player.cursor_stack
  if remaining > 0 and cs and cs.valid_for_read and cs.name == item_name then
    local cursor_remaining = math.min(cs.count, want_count)
    while cursor_remaining > 0 and moved < want_count do
      local dst = find_or_make_target(pools, item_name, nil, player, allow_place)
      if not dst then break end

      local dst_inv = dst.get_inventory(defines.inventory.chest)
      if not (dst_inv and dst_inv.valid) then break end

      local can_insert = dst_inv.get_insertable_count(item_name)
      if can_insert <= 0 then break end

      local stack_size = (cs.prototype and cs.prototype.stack_size) or cursor_remaining
      if stack_size == 1 then
        local dst_stack = dst_inv.find_empty_stack({ name = item_name })
        if not (dst_stack and dst_stack.valid) then break end
        if not dst_stack.transfer_stack(cs) then break end
        cursor_remaining = 0
        moved = moved + 1
      else
        local to_move = math.min(cursor_remaining, can_insert, want_count - moved)
        if to_move <= 0 then break end

        local inserted = dst_inv.insert{ name = item_name, count = to_move }
        if inserted <= 0 then break end

        cs.count = cs.count - inserted
        cursor_remaining = cursor_remaining - inserted
        moved = moved + inserted
      end
    end
  end
  return moved
end

ChestSorter.rect_size = rect_size
ChestSorter.ensure_player_areas = ensure_player_areas
ChestSorter.get_player_areas = get_player_areas
ChestSorter.player_main_inventory = player_main_inventory
ChestSorter.inv_plus_cursor_count = inv_plus_cursor_count
ChestSorter.collect_area_chests = collect_area_chests
ChestSorter.queue_request_refresh = queue_request_refresh
ChestSorter.pull_from_areas_into_player_preferring_cursor = pull_from_areas_into_player_preferring_cursor
ChestSorter.push_from_player_into_areas = push_from_player_into_areas

Requests = require("scripts.requests")

-- === Sorting from a source chest (hotkey Y) ================================
local function sort_from_source(player, source)
  local allow_place = player.mod_settings["sorter-mod-place-new-chest"].value
  local areas = get_player_areas(player)
  if not areas then
    player.print({"message.no-area"})
    return
  end

  -- Sort the pointed chest into the selected areas.
  local target_areas = areas
  local chests = get_cached_area_chests(player, target_areas, source)

  local pools = build_pools(chests)
  local moved_stacks = 0
  local inv = source.get_inventory(defines.inventory.chest)
  if inv and inv.valid and not inv.is_empty() then
    for i = 1, #inv do
      local stack = inv[i]
      while stack and stack.valid_for_read do
        local name = stack.name
        local dst = find_or_make_target(pools, name, source, player, allow_place, target_areas)
        if not dst then
          player.print({"message.no-target", name})
          break
        end
        local inserted = move_some(stack, dst, name)
        if inserted > 0 then moved_stacks = moved_stacks + 1 end
      end
    end
  end

  player.print({"message.done", moved_stacks})
end

-- === Trash -> Areas (event-driven) =========================================
local function dump_trash_to_areas(player)
  local areas = get_player_areas(player)
  if not areas then return end

  local trash = player.get_inventory(defines.inventory.character_trash)
  if not (trash and trash.valid and not trash.is_empty()) then return end

  local chests = collect_area_chests(player)
  if not chests or #chests == 0 then return end

  local pools = build_pools(chests)
  local allow_place = player.mod_settings["sorter-mod-place-new-chest"].value

  for i = 1, #trash do
    local stack = trash[i]
    while stack and stack.valid_for_read do
      local name = stack.name
      local dst = find_or_make_target(pools, name, nil, player, allow_place)
      if not dst then break end
      move_some(stack, dst, name)
    end
  end
end

-- === Events =================================================================
-- Y: sort from pointed chest into Areas
script.on_event("sorter-mod-sort", function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end

  local sel = player.selected
  if not is_chest_entity(sel) then
    player.print("Point at a chest and press Y to sort from it.")
    return
  end

  local areas = get_player_areas(player)
  if not areas then
    player.print({"message.no-area"})
    return
  end

  sort_from_source(player, sel)
end)

script.on_event(defines.events.on_player_created, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid) then return end
  if Requests and Requests.on_player_created then
    Requests.on_player_created(player)
  end
end)

script.on_event(defines.events.on_player_joined_game, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid) then return end
  if Requests and Requests.on_player_joined_game then
    Requests.on_player_joined_game(player)
  end
end)

-- Selection tool: set/replace area
script.on_event(defines.events.on_player_selected_area, function(e)
  if e.item ~= "sorter-mod-area-tool" then return end
  local player = game.get_player(e.player_index)
  if not (player and player.valid) then return end

  local bucket = ensure_player_areas(player)
  bucket.list = { { area = e.area, surface_index = player.surface.index } }
  mark_player_chest_cache_dirty(player)
  local w,h = rect_size(e.area)
  player.print({"message.area-set", w, h})
  queue_request_refresh(player)
end)

-- Selection tool (Shift-drag): add area
script.on_event(defines.events.on_player_alt_selected_area, function(e)
  if e.item ~= "sorter-mod-area-tool" then return end
  local player = game.get_player(e.player_index)
  if not (player and player.valid) then return end

  local bucket = ensure_player_areas(player)
  table.insert(bucket.list, { area = e.area, surface_index = player.surface.index })
  mark_player_chest_cache_dirty(player)
  local w,h = rect_size(e.area)
  player.print({"message.area-added", w, h, #bucket.list})
  queue_request_refresh(player)
end)

local function process_item_name(player, item_name)
  if not (player and player.valid and player.character) then return end
  if type(item_name) ~= "string" or item_name == "" then return end
  if Requests and Requests.process_item then
    Requests.process_item(player, item_name)
  elseif Requests and Requests.process then
    Requests.process(player)
  end
end

local function refresh_request_for_item_immediate(player, item_name)
  if not (player and player.valid and player.character) then return end
  if type(item_name) ~= "string" or item_name == "" then return end

  storage.cursor_refresh_guard = storage.cursor_refresh_guard or {}
  local guard = storage.cursor_refresh_guard[player.index]
  if guard and guard[item_name] == game.tick then return end
  storage.cursor_refresh_guard[player.index] = guard or {}
  storage.cursor_refresh_guard[player.index][item_name] = game.tick

  process_item_name(player, item_name)

  local queue = storage.requests_queue
  local bucket = queue and queue[player.index] or nil
  if bucket and not bucket.full and bucket.item_name == item_name then
    queue[player.index] = nil
  end
end

local function process_consumed_items(player, consumed_items)
  if not (player and player.valid and player.character) then return end
  if not (consumed_items and consumed_items.valid) then return end

  local seen = {}
  for i = 1, #consumed_items do
    local stack = consumed_items[i]
    if stack and stack.valid_for_read then
      local item_name = stack.name
      if item_name and not seen[item_name] then
        seen[item_name] = true
        process_item_name(player, item_name)
      end
    end
  end
end

-- Trash inventory changed: immediately dump to Areas (guard re-entrancy per tick)
script.on_event(defines.events.on_player_trash_inventory_changed, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end
  -- ensure guard table exists even if on_init/migrations didn't run yet
  storage.trash_guard = storage.trash_guard or {}
  local g = storage.trash_guard
  if g[e.player_index] == game.tick then return end
  g[e.player_index] = game.tick
  dump_trash_to_areas(player)
  queue_request_refresh(player, nil, true)
end)

script.on_event(defines.events.on_player_crafted_item, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end
  local item_stack = e.item_stack
  if item_stack and item_stack.valid_for_read then
    queue_request_refresh(player, item_stack.name)
  end
end)

script.on_event(defines.events.on_player_mined_item, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end
  local item_stack = e.item_stack
  if item_stack and item_stack.valid_for_read then
    queue_request_refresh(player, item_stack.name)
  end
end)

script.on_event(defines.events.on_picked_up_item, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end
  local item_stack = e.item_stack
  if item_stack and item_stack.valid_for_read then
    queue_request_refresh(player, item_stack.name)
  end
end)

script.on_event(defines.events.on_player_pipette, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end
  local item = e.item
  if item and item.name then
    refresh_request_for_item_immediate(player, item.name)
  else
    queue_request_refresh(player)
  end
end)

script.on_event(defines.events.on_player_used_capsule, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end
  local item = e.item
  queue_request_refresh(player, item and item.name or nil)
end)

-- Event-driven refills for requests (no timers): trigger on relevant changes
script.on_event(defines.events.on_player_main_inventory_changed, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end
  queue_request_refresh(player)
end)

script.on_event(defines.events.on_player_cursor_stack_changed, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end
  local cursor_stack = player.cursor_stack
  if cursor_stack and cursor_stack.valid_for_read then
    refresh_request_for_item_immediate(player, cursor_stack.name)
  else
    queue_request_refresh(player)
  end
end)

script.on_event(defines.events.on_built_entity, function(e)
  local player = e.player_index and game.get_player(e.player_index) or nil
  if not (player and player.valid and player.character) then return end
  cache_chest_for_player(player, e.entity or e.created_entity)
  process_consumed_items(player, e.consumed_items)
end)

script.on_event(defines.events.on_robot_built_entity, function(e)
  local entity = e.entity
  if not (entity and entity.valid) then return end
  for _, player in pairs(game.players) do
    if player and player.valid then
      cache_chest_for_player(player, entity)
    end
  end
end)

script.on_event(defines.events.script_raised_built, function(e)
  local entity = e.entity
  if not (entity and entity.valid) then return end
  for _, player in pairs(game.players) do
    if player and player.valid then
      cache_chest_for_player(player, entity)
    end
  end
end)

script.on_event(defines.events.on_player_mined_entity, function(e)
  forget_chest_from_all_caches(e.entity)
end)

script.on_event(defines.events.on_robot_mined_entity, function(e)
  forget_chest_from_all_caches(e.entity)
end)

script.on_event(defines.events.on_entity_died, function(e)
  forget_chest_from_all_caches(e.entity)
end)

script.on_event(defines.events.script_raised_destroy, function(e)
  forget_chest_from_all_caches(e.entity)
end)

script.on_event(defines.events.on_player_fast_transferred, function(e)
  local player = game.get_player(e.player_index)
  if not (player and player.valid and player.character) then return end
  queue_request_refresh(player, nil, true)
end)

script.on_event(defines.events.on_gui_click, function(e)
  if Requests and Requests.on_gui_click then
    Requests.on_gui_click(e)
  end
end)

script.on_event(defines.events.on_gui_elem_changed, function(e)
  if Requests and Requests.on_gui_elem_changed then
    Requests.on_gui_elem_changed(e)
  end
end)

script.on_event(defines.events.on_gui_text_changed, function(e)
  if Requests and Requests.on_gui_text_changed then
    Requests.on_gui_text_changed(e)
  end
end)
