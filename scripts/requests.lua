local Requests = {}

local GUI_BUTTON_NAME = "sorter-mod-requests-button"
local FRAME_NAME = "sorter-mod-requests-frame"
local LIST_NAME = "sorter-mod-requests-list"
local NEW_ITEM_NAME = "sorter-mod-request-new-item"
local NEW_MIN_NAME = "sorter-mod-request-new-min"
local NEW_MAX_NAME = "sorter-mod-request-new-max"
local NEW_EDITOR_NAME = "sorter-mod-request-editor"
local ADD_BUTTON_NAME = "sorter-mod-request-add"
local CLOSE_BUTTON_NAME = "sorter-mod-request-close"
local MAX_RULE_AMOUNT = 100000

local function ensure_storage()
  storage = storage or {}
  storage.requests = storage.requests or {}
  storage.requests_next_id = storage.requests_next_id or 0
  storage.requests_last_full_scan_tick = storage.requests_last_full_scan_tick or {}
end

local function ensure_bucket(player)
  ensure_storage()
  local bucket = storage.requests[player.index]
  if not bucket then
    bucket = { rules = {} }
    storage.requests[player.index] = bucket
  end
  bucket.rules = bucket.rules or {}
  return bucket
end

local function get_rules(player)
  return ensure_bucket(player).rules
end

local function to_int(value, fallback, minimum, maximum)
  local number = tonumber(value)
  if not number then return fallback end
  number = math.floor(number)
  if minimum and number < minimum then
    number = minimum
  end
  if maximum and number > maximum then
    number = maximum
  end
  return number
end

local function is_valid_item_name(item_name)
  if type(item_name) ~= "string" or item_name == "" then
    return false
  end

  if prototypes and prototypes.item then
    local ok, item_proto = pcall(function()
      return prototypes.item[item_name]
    end)
    return ok and item_proto ~= nil
  end

  return true
end

local function next_rule_id()
  ensure_storage()
  storage.requests_next_id = (storage.requests_next_id or 0) + 1
  return storage.requests_next_id
end

local function normalize_rule(rule)
  rule = rule or {}
  if not is_valid_item_name(rule.item) then
    log("Invalid item name in request rule: " .. tostring(rule.item))
    rule.item = nil
  end
  rule.min = to_int(rule.min, 0, 0, MAX_RULE_AMOUNT)
  rule.max = to_int(rule.max, rule.min, 0, MAX_RULE_AMOUNT)
  if rule.max < rule.min then
    rule.max = rule.min
  end
  return rule
end

local function normalize_bucket(bucket, preferred_rule_id)
  if not bucket then return end
  bucket.rules = bucket.rules or {}
  local cleaned = {}
  local seen_items = {}
  local seen_ids = {}

  for _, rule in ipairs(bucket.rules) do
    normalize_rule(rule)

    local rule_id = tonumber(rule.id)
    if not rule_id or seen_ids[rule_id] then
      rule_id = next_rule_id()
      rule.id = rule_id
    end
    seen_ids[rule_id] = true

    if rule.item then
      local existing_index = seen_items[rule.item]
      if existing_index then
        if preferred_rule_id and rule_id == preferred_rule_id then
          cleaned[existing_index] = rule
        end
      else
        seen_items[rule.item] = #cleaned + 1
        table.insert(cleaned, rule)
      end
    end
  end

  bucket.rules = cleaned
  bucket.rules_by_item = {}
  for _, rule in ipairs(cleaned) do
    if rule.item then
      bucket.rules_by_item[rule.item] = rule
    end
  end
end

local function find_rule_index_by_item(rules, item_name)
  for index, rule in ipairs(rules) do
    if rule.item == item_name then
      return index
    end
  end
end

local function find_rule_index_by_id(rules, rule_id)
  for index, rule in ipairs(rules) do
    if rule.id == rule_id then
      return index
    end
  end
end

local function get_selected_item_name(item_button)
  if not (item_button and item_button.valid) then return nil end

  local value = item_button.elem_value
  if type(value) == "string" and value ~= "" then
    return value
  end

  if value ~= nil then
    local ok, name = pcall(function()
      return value.name
    end)
    if ok and type(name) == "string" and name ~= "" then
      return name
    end
  end

  return nil
end

local function get_item_stack_size(item_name)
  if type(item_name) ~= "string" or item_name == "" then
    return 1
  end

  local proto = prototypes
    and prototypes.item
    and prototypes.item[item_name]

  return (proto and proto.stack_size) or 1
end

