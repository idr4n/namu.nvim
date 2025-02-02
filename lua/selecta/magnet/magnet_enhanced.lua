--[[ magnet.lua
Quick LSP symbol jumping with live preview and fuzzy finding.

Features:
- Fuzzy find LSP symbols
- Live preview as you move
- Auto-sized window
- Filtered by symbol kinds
- Configurable exclusions

This version includes:
1. Full integration with our enhanced `selecta` module
2. Live preview as you move through symbols
3. Proper highlight cleanup
4. Position restoration on cancel
5. Auto-sized window
6. Fuzzy finding with highlighting
7. Type annotations
8. Configurable through setup function
9. Better error handling
10. Optional keymap setup

You can enhance it further with:
1. Symbol kind icons in the display
2. More sophisticated preview behavior
3. Additional filtering options
4. Symbol documentation preview
5. Multi-select support

Usage in your Neovim config:

```lua
-- In your init.lua or similar

-- Optional: Configure selecta first
require('selecta').setup({
    window = {
        border = 'rounded',
        title_prefix = "󰍇 > ",
    }
})

-- Configure magnet
require('magnet').setup({
    -- Optional: Override default config
    includeKinds = {
        -- Add custom kinds per filetype
        python = { "Function", "Class", "Method" },
    },
    window = {
        auto_size = true,
        min_width = 50,
        padding = 2,
    },
    -- Custom highlight for preview
    highlight = "MagnetPreview",
})

-- Optional: Set up default keymaps
require('magnet').setup_keymaps()

-- Or set your own keymap
vim.keymap.set('n', 'gs', require('magnet').jump, {
    desc = "Jump to symbol"
})
```
]]

local selecta = require("selecta.selecta.selecta")
local M = {}

---@alias LSPSymbolKind string
-- ---@alias TSNode userdata
-- ---@alias vim.lsp.Client table

---@class LSPSymbol
---@field name string Symbol name
---@field kind number LSP symbol kind number
---@field range table<string, table> Symbol range in the document
---@field children? LSPSymbol[] Child symbols

---@class MagnetConfig
---@field AllowKinds table<string, string[]> Symbol kinds to include
---@field display table<string, string|number> Display configuration
---@field kindText table<string, string> Text representation of kinds
---@field kindIcons table<string, string> Icons for kinds
---@field BlockList table<string, string[]> Patterns to exclude
---@field icon string Icon for the picker
---@field highlight string Highlight group for preview
---@field highlights table<string, string> Highlight groups
---@field window table Window configuration
---@field debug boolean Enable debug logging
---@field focus_current_symbol boolean Focus the current symbol
---@field auto_select boolean Auto-select single matches
---@field row_position "center"|"top10" Window position preset
---@field multiselect table Multiselect configuration
---@field keymaps table Keymap configuration

---@class MagnetState
---@field original_win number|nil Original window
---@field original_buf number|nil Original buffer
---@field original_ft string|nil Original filetype
---@field original_pos table|nil Original cursor position
---@field preview_ns number|nil Preview namespace
---@field current_request table|nil Current LSP request ID

-- Store original window and position for preview
---@type MagnetState
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = vim.api.nvim_create_namespace("magnet_preview"),
  current_request = nil,
}

