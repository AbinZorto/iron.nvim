-- luacheck: globals describe it assert

describe("JavaScript and TypeScript filetype definitions", function()
  it("defines default block dividers for node", function()
    local js = require("iron.fts.javascript").node

    assert.are.same({ "// %%", "//%%" }, js.block_deviders)
  end)

  it("defines default block dividers for ts-node", function()
    local ts = require("iron.fts.typescript").ts

    assert.are.same({ "// %%", "//%%" }, ts.block_deviders)
  end)

  it("maps react variants to the base JavaScript and TypeScript definitions", function()
    local fts = require("iron.fts")

    assert.are.same(fts.javascript, fts.javascriptreact)
    assert.are.same(fts.javascript, fts.jsx)
    assert.are.same(fts.typescript, fts.typescriptreact)
    assert.are.same(fts.typescript, fts.tsx)
  end)
end)