local function set_fields_to_item_stack_size(min_field, max_field, item_name)
  local stack_size = get_item_stack_size(item_name)
  if min_field then min_field.text = tostring(stack_size) end
  if max_field then max_field.text = tostring(stack_size) end
end

local function process_rule(player, chest_sorter, chests, rule)
  if not (rule and rule.item) then return end

  local have_now = chest_sorter.inv_plus_cursor_count and chest_sorter.inv_plus_cursor_count(player, rule.item) or 0
  if have_now < rule.min then
    local need = rule.min - have_now
    if need > 0 and chest_sorter.pull_from_areas_into_player_preferring_cursor then
      chest_sorter.pull_from_areas_into_player_preferring_cursor(player, rule.item, need, chests)
    end
  elseif have_now > rule.max then
    local excess = have_now - rule.max
    if excess > 0 and chest_sorter.push_from_player_into_areas then
      chest_sorter.push_from_player_into_areas(player, rule.item, excess, chests)
    end
  end
end

local function ensure_top_button(player)
  local top = player.gui.top
  if top[GUI_BUTTON_NAME] then return end
  top.add{
    type = "button",
    name = GUI_BUTTON_NAME,
    caption = {"gui.sorter-mod-requests-button"},
    tooltip = {"gui.sorter-mod-requests-button-tooltip"}
  }
end

local function destroy_frame(player)
  local frame = player.gui.screen[FRAME_NAME]
  if frame and frame.valid then
    frame.destroy()
  end
end

local function clear_children(element)
  local children = element.children
  for i = #children, 1, -1 do
    local child = children[i]
    if child and child.valid then
      child.destroy()
    end
  end
end

local function rule_row_name(prefix, rule_id)
  return prefix .. tostring(rule_id)
end

local function build_rule_row(list, rule)
  local row = list.add{type = "flow", direction = "horizontal", name = rule_row_name("sorter-mod-request-row-", rule.id)}
  local element_button = row.add{type = "choose-elem-button", name = rule_row_name("sorter-mod-request-item-", rule.id), elem_type = "item"}
  element_button.elem_value = rule.item
  row.add{type = "textfield", name = rule_row_name("sorter-mod-request-min-", rule.id), text = tostring(rule.min), numeric = true, allow_negative = false}
  row.add{type = "textfield", name = rule_row_name("sorter-mod-request-max-", rule.id), text = tostring(rule.max), numeric = true, allow_negative = false}
  row.add{type = "sprite-button", name = rule_row_name("sorter-mod-request-delete-", rule.id), sprite = "utility/trash", tooltip = {"gui.sorter-mod-delete-rule"}, style = "frame_action_button"}
end

local function refresh_list(player)
  local frame = player.gui.screen[FRAME_NAME]
  if not (frame and frame.valid) then return end

  local list = frame[LIST_NAME]
  if not (list and list.valid) then return end

  clear_children(list)

  local bucket = ensure_bucket(player)
  normalize_bucket(bucket)

  local rules = bucket.rules
  for _, rule in ipairs(rules) do
    build_rule_row(list, rule)
  end

  if #rules == 0 then
    list.add{type = "label", caption = {"gui.sorter-mod-no-rules"}}
  end
end

local function build_frame(player)
  local screen = player.gui.screen
  local frame = screen.add{
    type = "frame",
    name = FRAME_NAME,
    direction = "vertical",
    caption = {"gui.sorter-mod-requests-title"}
  }
  frame.auto_center = true

  local header = frame.add{type = "flow", direction = "horizontal"}
  header.add{type = "label", caption = {"gui.sorter-mod-requests-description"}}
  local spacer = header.add{type = "empty-widget"}
  spacer.style.horizontally_stretchable = true
  header.add{type = "sprite-button", name = CLOSE_BUTTON_NAME, sprite = "utility/close", style = "frame_action_button", tooltip = {"gui.close"}}

  local editor_title = frame.add{type = "label", caption = {"gui.sorter-mod-new-rule"}}
  editor_title.style.top_margin = 8

  local editor = frame.add{type = "flow", name = NEW_EDITOR_NAME, direction = "horizontal"}
  editor.add{type = "choose-elem-button", name = NEW_ITEM_NAME, elem_type = "item"}
  editor.add{type = "textfield", name = NEW_MIN_NAME, text = "0", numeric = true, allow_negative = false}
  editor.add{type = "textfield", name = NEW_MAX_NAME, text = "100", numeric = true, allow_negative = false}
  editor.add{type = "button", name = ADD_BUTTON_NAME, caption = {"gui.add"}}

  local list_label = frame.add{type = "label", caption = {"gui.sorter-mod-rules"}}
  list_label.style.top_margin = 8

  local scroll = frame.add{
    type = "scroll-pane",
    name = LIST_NAME,
    direction = "vertical"
  }
  scroll.style.minimal_height = 220
  scroll.style.maximal_height = 420
  scroll.style.vertically_stretchable = true

  refresh_list(player)
  player.opened = frame