---@type MagnetConfig
M.config = {
  AllowKinds = {
    default = {
      "Function",
      "Method",
      "Class",
      "Module",
      "Property",
      "Variable",
      "Constant",
      "Enum",
      "Interface",
      "Field",
    },
    -- Filetype specific
    yaml = { "Object", "Array" },
    json = { "Module" },
    toml = { "Object" },
    markdown = { "String" },
  },
  display = {
    mode = "text", -- or "icon"
    padding = 2,
  },
  kindText = {
    Function = "function",
    Method = "method",
    Class = "class",
    Module = "module",
    Constructor = "constructor",
    Interface = "interface",
    Property = "property",
    Field = "field",
    Enum = "enum",
    Constant = "constant",
    Variable = "variable",
  },
  kindIcons = {
    File = "󰈙",
    Module = "󰏗",
    Namespace = "󰌗",
    Package = "󰏖",
    Class = "󰌗",
    Method = "󰆧",
    Property = "󰜢",
    Field = "󰜢",
    Constructor = "󰆧",
    Enum = "󰒻",
    Interface = "󰕘",
    Function = "󰊕",
    Variable = "󰀫",
    Constant = "󰏿",
    String = "󰀬",
    Number = "󰎠",
    Boolean = "󰨙",
    Array = "󰅪",
    Object = "󰅩",
    Key = "󰌋",
    Null = "󰟢",
    EnumMember = "󰒻",
    Struct = "󰌗",
    Event = "󰉁",
    Operator = "󰆕",
    TypeParameter = "󰊄",
  },
  BlockList = {
    default = {},
    -- Filetype-specific
    lua = {
      "^vim%.", -- anonymous functions passed to nvim api
      "%.%.%. :", -- vim.iter functions
      ":gsub", -- lua string.gsub
      "^callback$", -- nvim autocmds
      "^filter$",
      "^map$", -- nvim keymaps
    },
    -- python = {},
    -- rust = {}
  },
  icon = "󱠦", -- 󱠦 -  -  -- 󰚟
  highlight = "MagnetPreview",
  highlights = {
    parent = "MagnetParent",
    nested = "MagnetNested",
    style = "MagnetStyle",
  },
  window = {
    auto_size = true,
    min_width = 30,
    padding = 4,
    border = "rounded",
    show_footer = true,
    footer_pos = "right",
  },
  debug = false, -- Debug flag for both magnet and selecta
  focus_current_symbol = true, -- Add this option to control the feature
  auto_select = false,
  row_position = "top10", -- options: "center"|"top10",
  multiselect = {
    enabled = true,
    indicator = "●", -- or "✓"
    keymaps = {
      toggle = "<Tab>",
      select_all = "<C-a>",
      clear_all = "<C-l>",
    },
    max_items = nil, -- No limit by default
  },
  keymaps = {
    {
      key = "<C-o>",
      handler = function(items_or_item)
        if type(items_or_item) == "table" and items_or_item[1] then
          M.add_symbol_to_codecompanion(items_or_item, state.original_buf)
        else
          -- Single item case
          M.add_symbol_to_codecompanion({ items_or_item }, state.original_buf)
        end
      end,
      desc = "Add symbol to CodeCompanion",
    },
  },
}

---Sends current symbol context to CodeCompanion for AI assistance
---@param items table[] Array of selected items from selecta
---@param bufnr number The buffer number of the original buffer
function M.add_symbol_to_codecompanion(items, bufnr)
  if not items or #items == 0 then
    print("No items received")
    return
  end
  -- Collect all content
  local all_content = {}
  local sorted_symbols = {}
  -- First pass: collect and sort symbols by line number
  for _, item in ipairs(items) do
    table.insert(sorted_symbols, item.value)
  end
  table.sort(sorted_symbols, function(a, b)
    return a.lnum < b.lnum
  end)

  -- Second pass: collect content with no duplicates
  local last_end_lnum = -1
  for _, symbol in ipairs(sorted_symbols) do
    -- Only add if this section doesn't overlap with the previous one
    if symbol.lnum > last_end_lnum then
      local lines = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.end_lnum, false)
      table.insert(all_content, table.concat(lines, "\n"))
      last_end_lnum = symbol.end_lnum
    end
  end

  local chat = require("codecompanion").last_chat()
  if not chat then
    chat = require("codecompanion").chat()
    if not chat then
      return vim.notify("Could not create chat buffer", vim.log.levels.WARN)
    end
  end

  chat:add_buf_message({
    role = require("codecompanion.config").constants.USER_ROLE,
    content = "Here is some code from "
      .. vim.api.nvim_buf_get_name(bufnr)
      .. ":\n\n```"
      .. vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      .. "\n"
      .. table.concat(all_content, "\n\n")
      .. "\n```\n",
  })
  chat.ui:open()
end

