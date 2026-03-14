local typescript = {}

typescript.ts = {
  command = {"ts-node"},
  open = ".editor\n",
  close = "\04",
  block_deviders = { "// %%", "//%%" },
}

return typescript