end

local function toggle_gui(player)
  local frame = player.gui.screen[FRAME_NAME]
  if frame and frame.valid then
    destroy_frame(player)
    return
  end

  ensure_top_button(player)
  build_frame(player)
end

local function set_rule_from_editor(player, rules)
  local frame = player.gui.screen[FRAME_NAME]
  if not (frame and frame.valid) then return end

  local editor = frame[NEW_EDITOR_NAME]
  local item_button = editor and editor[NEW_ITEM_NAME]
  local min_field = editor and editor[NEW_MIN_NAME]
  local max_field = editor and editor[NEW_MAX_NAME]

  local item_name = get_selected_item_name(item_button)
  if not item_name then
    player.print({"gui.sorter-mod-select-item-first"})
    return
  end

  local min_value = to_int(min_field and min_field.text or 0, 0, 0, MAX_RULE_AMOUNT)
  local max_value = to_int(max_field and max_field.text or min_value, min_value, 0, MAX_RULE_AMOUNT)
  if max_value < min_value then
    max_value = min_value
  end

  local bucket = ensure_bucket(player)
  local rules = bucket.rules
  local existing_index = find_rule_index_by_item(rules, item_name)
  if existing_index then
    local rule = rules[existing_index]
    rule.item = item_name
    rule.min = min_value
    rule.max = max_value
    normalize_bucket(bucket, rule.id)
  else
    table.insert(rules, { id = next_rule_id(), item = item_name, min = min_value, max = max_value })
    normalize_bucket(bucket)
  end

  if item_button then item_button.elem_value = nil end
  if min_field then min_field.text = "0" end
  if max_field then max_field.text = "100" end
  refresh_list(player)
end

local function update_rule_from_fields(player, rule_id, refresh)
  local bucket = ensure_bucket(player)
  local rules = bucket.rules
  local index = find_rule_index_by_id(rules, rule_id)
  local rule = index and rules[index] or nil
  if not rule then return end

  local frame = player.gui.screen[FRAME_NAME]
  if not (frame and frame.valid) then return end

  local list = frame[LIST_NAME]
  local row = list and list[rule_row_name("sorter-mod-request-row-", rule.id)]
  local item_button = row and row[rule_row_name("sorter-mod-request-item-", rule.id)]
  local min_field = row and row[rule_row_name("sorter-mod-request-min-", rule.id)]
  local max_field = row and row[rule_row_name("sorter-mod-request-max-", rule.id)]

  local item_name = get_selected_item_name(item_button) or rule.item
  if type(item_name) == "string" and item_name ~= "" then
    rule.item = item_name
  else
    rule.item = nil
  end

  rule.min = to_int(min_field and min_field.text or rule.min, rule.min, 0, MAX_RULE_AMOUNT)
  rule.max = to_int(max_field and max_field.text or rule.max, rule.min, 0, MAX_RULE_AMOUNT)
  if rule.max < rule.min then
    rule.max = rule.min
  end

  normalize_bucket(bucket, rule.id)
  if refresh ~= false then
    refresh_list(player)
  end
end

local function delete_rule(player, rule_id)
  local bucket = ensure_bucket(player)
  local rules = bucket.rules
  local index = find_rule_index_by_id(rules, rule_id)
  if not index then return end
  table.remove(rules, index)
  normalize_bucket(bucket)
  refresh_list(player)
end

function Requests.init_storage()
  ensure_storage()
end

function Requests.on_init()
  ensure_storage()
end

function Requests.on_configuration_changed()
  ensure_storage()
  for _, bucket in pairs(storage.requests) do
    normalize_bucket(bucket)
  end
end

function Requests.on_player_created(player)
  if not (player and player.valid) then return end
  ensure_top_button(player)
  local bucket = ensure_bucket(player)
  normalize_bucket(bucket)
end

function Requests.on_player_joined_game(player)
  if not (player and player.valid) then return end
  ensure_top_button(player)
end