---find_containing_symbol: Locates the symbol that contains the current cursor position
---@param items table[] Selecta items list
---@return table|nil symbol The matching symbol if found
local function find_containing_symbol(items)
  -- Cache cursor position
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local cursor_line, cursor_col = cursor_pos[1], cursor_pos[2] + 1

  -- Early exit if no items
  if #items == 0 then
    return nil
  end

  ---[local] Helper function to efficiently search through symbol ranges
  ---@diagnostic disable-next-line: redefined-local
  local function binary_search_range(items, target_line)
    local left, right = 1, #items
    while left <= right do
      local mid = math.floor((left + right) / 2)
      local symbol = items[mid].value

      if symbol.lnum <= target_line and symbol.end_lnum >= target_line then
        return mid
      elseif symbol.lnum > target_line then
        right = mid - 1
      else
        left = mid + 1
      end
    end
    return left
  end

  -- Find approximate position using binary search
  local start_index = binary_search_range(items, cursor_line)

  -- Search window size
  local WINDOW_SIZE = 10
  local start_pos = math.max(1, start_index - WINDOW_SIZE)
  local end_pos = math.min(#items, start_index + WINDOW_SIZE)

  -- Find the most specific symbol within the window
  local matching_symbol = nil
  local smallest_area = math.huge

  for i = start_pos, end_pos do
    local item = items[i]
    local symbol = item.value

    -- Quick bounds check
    if not (symbol.lnum and symbol.end_lnum and symbol.col and symbol.end_col) then
      goto continue
    end

    -- Fast range check
    if cursor_line < symbol.lnum or cursor_line > symbol.end_lnum then
      goto continue
    end

    -- Detailed position check
    local in_range = (
      (cursor_line > symbol.lnum or (cursor_line == symbol.lnum and cursor_col >= symbol.col))
      and (cursor_line < symbol.end_lnum or (cursor_line == symbol.end_lnum and cursor_col <= symbol.end_col))
    )

    if in_range then
      -- Optimize area calculation
      local area = (symbol.end_lnum - symbol.lnum + 1) * 1000 + (symbol.end_col - symbol.col)
      if area < smallest_area then
        smallest_area = area
        matching_symbol = item
      end
    end

    ::continue::
  end

  return matching_symbol
end

-- Cache for symbol ranges
local symbol_range_cache = {}

--Maintains a cache of symbol ranges for quick lookup
local function update_symbol_ranges_cache(items)
  symbol_range_cache = {}
  for i, item in ipairs(items) do
    local symbol = item.value
    if symbol.lnum and symbol.end_lnum then
      table.insert(symbol_range_cache, {
        index = i,
        start_line = symbol.lnum,
        end_line = symbol.end_lnum,
        item = item,
      })
    end
  end
  -- Sort by start line for binary search
  table.sort(symbol_range_cache, function(a, b)
    return a.start_line < b.start_line
  end)
end

---Finds index of symbol at current cursor position
---@param items SelectaItem[] The filtered items list
---@param symbol SelectaItem table The symbol to find
---@return number|nil index The index of the symbol if found
local function find_symbol_index(items, symbol)
  for i, item in ipairs(items) do
    -- Compare the essential properties to find a match
    if
      item.value.lnum == symbol.value.lnum
      and item.value.col == symbol.value.col
      and item.value.name == symbol.value.name
    then
      return i
    end
  end
  return nil
end

---Traverses syntax tree to find significant nodes for better symbol context
---@param node TSNode The treesitter node
---@param lnum number The line number (0-based)
---@return TSNode|nil
local function find_meaningful_node(node, lnum)
  if not node then
    return nil
  end
  -- [local] Helper to check if a node starts at our target line
  local function starts_at_line(n)
    local start_row = select(1, n:range())
    return start_row == lnum
  end
  -- Get the root-most node that starts at our line
  local current = node
  local target_node = node
  while current and starts_at_line(current) do
    target_node = current
    ---@diagnostic disable-next-line: undefined-field
    current = current:parent()
  end

  -- Now we have the largest node that starts at our line
  ---@diagnostic disable-next-line: undefined-field
  local type = target_node:type()

  -- Quick check if we're already at the right node type
  if type == "function_definition" then
    return node
  end

  -- Handle assignment cases (like MiniPick.stop = function())
  if type == "assignment_statement" then
    -- First try to get the function from the right side
    ---@diagnostic disable-next-line: undefined-field
    local expr_list = target_node:field("rhs")[1]
    if expr_list then
      for i = 0, expr_list:named_child_count() - 1 do
        local child = expr_list:named_child(i)
        if child and child:type() == "function_definition" then
          -- For assignments, we want to include the entire assignment
          -- not just the function definition
          return target_node
        end
      end
    end
  end

  -- Handle local function declarations
  if type == "local_function" or type == "function_declaration" then
    return target_node
  end

  -- Handle local assignments with functions
  if type == "local_declaration" then
    ---@diagnostic disable-next-line: undefined-field
    local values = target_node:field("values")
    if values and values[1] and values[1]:type() == "function_definition" then
      return target_node
    end
  end

  -- Handle method definitions
  if type == "method_definition" then
    return target_node
  end

  return target_node
end

---Handles visual highlighting of selected symbols in preview
---@param symbol table LSP symbol item
local function highlight_symbol(symbol)
  local picker_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.original_win)
  vim.api.nvim_buf_clear_namespace(0, state.preview_ns, 0, -1)

  -- Get the line content
  local bufnr = vim.api.nvim_win_get_buf(state.original_win)
  local line = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.lnum, false)[1]

  -- Find first non-whitespace character position
  local first_char_col = line:find("%S")
  if not first_char_col then
    return
  end
  first_char_col = first_char_col - 1 -- Convert to 0-based index

  -- Get node at the first non-whitespace character
  local node = vim.treesitter.get_node({
    pos = { symbol.lnum - 1, first_char_col },
    ignore_injections = false,
  })
  -- Try to find a more meaningful node
  if node then
    node = find_meaningful_node(node, symbol.lnum - 1)
  end

  if node then
    local srow, scol, erow, ecol = node:range()

    -- Create extmark for the entire node range
    vim.api.nvim_buf_set_extmark(bufnr, state.preview_ns, srow, 0, {
      end_row = erow,
      end_col = ecol,
      hl_group = M.config.highlight,
      hl_eol = true,
      priority = 1,
      strict = false, -- Allow marks beyond EOL
    })

    -- Center the view on the node
    vim.api.nvim_win_set_cursor(state.original_win, { srow + 1, scol })
    vim.cmd("normal! zz")
  end

  vim.api.nvim_set_current_win(picker_win)
