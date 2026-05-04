if vim.g.loaded_hexedit_plugin == 1 then
  return
end

vim.g.loaded_hexedit_plugin = 1

if vim.bo.binary then
	require("hexedit").open()
end

vim.api.nvim_create_user_command("HexView", function(command)
  require("hexedit").open(command.args ~= "" and command.args or nil)
end, {
  nargs = "?",
  complete = "file",
  desc = "Open a binary file in an editable hex view",
})

vim.api.nvim_create_user_command("HexWrite", function()
  require("hexedit").write()
end, {
  desc = "Write the current hex view back to disk",
})

vim.api.nvim_create_user_command("HexPageNext", function()
  require("hexedit").next_page()
end, {
  desc = "Open the next hex page",
})

vim.api.nvim_create_user_command("HexPagePrev", function()
  require("hexedit").prev_page()
end, {
  desc = "Open the previous hex page",
})

vim.api.nvim_create_user_command("HexPage", function(command)
  require("hexedit").goto_page(command.args)
end, {
  nargs = 1,
  desc = "Jump to a hex page number",
})

vim.api.nvim_create_user_command("HexSearch", function(command)
  require("hexedit").search(command.args)
end, {
  nargs = "+",
  desc = "Search across all hex pages",
})

vim.api.nvim_create_user_command("HexSearchPrev", function(command)
  require("hexedit").search_prev(command.args)
end, {
  nargs = "+",
  desc = "Search backwards across all hex pages",
})
