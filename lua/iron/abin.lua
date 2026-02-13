local M = {}

function M.setup()
  local core = require("iron.core")
  local ll = require("iron.lowlevel")

  --
  -- Helper Functions
  --

  local function ensure_open()
    local meta = vim.b[0].repl
    if not meta or not ll.repl_exists(meta) then
      local ft = ll.get_buffer_ft(0)
      meta = ll.get(ft)
    end
    if not ll.repl_exists(meta) then
      local ft = ll.get_buffer_ft(0)
      meta = core.repl_for(ft)
    end
    return meta
  end

  local function ensure_open_and_cleared()
    core.clear_repl()
    local meta = ensure_open()
    if meta == nil then
      return
    end
    local sb = vim.bo[meta.bufnr].scrollback
    vim.bo[meta.bufnr].scrollback = 1
    vim.bo[meta.bufnr].scrollback = sb
    return meta
  end

  local function clear_then(func)
    return function()
      ensure_open_and_cleared()
      func()
    end
  end

  --
  -- RELIABLE NAVIGATION HELPER
  --
  local function jump_to_cell(direction)
    local config = require("iron.config")
    local ft = vim.bo.filetype
    local dividers = config.repl_definition[ft] and config.repl_definition[ft].block_deviders

    if not dividers or #dividers == 0 then
      vim.notify("No block dividers defined for " .. ft, vim.log.levels.ERROR)
      return
    end

    local pattern = "\\(" .. table.concat(dividers, "\\|") .. "\\)"
    local flags = (direction == "up" and "bW" or "W")
    local line_nr = vim.fn.search(pattern, flags)

    if line_nr > 0 then
      vim.api.nvim_win_set_cursor(0, { line_nr, 0 })
    end
  end

  --
  -- send_top_block_then_current_block
  --
  local function send_top_block_then_current_block(clear_first)
    if clear_first then ensure_open_and_cleared() else ensure_open() end

    local original_pos = vim.api.nvim_win_get_cursor(0)

    vim.schedule(function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local first_code_line = vim.fn.search("^\\s*\\S", "W")
      if first_code_line > 0 then
        vim.api.nvim_win_set_cursor(0, { first_code_line, 0 })
      end

      vim.defer_fn(function()
        core.send_code_block()

        vim.defer_fn(function()
          vim.api.nvim_win_set_cursor(0, original_pos)
          core.send_code_block()
        end, 200)
      end, 50)
    end)
  end

  local function send_line_and_capture_output()
    local current_buf = vim.api.nvim_get_current_buf()
    local meta = ensure_open()
    if meta == nil then return end

    local tmpfile = vim.fn.tempname()

    local function send_line()
      local linenr = vim.api.nvim_win_get_cursor(0)[1] - 1
      local cur_line = vim.api.nvim_buf_get_lines(0, linenr, linenr + 1, 0)[1]
      if vim.fn.strwidth(cur_line) == 0 then return end

      local escaped_line = cur_line:gsub('"', '\\"')
      local command = string.format('!python -c "print(%s)" | tee "%s"', escaped_line, tmpfile)
      core.send(nil, command)

      vim.defer_fn(function()
        local file = io.open(tmpfile, "r")
        if not file then
          vim.notify("No output file found: " .. tmpfile, vim.log.levels.WARN)
          return
        end

        local commented_lines = {}
        for line in file:lines() do
          table.insert(commented_lines, "# " .. line)
        end
        file:close()

        if #commented_lines > 0 then
          vim.api.nvim_set_current_buf(current_buf)
          vim.api.nvim_put(commented_lines, "l", true, true)
        else
          vim.notify("Output file is empty.", vim.log.levels.WARN)
        end
      end, 500)
    end

    send_line()
  end

  local function send_selection_and_capture_output()
    local current_buf = vim.api.nvim_get_current_buf()
    local meta = ensure_open()
    if meta == nil then return end

    local tmpfile = vim.fn.tempname()
    local temp_script = vim.fn.tempname() .. ".py"

    local save_reg = vim.fn.getreg("z")
    local save_regtype = vim.fn.getregtype("z")

    vim.cmd('normal! "zy')
    local selection_text = vim.fn.getreg("z")

    vim.fn.setreg("z", save_reg, save_regtype)
    vim.cmd("normal! gv")

    if not selection_text or selection_text == "" then
      vim.notify("No text selected", vim.log.levels.WARN)
      return
    end

    vim.notify(
      "Captured: " .. string.sub(selection_text, 1, 50)
      .. (string.len(selection_text) > 50 and "..." or ""),
      vim.log.levels.INFO
    )

    local file = io.open(temp_script, "w")
    if not file then
      vim.notify("Could not create temporary script file", vim.log.levels.ERROR)
      return
    end

    file:write(selection_text)
    if not selection_text:match("\n$") then
      file:write("\n")
    end
    file:close()

    local command = string.format('!python "%s" | tee "%s"', temp_script, tmpfile)
    vim.notify("Sending command: " .. command, vim.log.levels.INFO)

    core.send(nil, command)

    local function check_output()
      local output_file = io.open(tmpfile, "r")
      if not output_file then
        vim.defer_fn(check_output, 200)
        return
      end

      local content = output_file:read("*all")
      output_file:close()

      if not content or content == "" then
        vim.defer_fn(check_output, 200)
        return
      end

      local commented_lines = {}
      for line in content:gmatch("[^\r\n]+") do
        table.insert(commented_lines, "# " .. line)
      end

      os.remove(temp_script)
      os.remove(tmpfile)

      if #commented_lines > 0 then
        vim.api.nvim_set_current_buf(current_buf)
        vim.api.nvim_put(commented_lines, "l", true, true)
        vim.notify("Output captured (" .. #commented_lines .. " lines)", vim.log.levels.INFO)
      else
        vim.notify("Output file is empty.", vim.log.levels.WARN)
      end
    end

    vim.defer_fn(check_output, 500)
  end

  local function send_top_block_then_selection_and_capture_output()
    local current_buf = vim.api.nvim_get_current_buf()
    local meta = ensure_open()
    if meta == nil then return end

    local tmpfile = vim.fn.tempname()
    local temp_script = vim.fn.tempname() .. ".py"

    local original_pos = vim.api.nvim_win_get_cursor(0)

    local save_reg = vim.fn.getreg("z")
    local save_regtype = vim.fn.getregtype("z")

    vim.cmd('normal! "zy')
    local selection_text = vim.fn.getreg("z")

    vim.fn.setreg("z", save_reg, save_regtype)
    vim.cmd("normal! gv")

    if not selection_text or selection_text == "" then
      vim.notify("No text selected", vim.log.levels.WARN)
      return
    end

    vim.schedule(function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local first_code_line = vim.fn.search("^\\s*\\S", "W")
      if first_code_line > 0 then
        vim.api.nvim_win_set_cursor(0, { first_code_line, 0 })
      end

      local config = require("iron.config")
      local ft = vim.bo.filetype
      local dividers = config.repl_definition[ft] and config.repl_definition[ft].block_deviders

      local top_block_text = ""
      if dividers and #dividers > 0 then
        local pattern = "\\(" .. table.concat(dividers, "\\|") .. "\\)"
        local end_line = vim.fn.search(pattern, "W")

        if end_line > 0 then
          local lines = vim.api.nvim_buf_get_lines(0, first_code_line - 1, end_line - 1, false)
          top_block_text = table.concat(lines, "\n")
        else
          local lines = vim.api.nvim_buf_get_lines(0, first_code_line - 1, -1, false)
          top_block_text = table.concat(lines, "\n")
        end
      else
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        top_block_text = table.concat(lines, "\n")
      end

      vim.api.nvim_win_set_cursor(0, original_pos)

      vim.notify("Combining top block with selection...", vim.log.levels.INFO)

      local file = io.open(temp_script, "w")
      if not file then
        vim.notify("Could not create temporary script file", vim.log.levels.ERROR)
        return
      end

      if top_block_text and top_block_text ~= "" then
        file:write(top_block_text)
        if not top_block_text:match("\n$") then
          file:write("\n")
        end
        file:write("\n# --- Selection starts here ---\n")
      end

      file:write(selection_text)
      if not selection_text:match("\n$") then
        file:write("\n")
      end
      file:close()

      local command = string.format('!python "%s" | tee "%s"', temp_script, tmpfile)
      vim.notify("Running combined script and capturing output...", vim.log.levels.INFO)

      core.send(nil, command)

      local function check_output()
        local output_file = io.open(tmpfile, "r")
        if not output_file then
          vim.defer_fn(check_output, 200)
          return
        end

        local content = output_file:read("*all")
        output_file:close()

        if not content or content == "" then
          vim.defer_fn(check_output, 200)
          return
        end

        local commented_lines = {}
        for line in content:gmatch("[^\r\n]+") do
          table.insert(commented_lines, "# " .. line)
        end

        os.remove(temp_script)
        os.remove(tmpfile)

        if #commented_lines > 0 then
          vim.api.nvim_set_current_buf(current_buf)
          vim.api.nvim_put(commented_lines, "l", true, true)
          vim.notify(
            "Combined script executed, output captured (" .. #commented_lines .. " lines)",
            vim.log.levels.INFO
          )
        else
          vim.notify("Output file is empty.", vim.log.levels.WARN)
        end
      end

      vim.defer_fn(check_output, 500)
    end)
  end

  local function current_line_is_blank()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local current_line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
    return current_line:match("^%s*$")
  end

  local function is_line_before_blank_or_first_in_file()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if row == 1 then
      return true
    end
    local previous_line = vim.api.nvim_buf_get_lines(0, row - 2, row - 1, false)[1]
    return previous_line:match("^%s*$")
  end

  local function open_cells_picker()
    local ok = pcall(require, "telescope.pickers")
    if not ok then
      vim.notify("Telescope is not available", vim.log.levels.WARN)
      return
    end

    local config = require("iron.config")
    local ft = vim.bo.filetype
    local dividers = config.repl_definition[ft] and config.repl_definition[ft].block_deviders or {}
    if #dividers == 0 then
      vim.notify("No iron dividers defined for " .. ft, vim.log.levels.WARN)
      return
    end

    local items = {}
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      for _, div in ipairs(dividers) do
        if line:find(div, 1, true) then
          local cleaned = line:gsub(vim.pesc(div), "")
          cleaned = cleaned:gsub("^%s*", ""):gsub("%s*$", "")
          table.insert(items, { lnum = i, text = line, display = cleaned })
          break
        end
      end
    end

    if #items == 0 then
      vim.notify("No iron cells found", vim.log.levels.INFO)
      return
    end

    local rev = {}
    for i = #items, 1, -1 do
      table.insert(rev, items[i])
    end
    items = rev

    local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
    local nearest_index = 1
    local nearest_dist = math.huge
    for i, item in ipairs(items) do
      local dist = math.abs(item.lnum - cursor_row)
      if dist < nearest_dist then
        nearest_dist = dist
        nearest_index = i
      end
    end

    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local entry_display = require("telescope.pickers.entry_display")
    local previewers = require("telescope.previewers")
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local displayer = entry_display.create({
      separator = " ",
      items = {
        { width = 4 },
        { remaining = true },
      },
    })

    pickers.new({}, {
      prompt_title = "Iron Cells",
      default_selection_index = nearest_index,
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          return {
            value = item,
            ordinal = item.text,
            display = function(entry)
              return displayer({
                { tostring(entry.lnum), "LineNr" },
                entry.value.display or entry.value.text,
              })
            end,
            lnum = item.lnum,
            path = vim.api.nvim_buf_get_name(0),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Cell Preview",
        define_preview = function(self, entry)
          if not entry.path or entry.path == "" then
            return
          end
          local lnum = entry.lnum or (entry.value and entry.value.lnum) or 1
          previewers.buffer_previewer_maker(entry.path, self.state.bufnr, {
            bufname = self.state.bufname,
            winid = self.state.winid,
            callback = function()
              if not vim.api.nvim_buf_is_valid(self.state.bufnr) then return end
              local last = vim.api.nvim_buf_line_count(self.state.bufnr)
              local target = math.max(1, math.min(lnum, last))
              if vim.api.nvim_win_is_valid(self.state.winid) then
                vim.api.nvim_win_call(self.state.winid, function()
                  vim.fn.winrestview({ topline = target, lnum = target, col = 0 })
                end)
                vim.api.nvim_buf_add_highlight(self.state.bufnr, -1, "CursorLine", target - 1, 0, -1)
              end
            end,
          })
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        local function jump()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and entry.lnum then
            vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
          end
        end
        map("i", "<CR>", jump)
        map("n", "<CR>", jump)
        return true
      end,
    }):find()
  end

  --
  -- Keymaps
  --

  vim.keymap.set("n", "<leader>icm", clear_then(function() core.run_motion("send_motion") end),
    { desc = "clear => send motion" })
  vim.keymap.set("v", "<leader>icv", clear_then(function() core.send(nil, core.mark_visual()) end),
    { desc = "clear => send visual" })
  vim.keymap.set("n", "<leader>icf", clear_then(core.send_file), { desc = "clear => send file" })
  vim.keymap.set("n", "<leader>icl", clear_then(core.send_line), { desc = "clear => send line" })
  vim.keymap.set("n", "<leader>icp", clear_then(core.send_paragraph),
    { desc = "clear => send paragraph" })
  vim.keymap.set("n", "<leader>icb", clear_then(core.send_code_block),
    { desc = "clear => send block" })
  vim.keymap.set("n", "<leader>icn", clear_then(function() core.send_code_block(true) end),
    { desc = "clear => send block and move" })
  vim.keymap.set("n", "<leader>ist", function() send_top_block_then_current_block(false) end,
    { desc = "run top block then current block" })
  vim.keymap.set("n", "<leader>ict", function() send_top_block_then_current_block(true) end,
    { desc = "clear => run top block then current" })

  vim.keymap.set("n", "<leader>icc", ensure_open_and_cleared, { desc = "clear repl" })
  vim.keymap.set("n", "<leader>il", send_line_and_capture_output,
    { desc = "send line and capture output" })
  vim.keymap.set("v", "<leader>il", send_selection_and_capture_output,
    { desc = "send selection and capture output" })
  vim.keymap.set("v", "<leader>it", send_top_block_then_selection_and_capture_output,
    { desc = "send top block then selection and capture output" })

  vim.keymap.set("n", "<leader>ii", open_cells_picker, { desc = "Iron cells (Telescope)" })

  vim.keymap.set("n", "<leader>ij", function()
    for _ = 1, vim.v.count1 do
      jump_to_cell("down")
    end
  end, { desc = "iron - next cell" })
  vim.keymap.set("n", "<leader>ik", function()
    for _ = 1, vim.v.count1 do
      jump_to_cell("up")
    end
  end, { desc = "iron - previous cell" })

  vim.keymap.set("n", "<leader>ib", function()
    local ft = vim.bo.filetype
    local divider = require("iron.config").repl_definition[ft].block_deviders[1]
    if not current_line_is_blank() then
      vim.api.nvim_feedkeys("}", "n", false)
      vim.defer_fn(function()
        if not current_line_is_blank() then
          vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("o<Esc>", true, false, true), "n", false
          )
        end
        local keys = vim.api.nvim_replace_termcodes(
          "o" .. divider .. "<CR><Esc>cc<Esc>", true, false, true
        )
        vim.api.nvim_feedkeys(keys, "n", false)
      end, 0)
    else
      if not is_line_before_blank_or_first_in_file() then
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("o<Esc>", true, false, true), "n", false
        )
      end
      local keys = vim.api.nvim_replace_termcodes(
        "i" .. divider .. "<CR><Esc>cc<Esc>", true, false, true
      )
      vim.api.nvim_feedkeys(keys, "n", false)
    end
  end, { desc = "iron - insert block divider" })

  --
  -- Plugin Setup
  --

  core.setup {
    config = {
      scratch_repl = true,
      repl_definition = {
        fish = { command = { "fish" }, block_deviders = { "#%%" } },
        sh = { command = { "bash" }, block_deviders = { "#%%" } },
        lua = { command = { "lua" }, block_deviders = { "-- %%", "--%%" } },
        python = {
          command = { "ipython", "--no-autoindent" },
          format = function(lines, extras)
            local result = require("iron.fts.common").bracketed_paste_python(lines, extras)
            local filtered = vim.tbl_filter(
              function(line) return not string.match(line, "^%s*#") end,
              result
            )
            return filtered
          end,
          block_deviders = { "#%%", "# %%" },
        },
      },
      repl_filetype = function(_, ft)
        return ft
      end,
      repl_open_cmd = "vertical split",
    },
    keymaps = {
      toggle_repl = "<space>ir",
      restart_repl = "<space>iR",
      send_motion = "<space>ism",
      visual_send = "<space>isv",
      send_file = "<space>isf",
      send_line = "<space>isl",
      send_paragraph = "<space>isp",
      send_until_cursor = "<space>isu",
      send_code_block = "<space>isb",
      send_code_block_and_move = "<space>isn",
      mark_motion = "<space>imm",
      mark_visual = "<space>imv",
      remove_mark = "<space>imd",
      send_mark = "<space>imr",
      cr = "<space>is<cr>",
      interrupt = "<space>iq",
      exit = "<space>ix",
    },
    highlight = {
      italic = true,
    },
    ignore_blank_lines = true,
  }
end

return M