end

---Filters symbols based on configured kinds and blocklist
---@param symbol LSPSymbol
---@return boolean
local function should_include_symbol(symbol)
  local kind = M.symbol_kind(symbol.kind)
  local includeKinds = M.config.AllowKinds[vim.bo.filetype] or M.config.AllowKinds.default
  local excludeResults = M.config.BlockList[vim.bo.filetype] or M.config.BlockList.default

  local include = vim.tbl_contains(includeKinds, kind)
  local exclude = vim.iter(excludeResults):any(function(pattern)
    return symbol.name:find(pattern) ~= nil
  end)

  return include and not exclude
end

---Converts LSP symbols to selecta-compatible items with proper formatting
---@param raw_symbols LSPSymbol[]
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols)
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if M.symbol_cache and M.symbol_cache.key == cache_key then
    return M.symbol_cache.items
  end

  local items = {}
  local STYLE = 2 -- TODO: move it to config later

  ---[local] Recursively processes each symbol and its children into SelectaItem format with proper indentation
  ---@param result LSPSymbol
  ---@param depth number Current depth level
  local function processSymbolResult(result, depth)
    if not result or not result.name then
      return
    end

    if not should_include_symbol(result) then
      if result.children then
        for _, child in ipairs(result.children) do
          processSymbolResult(child, depth)
        end
      end
      return
    end

    local clean_name = result.name:match("^([^%s%(]+)") or result.name
    local prefix = depth == 0 and ""
      or (
        STYLE == 1 and string.rep("  ", depth)
        or STYLE == 2 and string.rep("  ", depth - 1) .. ".."
        or STYLE == 3 and string.rep("  ", depth - 1) .. " →"
        or string.rep("  ", depth)
      )

    local display_text = prefix .. clean_name

    local item = {
      text = display_text,
      value = {
        text = clean_name,
        name = clean_name,
        kind = M.symbol_kind(result.kind),
        lnum = result.range.start.line + 1,
        col = result.range.start.character + 1,
        end_lnum = result.range["end"].line + 1,
        end_col = result.range["end"].character + 1,
      },
      icon = M.config.kindIcons[M.symbol_kind(result.kind)] or M.config.icon,
      kind = M.symbol_kind(result.kind),
      depth = depth,
    }

    table.insert(items, item)

    if result.children then
      for _, child in ipairs(result.children) do
        processSymbolResult(child, depth + 1)
      end
    end
  end

  for _, symbol in ipairs(raw_symbols) do
    processSymbolResult(symbol, 0)
  end

  M.symbol_cache = { key = cache_key, items = items }
  update_symbol_ranges_cache(items)
  return items
