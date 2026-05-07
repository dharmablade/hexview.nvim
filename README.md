# hexedit.nvim

`hexedit.nvim` opens a binary file in a dedicated Neovim buffer with synchronized hex and ASCII columns. This version uses paging and a disk-backed piece table so large files do not need to live entirely in RAM.

## Features

- Separate hex view buffer opened from a file path or the current file.
- Fixed-width hex + ASCII layout for binary inspection.
- Edit bytes through two-digit hex pairs or visible ASCII characters.
- A sliding 2-3 page window that keeps previous/current/next pages loaded as you move.
- Automatic rollover movement plus `:HexPageNext`, `:HexPagePrev`, and `:HexPage {n}`.
- Buffer-local `<C-f>`, `<C-b>`, `<PageDown>`, and `<PageUp>` keep their normal Neovim screen-page feel and load more pages when needed.
- File-wide search via `/`, `?`, `n`, `N`, `:HexSearch`, and `:HexSearchPrev`.
- Disk-backed piece table keeps large-file RAM usage far lower than a full in-memory copy.
- Saving streams data out in chunks instead of rebuilding the whole file buffer in memory.
- Standard plugin layout that works with `lazy.nvim` and Neovim 0.12 package loading.

## Installation

### lazy.nvim

```lua
{
  "dharmablade/hexedit.nvim",
  opts = {
    open_cmd = "current",
    bytes_per_line = 16,
    page_bytes = 4096,
    visible_pages = 3,
  },
}
```

### Neovim 0.12 built-in plugin manager

```lua
vim.pack.add({
  { src = "https://github.com/dharmablade/hexedit.nvim" },
})

require("hexedit").setup({
  open_cmd = "current",
  bytes_per_line = 16,
  page_bytes = 4096,
  visible_pages = 3,
})
```

## Usage

Open the current file:

```vim
:HexView
```

Or just use "-b" flag:

```bash
nvim -b /path/to/file
```

Open a specific file:

```vim
:HexView path/to/file.bin
```

Move to the next or previous page:

```vim
:HexPageNext
:HexPagePrev
```

Jump to a specific page:

```vim
:HexPage 12
```

Search across all pages:

```vim
/needle
?needle
:HexSearch needle
:HexSearchPrev needle
```

Search for raw bytes:

```vim
:HexSearch hex:4D5A90
```

Write the edited bytes back to disk:

```vim
:write
```

or:

```vim
:HexWrite
```

## Configuration

```lua
require("hexedit").setup({
  open_cmd = "current", -- Default. Use a split command like "vsplit" if you prefer.
  bytes_per_line = 16, -- Optimized for the fixed layout in this plugin.
  page_bytes = 4096, -- Number of bytes shown and edited per page.
  visible_pages = 3, -- Shows previous/current/next pages when available.
  write_chunk_size = 65536, -- Streaming chunk size used during saves.
  search_chunk_size = 65536, -- Streaming chunk size used during file-wide search.
  auto_page_switch = true, -- Roll j/k and arrow movement across page boundaries.
})
```

## Notes

- Structural formatting is restored automatically after page edits.
- Non-printable bytes are shown as `.` in the ASCII column.
- The visible buffer shows up to three adjacent pages at once and slides forward/backward as you enter an edge page.
- `<C-f>`/`<C-b>` and PageDown/PageUp keep their usual Neovim-style screen-page movement while still updating the loaded page window.
- ASCII-side insertion and deletion are applied within the visible window when you leave insert mode or make a normal-mode text change.
- Hex-side insertion and deletion work by editing the raw hex digits directly. One byte is one hex pair, so deleting a byte there means deleting both digits.
- A trailing single hex nibble is ignored until it is completed.
- The original file stays on disk and edited spans are tracked in a piece table until save.
- Prefix search queries with `hex:` to search for raw bytes instead of text.
