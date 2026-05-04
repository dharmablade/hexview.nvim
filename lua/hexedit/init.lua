local M = {}

local api = vim.api
local unpack = table.unpack or unpack

local default_config = {
  bytes_per_line = 16,
  open_cmd = "current",
  page_bytes = 4096,
  visible_pages = 3,
  write_chunk_size = 65536,
  search_chunk_size = 65536,
  auto_page_switch = true,
  auto_page_switch_margin = 16,
}

local config = vim.deepcopy(default_config)
local states = {}
local char_chunk_size = 1024

local function copy_defaults(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts or {})
end

local function printable(byte)
  if byte >= 32 and byte <= 126 then
    return string.char(byte)
  end

  return "."
end

local function bytes_from_string(content)
  local bytes = {}

  for index = 1, #content do
    bytes[index] = content:byte(index)
  end

  return bytes
end

local function string_from_bytes(bytes)
  if #bytes == 0 then
    return ""
  end

  local parts = {}

  for first = 1, #bytes, char_chunk_size do
    local last = math.min(first + char_chunk_size - 1, #bytes)
    parts[#parts + 1] = string.char(unpack(bytes, first, last))
  end

  return table.concat(parts)
end

local function total_piece_length(pieces)
  local length = 0

  for _, piece in ipairs(pieces) do
    length = length + piece.length
  end

  return length
end

local function merge_pieces(pieces)
  local merged = {}

  for _, piece in ipairs(pieces) do
    if piece.length > 0 then
      local last = merged[#merged]
      if last and last.source == piece.source and last.start + last.length == piece.start then
        last.length = last.length + piece.length
      else
        merged[#merged + 1] = {
          source = piece.source,
          start = piece.start,
          length = piece.length,
        }
      end
    end
  end

  return merged
end

local function split_pieces_at(pieces, offset)
  local left = {}
  local right = {}
  local consumed = 0
  local split_done = false

  for _, piece in ipairs(pieces) do
    local piece_start = consumed + 1
    local piece_end = consumed + piece.length

    if split_done then
      right[#right + 1] = {
        source = piece.source,
        start = piece.start,
        length = piece.length,
      }
    elseif offset <= piece_start then
      right[#right + 1] = {
        source = piece.source,
        start = piece.start,
        length = piece.length,
      }
      split_done = true
    elseif offset > piece_end then
      left[#left + 1] = {
        source = piece.source,
        start = piece.start,
        length = piece.length,
      }
    else
      local left_len = offset - piece_start
      local right_len = piece.length - left_len

      if left_len > 0 then
        left[#left + 1] = {
          source = piece.source,
          start = piece.start,
          length = left_len,
        }
      end

      if right_len > 0 then
        right[#right + 1] = {
          source = piece.source,
          start = piece.start + left_len,
          length = right_len,
        }
      end

      split_done = true
    end

    consumed = piece_end
  end

  return left, right
end

local function append_add_chunk(state, content)
  if content == "" then
    return nil
  end

  local start = state.add_length + 1
  local chunk = {
    start = start,
    finish = start + #content - 1,
    data = content,
  }

  state.add_chunks[#state.add_chunks + 1] = chunk
  state.add_length = chunk.finish
  return start
end

local function slice_add_data(state, start, length)
  if length <= 0 then
    return ""
  end

  local finish = start + length - 1
  local parts = {}

  for _, chunk in ipairs(state.add_chunks) do
    if chunk.finish >= start and chunk.start <= finish then
      local local_start = math.max(start, chunk.start) - chunk.start + 1
      local local_end = math.min(finish, chunk.finish) - chunk.start + 1
      parts[#parts + 1] = chunk.data:sub(local_start, local_end)
    end
  end

  return table.concat(parts)
end

local function open_source_handle(path)
  local handle, err = io.open(path, "rb")
  if not handle then
    return nil, err
  end

  return handle
end

local function close_source_handle(state)
  if state.source_handle then
    state.source_handle:close()
    state.source_handle = nil
  end
end

local function ensure_source_handle(state)
  if state.source_handle then
    return state.source_handle
  end

  local handle, err = open_source_handle(state.path)
  if not handle then
    return nil, err
  end

  state.source_handle = handle
  return handle
end

local function read_source_range(state, start, length)
  if length <= 0 then
    return ""
  end

  local handle, err = ensure_source_handle(state)
  if not handle then
    return nil, err
  end

  handle:seek("set", start - 1)
  local chunk = handle:read(length)
  if chunk == nil then
    return nil, "failed to read file chunk"
  end

  return chunk
end

local function slice_logical_data(state, start, length)
  if length <= 0 or start > state.file_length then
    return ""
  end

  local remaining = math.min(length, state.file_length - start + 1)
  local parts = {}
  local logical = 1
  local target = start

  for _, piece in ipairs(state.pieces) do
    local piece_start = logical
    local piece_end = logical + piece.length - 1

    if piece_end >= target and remaining > 0 then
      local offset = math.max(target, piece_start) - piece_start
      local take = math.min(piece.length - offset, remaining)
      local part

      if piece.source == "file" then
        part = assert(read_source_range(state, piece.start + offset, take))
      else
        part = slice_add_data(state, piece.start + offset, take)
      end

      parts[#parts + 1] = part
      remaining = remaining - take
      target = target + take

      if remaining <= 0 then
        break
      end
    end

    logical = piece_end + 1
  end

  return table.concat(parts)
end

local function replace_range(state, start, old_length, new_bytes)
  local new_string = string_from_bytes(new_bytes)
  local left, tail = split_pieces_at(state.pieces, start)
  local _, right = split_pieces_at(tail, old_length + 1)
  local pieces = {}

  for _, piece in ipairs(left) do
    pieces[#pieces + 1] = piece
  end

  if new_string ~= "" then
    local add_start = append_add_chunk(state, new_string)
    pieces[#pieces + 1] = {
      source = "add",
      start = add_start,
      length = #new_string,
    }
  end

  for _, piece in ipairs(right) do
    pieces[#pieces + 1] = piece
  end

  state.pieces = merge_pieces(pieces)
  state.file_length = total_piece_length(state.pieces)
end

local function render_hex_area(count)
  local parts = {}

  for column = 1, config.bytes_per_line do
    local value = "  "
    if column <= count then
      value = "00"
    end

    parts[#parts + 1] = value
    if column < config.bytes_per_line then
      parts[#parts + 1] = " "
      if column == config.bytes_per_line / 2 then
        parts[#parts + 1] = " "
      end
    end
  end

  return table.concat(parts)
end

local function ascii_start_col()
  return 11 + #render_hex_area(config.bytes_per_line) + 2
end

local function hex_column_for_byte(byte_index)
  local column = 11 + ((byte_index - 1) * 3)
  if byte_index > config.bytes_per_line / 2 then
    column = column + 1
  end

  return column
end

local function current_region()
  local col = api.nvim_win_get_cursor(0)[2] + 1
  if col >= ascii_start_col() then
    return "ascii"
  end

  return "hex"
end

local function page_line_count(byte_count)
  if byte_count <= 0 then
    return 1
  end

  return math.ceil(byte_count / config.bytes_per_line)
end

local function page_line_byte_count(bytes, line_index)
  local offset = (line_index - 1) * config.bytes_per_line
  local remaining = #bytes - offset

  if remaining <= 0 then
    return 0
  end

  return math.min(config.bytes_per_line, remaining)
end

local function make_line(bytes, offset, display_offset)
  local count = math.min(config.bytes_per_line, #bytes - offset + 1)
  local hex_parts = {}
  local ascii_parts = {}

  for column = 1, config.bytes_per_line do
    local byte = bytes[offset + column - 1]
    if byte then
      hex_parts[#hex_parts + 1] = string.format("%02X", byte)
      ascii_parts[#ascii_parts + 1] = printable(byte)
    else
      hex_parts[#hex_parts + 1] = "  "
      ascii_parts[#ascii_parts + 1] = " "
    end

    if column < config.bytes_per_line then
      hex_parts[#hex_parts + 1] = " "
      if column == config.bytes_per_line / 2 then
        hex_parts[#hex_parts + 1] = " "
      end
    end
  end

  return string.format("%08X  %s  |%s|", display_offset, table.concat(hex_parts), table.concat(ascii_parts))
end

local function render_page_lines(bytes, page_start)
  if #bytes == 0 then
    return { make_line({}, 1, page_start - 1) }
  end

  local lines = {}

  for offset = 1, #bytes, config.bytes_per_line do
    lines[#lines + 1] = make_line(bytes, offset, page_start + offset - 2)
  end

  return lines
end

local function extract_ascii_segment(line)
  local first = line:find("|", 1, true)
  if not first then
    return ""
  end

  local last = line:find("|", first + 1, true)
  if last then
    return line:sub(first + 1, last - 1)
  end

  return line:sub(first + 1)
end

local function extract_hex_segment(line)
  local segment = line:gsub("^%x%x%x%x%x%x%x%x%s+", "", 1)
  local pipe = segment:find("|", 1, true)
  if pipe then
    segment = segment:sub(1, pipe - 1)
  end

  return segment:gsub("[^0-9A-Fa-f]", "")
end

local function parse_ascii_line_bytes(previous_bytes, segment)
  local previous_ascii = {}
  for index = 1, #previous_bytes do
    previous_ascii[index] = printable(previous_bytes[index])
  end

  local previous_text = table.concat(previous_ascii)
  local prefix = 0
  local max_prefix = math.min(#previous_text, #segment)

  while prefix < max_prefix and previous_text:sub(prefix + 1, prefix + 1) == segment:sub(prefix + 1, prefix + 1) do
    prefix = prefix + 1
  end

  local suffix = 0
  local max_suffix = math.min(#previous_text - prefix, #segment - prefix)
  while suffix < max_suffix do
    local previous_index = #previous_text - suffix
    local current_index = #segment - suffix
    if previous_text:sub(previous_index, previous_index) ~= segment:sub(current_index, current_index) then
      break
    end
    suffix = suffix + 1
  end

  local bytes = {}
  if prefix > 0 then
    table.move(previous_bytes, 1, prefix, 1, bytes)
  end

  for index = prefix + 1, #segment - suffix do
    bytes[#bytes + 1] = segment:byte(index)
  end

  if suffix > 0 then
    local start = #previous_bytes - suffix + 1
    table.move(previous_bytes, start, #previous_bytes, #bytes + 1, bytes)
  end

  return bytes
end

local function parse_ascii_page(previous_bytes, lines)
  local bytes = {}
  local previous_lines = math.max(page_line_count(#previous_bytes), #lines)

  for line_index = 1, previous_lines do
    local segment = extract_ascii_segment(lines[line_index] or "")
    local previous_count = page_line_byte_count(previous_bytes, line_index)
    local effective_count = previous_count + (#segment - config.bytes_per_line)

    if previous_count == 0 and segment ~= "" then
      effective_count = #segment
    end

    effective_count = math.max(0, math.min(#segment, effective_count))
    segment = segment:sub(1, effective_count)

    local line_bytes = {}
    if previous_count > 0 then
      local first = (line_index - 1) * config.bytes_per_line + 1
      table.move(previous_bytes, first, first + previous_count - 1, 1, line_bytes)
    end

    local parsed = parse_ascii_line_bytes(line_bytes, segment)
    table.move(parsed, 1, #parsed, #bytes + 1, bytes)
  end

  return bytes
end

local function parse_hex_page(lines)
  local digits = {}

  for _, line in ipairs(lines) do
    digits[#digits + 1] = extract_hex_segment(line)
  end

  local stream = table.concat(digits):upper()
  local bytes = {}
  local limit = #stream - (#stream % 2)

  for index = 1, limit, 2 do
    bytes[#bytes + 1] = tonumber(stream:sub(index, index + 1), 16)
  end

  return bytes, #stream % 2 == 1
end

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end

  for index = 1, #left do
    if left[index] ~= right[index] then
      return false
    end
  end

  return true
end

local function page_count(state)
  return math.max(1, math.ceil(math.max(state.file_length, 1) / config.page_bytes))
end

local function current_page_number(state)
  return math.floor((state.page_start - 1) / config.page_bytes) + 1
end

local function visible_page_count()
  return math.max(1, math.min(3, tonumber(config.visible_pages) or 3))
end

local function page_start_for_number(page_number)
  return ((page_number - 1) * config.page_bytes) + 1
end

local function window_bounds(state)
  local first = math.floor((state.window_start - 1) / config.page_bytes) + 1
  local last = math.min(page_count(state), first + visible_page_count() - 1)
  return first, last
end

local function sync_window_to_current(state, force_reframe)
  local total = page_count(state)
  local span = visible_page_count()
  local max_first = math.max(1, total - span + 1)
  local current = current_page_number(state)
  local first, last = window_bounds(state)

  if force_reframe or current < first or current > last then
    first = math.max(1, math.min(current - 1, max_first))
  elseif current >= last and current < total then
    first = math.min(max_first, first + 1)
  elseif current <= first and current > 1 then
    first = math.max(1, first - 1)
  end

  state.window_start = page_start_for_number(first)
end

local function current_page_row_range(state)
  local first_page = math.floor((state.window_start - 1) / config.page_bytes) + 1
  local row_start = ((current_page_number(state) - first_page) * (config.page_bytes / config.bytes_per_line)) + 1
  local available = math.max(0, state.file_length - state.page_start + 1)
  local row_count = page_line_count(math.min(config.page_bytes, available))
  return row_start, row_start + row_count - 1
end

local function update_buffer_name(state)
  local page = current_page_number(state)
  local first_page, last_page = window_bounds(state)
  api.nvim_buf_set_name(state.bufnr, string.format("hex://%s [pages %d-%d, current %d/%d]", state.path, first_page, last_page, page, page_count(state)))
end

local function capture_cursor(bufnr)
  if api.nvim_get_current_buf() ~= bufnr then
    return nil
  end

  return api.nvim_win_get_cursor(0)
end

local function restore_cursor(bufnr, cursor)
  if not cursor or api.nvim_get_current_buf() ~= bufnr then
    return
  end

  local line_count = api.nvim_buf_line_count(bufnr)
  local row = math.min(cursor[1], line_count)
  local line = api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local col = math.min(cursor[2], math.max(#line - 1, 0))
  api.nvim_win_set_cursor(0, { row, col })
end

local function join_undo(bufnr)
  api.nvim_buf_call(bufnr, function()
    pcall(vim.cmd, "silent keepjumps undojoin")
  end)
end

local function clear_undo_history(bufnr)
  local undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  api.nvim_buf_set_lines(bufnr, 0, -1, false, api.nvim_buf_get_lines(bufnr, 0, -1, false))
  vim.bo[bufnr].undolevels = undolevels
  vim.bo[bufnr].modified = false
end

local function set_buffer_lines(bufnr, lines, modified, join_changes)
  local cursor = capture_cursor(bufnr)
  if join_changes then
    join_undo(bufnr)
  end

  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if modified ~= nil then
    vim.bo[bufnr].modified = modified
  end
  restore_cursor(bufnr, cursor)
end

local function load_window_bytes(state)
  local window_string = slice_logical_data(state, state.window_start, config.page_bytes * visible_page_count())
  state.window_bytes_data = bytes_from_string(window_string)
end

local function render_page(state, modified, join_changes)
  sync_window_to_current(state, false)
  load_window_bytes(state)
  state.last_lines = render_page_lines(state.window_bytes_data, state.window_start)
  state.applying = true
  set_buffer_lines(state.bufnr, state.last_lines, modified, join_changes)
  state.applying = false
  state.dirty_view = false
  update_buffer_name(state)
end

local function sync_current_page(bufnr)
  local state = states[bufnr]
  if not state or state.applying or not state.dirty_view then
    return
  end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local new_bytes
  local had_incomplete_hex = false
  local hex_bytes, incomplete = parse_hex_page(lines)
  local canonical_hex = same_lines(render_page_lines(hex_bytes, state.window_start), lines)

  if canonical_hex then
    new_bytes = hex_bytes
    had_incomplete_hex = incomplete
  elseif current_region() == "ascii" then
    new_bytes = parse_ascii_page(state.window_bytes_data, lines)
  else
    new_bytes = hex_bytes
    had_incomplete_hex = incomplete
  end

  if had_incomplete_hex then
    vim.notify("hexedit: ignored trailing incomplete hex nibble", vim.log.levels.WARN)
  end

  local old_length = #state.window_bytes_data
  replace_range(state, state.window_start, old_length, new_bytes)
  render_page(state, true, true)
end

local function configure_buffer(bufnr)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "hexedit"
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].modified = false
end

local function detach_state(bufnr)
  local state = states[bufnr]
  if state then
    close_source_handle(state)
  end

  states[bufnr] = nil
end

local function temp_output_path(path)
  return string.format("%s.hexedit.%d.tmp", path, vim.fn.getpid())
end

local function write_piece_to_handle(state, handle, piece)
  local remaining = piece.length
  local start = piece.start
  local chunk_size = config.write_chunk_size

  while remaining > 0 do
    local take = math.min(chunk_size, remaining)
    local chunk

    if piece.source == "file" then
      chunk = assert(read_source_range(state, start, take))
    else
      chunk = slice_add_data(state, start, take)
    end

    local ok, err = handle:write(chunk)
    if not ok then
      return nil, err
    end

    remaining = remaining - take
    start = start + take
  end

  return true
end

local function save_state(bufnr)
  local state = states[bufnr]
  if not state then
    return
  end

  sync_current_page(bufnr)

  local temp_path = temp_output_path(state.path)
  local output, err = io.open(temp_path, "wb")
  if not output then
    vim.notify("hexedit: failed to create temp file: " .. err, vim.log.levels.ERROR)
    return
  end

  for _, piece in ipairs(state.pieces) do
    local ok, write_err = write_piece_to_handle(state, output, piece)
    if not ok then
      output:close()
      os.remove(temp_path)
      vim.notify("hexedit: failed to write temp file: " .. write_err, vim.log.levels.ERROR)
      return
    end
  end

  output:close()
  close_source_handle(state)

  local renamed, rename_err = os.rename(temp_path, state.path)
  if not renamed then
    os.remove(temp_path)
    vim.notify("hexedit: failed to replace file: " .. tostring(rename_err), vim.log.levels.ERROR)
    ensure_source_handle(state)
    return
  end

  state.pieces = {
    {
      source = "file",
      start = 1,
      length = state.file_length,
    },
  }
  state.add_chunks = {}
  state.add_length = 0
  ensure_source_handle(state)
  render_page(state, false, false)
  vim.bo[bufnr].modified = false
  vim.notify("hexedit: wrote " .. state.path, vim.log.levels.INFO)
end

local function goto_page_start(state, new_page_start)
  local max_start = math.max(1, ((page_count(state) - 1) * config.page_bytes) + 1)
  state.page_start = math.max(1, math.min(new_page_start, max_start))
  sync_window_to_current(state, true)
  render_page(state, vim.bo[state.bufnr].modified, false)
  clear_undo_history(state.bufnr)
end

local function set_cursor_for_byte(state, absolute_byte, region)
  local target = math.max(1, math.min(absolute_byte, math.max(state.file_length, 1)))
  local page_offset = target - state.window_start
  if page_offset < 0 then
    page_offset = 0
  end

  local row = math.floor(page_offset / config.bytes_per_line) + 1
  local byte_index = (page_offset % config.bytes_per_line) + 1
  local col

  if region == "hex" then
    col = hex_column_for_byte(byte_index) - 1
  else
    col = ascii_start_col() + byte_index - 2
  end

  local line_count = api.nvim_buf_line_count(state.bufnr)
  row = math.max(1, math.min(row, line_count))
  local line = api.nvim_buf_get_lines(state.bufnr, row - 1, row, false)[1] or ""
  col = math.max(0, math.min(col, math.max(#line - 1, 0)))

  api.nvim_win_set_cursor(0, { row, col })
end

local function byte_index_for_column(col0)
  local col = col0 + 1
  if col >= ascii_start_col() then
    return math.max(1, math.min(config.bytes_per_line, col - ascii_start_col() + 1))
  end

  for byte_index = 1, config.bytes_per_line do
    local start = hex_column_for_byte(byte_index)
    local next_start = byte_index < config.bytes_per_line and hex_column_for_byte(byte_index + 1) or math.huge
    if col < next_start then
      return byte_index
    end
  end

  return config.bytes_per_line
end

local function absolute_byte_at_cursor(state, cursor)
  local byte_index = byte_index_for_column(cursor[2])
  return state.window_start + ((cursor[1] - 1) * config.bytes_per_line) + byte_index - 1
end

local function goto_byte(state, absolute_byte, region)
  sync_current_page(state.bufnr)
  local target = math.max(1, math.min(absolute_byte, math.max(state.file_length, 1)))
  local page = math.floor((target - 1) / config.page_bytes)
  goto_page_start(state, (page * config.page_bytes) + 1)
  set_cursor_for_byte(state, target, region or "ascii")
end

local function page_delta(state, delta)
  sync_current_page(state.bufnr)
  goto_page_start(state, state.page_start + (delta * config.page_bytes))
end

local function goto_page_number(state, page_number)
  sync_current_page(state.bufnr)
  local page = math.max(1, page_number)
  goto_page_start(state, ((page - 1) * config.page_bytes) + 1)
end

local function move_vertical(delta)
  local bufnr = api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state or not config.auto_page_switch then
    return false
  end

  local cursor = api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local region = current_region()
  local current_top, current_bottom = current_page_row_range(state)
  local margin = math.max(0, tonumber(config.auto_page_switch_margin) or 0)
  local down_trigger = math.max(current_top, current_bottom - margin)
  local up_trigger = math.min(current_bottom, current_top + margin)

  if delta > 0 and row >= down_trigger and current_page_number(state) < page_count(state) then
    local target = math.min(math.max(state.file_length, 1), absolute_byte_at_cursor(state, cursor) + config.bytes_per_line)
    page_delta(state, 1)
    set_cursor_for_byte(state, target, region)
    return true
  end

  if delta < 0 and row <= up_trigger and state.page_start > 1 then
    local target = math.max(1, absolute_byte_at_cursor(state, cursor) - config.bytes_per_line)
    page_delta(state, -1)
    set_cursor_for_byte(state, target, region)
    return true
  end

  return false
end

local function follow_screen_page_motion(command)
  local bufnr = api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state then
    return false
  end

  local region = current_region()
  local keys = api.nvim_replace_termcodes(command, true, false, true)

  api.nvim_feedkeys(keys, "n", false)

  vim.schedule(function()
    local current_state = states[bufnr]
    if not current_state or api.nvim_get_current_buf() ~= bufnr then
      return
    end

    local after_cursor = api.nvim_win_get_cursor(0)
    local after_absolute = absolute_byte_at_cursor(current_state, after_cursor)
    local target_page = math.floor((after_absolute - 1) / config.page_bytes) + 1

    if target_page ~= current_page_number(current_state) then
      goto_page_number(current_state, target_page)
      set_cursor_for_byte(current_state, after_absolute, region)
    end
  end)

  return true
end

local function search_query_to_bytes(query)
  if query:sub(1, 4) == "hex:" then
    local hex = query:sub(5):gsub("%s+", "")
    if hex == "" or #hex % 2 == 1 or not hex:match("^[0-9A-Fa-f]+$") then
      return nil, "invalid hex search pattern"
    end

    local bytes = {}
    for index = 1, #hex, 2 do
      bytes[#bytes + 1] = tonumber(hex:sub(index, index + 1), 16)
    end

    return string_from_bytes(bytes), "hex"
  end

  if query:sub(1, 5) == "text:" then
    return query:sub(6), "ascii"
  end

  return query, "ascii"
end

local function search_forward(state, needle, start_offset)
  local chunk_size = config.search_chunk_size
  local overlap = math.max(#needle - 1, 0)
  local offset = math.max(1, start_offset)

  while offset <= state.file_length do
    local length = math.min(chunk_size, state.file_length - offset + 1)
    local chunk = slice_logical_data(state, offset, length)
    local found = chunk:find(needle, 1, true)
    if found then
      return offset + found - 1
    end

    if offset + length > state.file_length then
      break
    end

    offset = offset + math.max(1, length - overlap)
  end

  return nil
end

local function search_backward(state, needle, start_offset)
  local chunk_size = config.search_chunk_size
  local overlap = math.max(#needle - 1, 0)
  local finish = math.min(start_offset, state.file_length)

  while finish >= 1 do
    local start = math.max(1, finish - chunk_size + 1)
    local length = finish - start + 1
    local chunk = slice_logical_data(state, start, length)
    local found_at
    local from = 1

    while true do
      local found = chunk:find(needle, from, true)
      if not found then
        break
      end
      found_at = found
      from = found + 1
    end

    if found_at then
      return start + found_at - 1
    end

    if start == 1 then
      break
    end

    finish = start + overlap - 1
  end

  return nil
end

local function perform_search(state, query, backwards)
  local needle, region_or_err = search_query_to_bytes(query)
  if not needle or needle == "" then
    vim.notify("hexedit: search query cannot be empty", vim.log.levels.ERROR)
    return
  end

  local cursor = api.nvim_win_get_cursor(0)
  local absolute = absolute_byte_at_cursor(state, cursor)
  local start = backwards and absolute - 1 or absolute + 1
  local match = backwards and search_backward(state, needle, start) or search_forward(state, needle, start)

  if not match and start > 1 and start <= state.file_length then
    match = backwards and search_backward(state, needle, state.file_length) or search_forward(state, needle, 1)
  end

  if not match then
    vim.notify("hexedit: no match for " .. query, vim.log.levels.INFO)
    return
  end

  state.last_search = {
    query = query,
    needle = needle,
    region = region_or_err == "hex" and "hex" or "ascii",
  }
  goto_byte(state, match, state.last_search.region)
end

local function prompt_search(backwards)
  local state = states[api.nvim_get_current_buf()]
  if not state then
    return
  end

  local query = vim.fn.input("Hex search: ", state.last_search and state.last_search.query or "")
  if query == nil or query == "" then
    return
  end

  perform_search(state, query, backwards)
end

local function repeat_search(backwards)
  local state = states[api.nvim_get_current_buf()]
  if not state or not state.last_search then
    vim.notify("hexedit: no previous search", vim.log.levels.WARN)
    return
  end

  perform_search(state, state.last_search.query, backwards)
end

local function create_buffer_mappings(bufnr)
  vim.keymap.set("n", "j", function()
    if not move_vertical(1) then
      vim.cmd("normal! j")
    end
  end, { buffer = bufnr, silent = true, desc = "Move down with page rollover" })

  vim.keymap.set("n", "k", function()
    if not move_vertical(-1) then
      vim.cmd("normal! k")
    end
  end, { buffer = bufnr, silent = true, desc = "Move up with page rollover" })

  vim.keymap.set("n", "<Down>", function()
    if not move_vertical(1) then
      vim.cmd("normal! <Down>")
    end
  end, { buffer = bufnr, silent = true, desc = "Move down with page rollover" })

  vim.keymap.set("n", "<Up>", function()
    if not move_vertical(-1) then
      vim.cmd("normal! <Up>")
    end
  end, { buffer = bufnr, silent = true, desc = "Move up with page rollover" })

  vim.keymap.set("n", "<C-f>", function()
    follow_screen_page_motion("<C-f>")
  end, { buffer = bufnr, silent = true, desc = "Move forward by screen page" })

  vim.keymap.set("n", "<C-b>", function()
    follow_screen_page_motion("<C-b>")
  end, { buffer = bufnr, silent = true, desc = "Move backward by screen page" })

  vim.keymap.set("n", "<PageDown>", function()
    follow_screen_page_motion("<PageDown>")
  end, { buffer = bufnr, silent = true, desc = "Move forward by screen page" })

  vim.keymap.set("n", "<PageUp>", function()
    follow_screen_page_motion("<PageUp>")
  end, { buffer = bufnr, silent = true, desc = "Move backward by screen page" })

  vim.keymap.set("n", "/", function()
    prompt_search(false)
  end, { buffer = bufnr, silent = true, desc = "Search across all pages" })

  vim.keymap.set("n", "?", function()
    prompt_search(true)
  end, { buffer = bufnr, silent = true, desc = "Search backwards across all pages" })

  vim.keymap.set("n", "n", function()
    repeat_search(false)
  end, { buffer = bufnr, silent = true, desc = "Next cross-page search result" })

  vim.keymap.set("n", "N", function()
    repeat_search(true)
  end, { buffer = bufnr, silent = true, desc = "Previous cross-page search result" })
end

local function create_autocmds(bufnr)
  local group = api.nvim_create_augroup("HexEditBuffer" .. bufnr, { clear = true })

  api.nvim_create_autocmd("TextChanged", {
    group = group,
    buffer = bufnr,
    callback = function()
      local state = states[bufnr]
      if state and not state.applying then
        state.dirty_view = true
        sync_current_page(bufnr)
      end
    end,
  })

  api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      local state = states[bufnr]
      if state and not state.applying then
        state.dirty_view = true
        sync_current_page(bufnr)
      end
    end,
  })

  api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      save_state(bufnr)
    end,
  })

  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      detach_state(bufnr)
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
end

local function open_window()
  if config.open_cmd == "current" then
    return
  end

  vim.cmd(config.open_cmd)
end

local function normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function resolve_path(path)
  if path and path ~= "" then
    return normalize_path(path)
  end

  local current = api.nvim_buf_get_name(0)
  if current == "" then
    return nil, "current buffer has no file path"
  end

  return normalize_path(current)
end

function M.open(path)
  local resolved_path, path_err = resolve_path(path)
  vim.opt.number = false
  vim.opt.relativenumber = false
  if not resolved_path then
    vim.notify("hexedit: " .. path_err, vim.log.levels.ERROR)
    return
  end

  local stat = vim.uv.fs_stat(resolved_path)
  if not stat then
    vim.notify("hexedit: failed to stat file", vim.log.levels.ERROR)
    return
  end

  open_window()
  local bufnr = api.nvim_create_buf(true, false)
  api.nvim_win_set_buf(0, bufnr)
  configure_buffer(bufnr)

  local state = {
    bufnr = bufnr,
    path = resolved_path,
    file_length = stat.size,
    pieces = {},
    add_chunks = {},
    add_length = 0,
    page_start = 1,
    window_start = 1,
    window_bytes_data = {},
    last_lines = {},
    applying = false,
    dirty_view = false,
    source_handle = nil,
  }

  if stat.size > 0 then
    state.pieces[1] = {
      source = "file",
      start = 1,
      length = stat.size,
    }
  end

  local handle, err = open_source_handle(resolved_path)
  if not handle then
    vim.notify("hexedit: failed to open file: " .. err, vim.log.levels.ERROR)
    return
  end

  state.source_handle = handle
  states[bufnr] = state
  create_autocmds(bufnr)
  create_buffer_mappings(bufnr)
  render_page(state, false, false)
  clear_undo_history(bufnr)
end

function M.write()
  save_state(api.nvim_get_current_buf())
end

function M.next_page()
  local state = states[api.nvim_get_current_buf()]
  if state then
    page_delta(state, 1)
  end
end

function M.prev_page()
  local state = states[api.nvim_get_current_buf()]
  if state then
    page_delta(state, -1)
  end
end

function M.goto_page(page_number)
  local state = states[api.nvim_get_current_buf()]
  if not state then
    return
  end

  local page = tonumber(page_number)
  if not page then
    vim.notify("hexedit: HexPage expects a page number", vim.log.levels.ERROR)
    return
  end

  goto_page_number(state, page)
end

function M.search(query)
  local state = states[api.nvim_get_current_buf()]
  if state then
    perform_search(state, query, false)
  end
end

function M.search_prev(query)
  local state = states[api.nvim_get_current_buf()]
  if state then
    perform_search(state, query, true)
  end
end

function M.setup(opts)
  if opts and opts.bytes_per_line and opts.bytes_per_line ~= 16 then
    vim.notify("hexedit: only bytes_per_line = 16 is currently supported", vim.log.levels.WARN)
    opts = vim.tbl_extend("force", {}, opts, { bytes_per_line = 16 })
  end

  copy_defaults(opts)
end

return M