end

-- Cache for symbol kinds
local symbol_kinds = nil

---Converts LSP symbol kind numbers to readable strings
---@param kind number
---@return LSPSymbolKind
function M.symbol_kind(kind)
  if not symbol_kinds then
    symbol_kinds = {}
    for k, v in pairs(vim.lsp.protocol.SymbolKind) do
      if type(v) == "number" then
        symbol_kinds[v] = k
      end
    end
  end
  return symbol_kinds[kind] or "Unknown"
end

function M.clear_preview_highlight()
  if state.preview_ns and state.original_win then
    -- Get the buffer number from the original window
    local bufnr = vim.api.nvim_win_get_buf(state.original_win)
    vim.api.nvim_buf_clear_namespace(bufnr, state.preview_ns, 0, -1)
  end
end

---Performs the actual jump to selected symbol location
---@param symbol table LSP symbol
local function jump_to_symbol(symbol)
  vim.cmd.normal({ "m`", bang = true }) -- set jump mark
  vim.api.nvim_win_set_cursor(state.original_win, { symbol.lnum, symbol.col - 1 })
end

---Displays the fuzzy finder UI with symbol list
---@param selectaItems SelectaItem[]
---@param notify_opts? {title: string, icon: string}
local function show_picker(selectaItems, notify_opts)
  if #selectaItems == 0 then
    vim.notify("Current `kindFilter` doesn't match any symbols.", nil, notify_opts)
    return
  end

  -- Find containing symbol for current cursor position
  local current_symbol = find_containing_symbol(selectaItems)

  local picker_win = selecta.pick(selectaItems, {
    title = "LSP Symbols",
    offset = 0,
    fuzzy = false,
    preserve_order = true,
    window = vim.tbl_deep_extend("force", M.config.window, {
      title_prefix = M.config.icon .. " ",
      show_footer = true,
    }),
    auto_select = M.config.auto_select,
    keymaps = M.config.keymaps,
    -- TODO: Enable multiselect if configured
    multiselect = {
      enabled = true,
      indicator = M.config.multiselect and M.config.multiselect.indicator or "◉ ",
      on_select = function(selected_items)
        -- TODO: we need smart mechanis on here.
        M.clear_preview_highlight()
        if type(selected_items) == "table" and selected_items[1] then
          jump_to_symbol(selected_items[1].value)
        end
      end,
    },
    initial_index = M.config.focus_current_symbol and current_symbol and find_symbol_index(
      selectaItems,
      current_symbol
    ) or nil,
    on_select = function(item)
      M.clear_preview_highlight()
      jump_to_symbol(item.value)
    end,
    on_cancel = function()
      M.clear_preview_highlight()
      if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
        vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
      end
    end,
    on_move = function(item)
      if item then
        highlight_symbol(item.value)
      end
    end,
  })

  -- Add cleanup autocmd after picker is created
  if picker_win then
    local augroup = vim.api.nvim_create_augroup("MagnetCleanup", { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(picker_win),
      callback = function()
        M.clear_preview_highlight()
        vim.api.nvim_del_augroup_by_name("MagnetCleanup")
      end,
      once = true,
    })
  end