function Requests.process(player, force)
  if not (player and player.valid and player.character) then return end
  local bucket = ensure_bucket(player)

  if not bucket.rules_by_item then
    normalize_bucket(bucket)
  end

  local rules = bucket.rules
  if not rules or #rules == 0 then return end

  local chest_sorter = ChestSorter
  if not chest_sorter then return end

  local chests = chest_sorter.collect_area_chests and chest_sorter.collect_area_chests(player) or nil
  if not chests or #chests == 0 then return end

  local last_full_scan_tick = storage.requests_last_full_scan_tick[player.index]
  if last_full_scan_tick == game.tick then return end
  storage.requests_last_full_scan_tick[player.index] = game.tick

  for _, rule in ipairs(rules) do
    process_rule(player, chest_sorter, chests, rule)
  end
end

function Requests.process_item(player, item_name, force)
  if not (player and player.valid and player.character) then return end
  if type(item_name) ~= "string" or item_name == "" then return end

  local bucket = ensure_bucket(player)
  if not bucket.rules_by_item then
    normalize_bucket(bucket)
  end

  local rule = bucket.rules_by_item and bucket.rules_by_item[item_name] or nil
  if not rule then return end

  local chest_sorter = ChestSorter
  if not chest_sorter then return end

  local chests = chest_sorter.collect_area_chests and chest_sorter.collect_area_chests(player) or nil
  if not chests or #chests == 0 then return end

  process_rule(player, chest_sorter, chests, rule)
  storage.requests_last_full_scan_tick[player.index] = game.tick
end

function Requests.on_gui_click(e)
  local element = e.element
  if not (element and element.valid) then return end

  local player = game.get_player(e.player_index)
  if not (player and player.valid) then return end

  if element.name == GUI_BUTTON_NAME then
    toggle_gui(player)
    return
  end

  if element.name == CLOSE_BUTTON_NAME then
    destroy_frame(player)
    return
  end

  if element.name == ADD_BUTTON_NAME then
    set_rule_from_editor(player, get_rules(player))
    Requests.process(player, true)
    return
  end

  local delete_rule_id = element.name:match("^sorter%-mod%-request%-delete%-(%d+)$")
  if delete_rule_id then
    delete_rule(player, tonumber(delete_rule_id))
    Requests.process(player, true)
  end
end

function Requests.on_gui_elem_changed(e)
  local element = e.element
  if not (element and element.valid) then return end

  local player = game.get_player(e.player_index)
  if not (player and player.valid) then return end

  if element.name == NEW_ITEM_NAME then
    local frame = player.gui.screen[FRAME_NAME]
    local editor = frame and frame.valid and frame[NEW_EDITOR_NAME] or nil
    local item_button = editor and editor[NEW_ITEM_NAME]
    local min_field = editor and editor[NEW_MIN_NAME]
    local max_field = editor and editor[NEW_MAX_NAME]
    local item_name = get_selected_item_name(item_button)
    if item_name then
      set_fields_to_item_stack_size(min_field, max_field, item_name)
    end
    return
  end

  local rule_id = element.name:match("^sorter%-mod%-request%-item%-(%d+)$")
  if rule_id then
    local frame = player.gui.screen[FRAME_NAME]
    local list = frame and frame.valid and frame[LIST_NAME] or nil
    local rule_row = list and list[rule_row_name("sorter-mod-request-row-", tonumber(rule_id))] or nil
    local item_button = rule_row and rule_row[rule_row_name("sorter-mod-request-item-", tonumber(rule_id))]
    local min_field = rule_row and rule_row[rule_row_name("sorter-mod-request-min-", tonumber(rule_id))]
    local max_field = rule_row and rule_row[rule_row_name("sorter-mod-request-max-", tonumber(rule_id))]
    local item_name = get_selected_item_name(item_button)
    if item_name then
      set_fields_to_item_stack_size(min_field, max_field, item_name)
    end
    update_rule_from_fields(player, tonumber(rule_id))
    Requests.process(player, true)
  end
end

function Requests.on_gui_text_changed(e)
  local element = e.element
  if not (element and element.valid) then return end

  local player = game.get_player(e.player_index)
  if not (player and player.valid) then return end

  local rule_id = element.name:match("^sorter%-mod%-request%-min%-(%d+)$") or element.name:match("^sorter%-mod%-request%-max%-(%d+)$")
  if rule_id then
    update_rule_from_fields(player, tonumber(rule_id), false)
    Requests.process(player, true)
  end
end

function Requests.refresh(player)
  if not (player and player.valid) then return end
  refresh_list(player)
end

function Requests.ensure_gui(player)
  if not (player and player.valid) then return end
  ensure_top_button(player)
end

function Requests.toggle(player)
  if not (player and player.valid) then return end
  toggle_gui(player)
end

return Requests