end

---Finds appropriate LSP client with symbol support
---@param bufnr number
---@return vim.lsp.Client|nil, string|nil
local function get_client_with_symbols(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })

  if vim.tbl_isempty(clients) then
    return nil, "No LSP client attached to buffer"
  end

  for _, client in ipairs(clients) do
    if client and client.server_capabilities and client.server_capabilities.documentSymbolProvider then
      return client, nil
    end
  end

  return nil, "No LSP client supports document symbols"
end

--Fetches symbols from LSP server
---@param bufnr number
---@param callback fun(err: any, result: any, ctx: any)
local function request_symbols(bufnr, callback)
  -- Cancel any existing request
  if state.current_request then
    local client = state.current_request.client
    local request_id = state.current_request.request_id
    -- Check if client and cancel_request are valid before calling
    if client and type(client.cancel_request) == "function" and request_id then
      client:cancel_request(request_id)
    end
    state.current_request = nil
  end

  -- Create params manually instead of using make_position_params
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
  }

  -- Get client with document symbols
  local client, err = get_client_with_symbols(bufnr)
  if err then
    callback(err, nil, nil)
    return
  end

  -- Send the request to the LSP server
  ---@diagnostic disable-next-line: undefined-field
  local success, actual_request_id
  if client then
    success, actual_request_id = client:request(
      "textDocument/documentSymbol",
      params,
      function(request_err, result, ctx)
        state.current_request = nil
        callback(request_err, result, ctx)
      end,
      bufnr
    )
  end
  -- Check if the request was successful and that the request_id is not nil
  if success and actual_request_id then
    -- Store the client and request_id
    state.current_request = {
      client = client,
      request_id = actual_request_id,
    }
  else
    -- Handle the case where the request was not successful
    callback("Request failed or request_id was nil", nil, nil)
  end

  return state.current_request
end

---Main entry point for symbol jumping functionality
function M.jump()
  -- Store current window and position
  state.original_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_get_current_buf()
  state.original_ft = vim.bo.filetype
  state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)

  vim.api.nvim_set_hl(0, M.config.highlight, {
    link = "Visual",
  })

  local notify_opts = { title = "Magnet", icon = M.config.icon }

  -- Use cached symbols if available
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if M.symbol_cache and M.symbol_cache.key == cache_key then
    show_picker(M.symbol_cache.items, notify_opts)
    return
  end

  request_symbols(state.original_buf, function(err, result, _)
    if err then
      local error_message = type(err) == "table" and err.message or err
      vim.notify("Error fetching symbols: " .. error_message, vim.log.levels.ERROR, notify_opts)
      return
    end
    if not result or #result == 0 then
      vim.notify("No results.", vim.log.levels.WARN, notify_opts)
      return
    end

    -- Convert directly to selecta items preserving hierarchy
    local selectaItems = symbols_to_selecta_items(result)

    -- Update cache
    M.symbol_cache = {
      key = cache_key,
      items = selectaItems,
    }

    show_picker(selectaItems, notify_opts)
  end)
end

---Initializes the module with user configuration
---@param opts? MagnetConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  -- Configure selecta with appropriate options
  selecta.setup({
    debug = M.config.debug,
    display = {
      mode = M.config.display.mode,
      padding = M.config.display.padding,
    },
    window = vim.tbl_deep_extend("force", {}, M.config.window),
    row_position = M.config.row_position,
  })
end

--Sets up default keymappings for symbol navigation
function M.setup_keymaps()
  vim.keymap.set("n", "<leader>ss", M.jump, {
    desc = "Jump to LSP symbol",
    silent = true,
  })
end

return M
