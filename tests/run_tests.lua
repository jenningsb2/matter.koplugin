#!/usr/bin/env lua
-- Test runner for the Matter plugin's pure-Lua modules.
--
-- Runs without KOReader. Exercises matter_markdown.lua (the Markdown to HTML
-- converter) against:
--   * Synthetic unit tests for each conversion path.
--   * A fixture response shaped exactly like Matter's API, with realistic
--     backslash-escape patterns, headings, footnotes, etc.
--   * An optional private fixture at tests/fixtures/private_response.json
--     for testing against a real Matter response without checking it in.
--
-- Usage:  lua tests/run_tests.lua
--
-- The exit code is 0 on success, 1 on any failure.

local here = arg[0]:match("(.*/)") or "./"
package.path = here .. "../?.lua;" .. package.path

local Markdown = require("matter_markdown")

local fail_count = 0
local pass_count = 0

local function fail(name, msg)
    fail_count = fail_count + 1
    io.write("FAIL  " .. name .. "\n")
    if msg then io.write("        " .. msg .. "\n") end
end

local function pass(name)
    pass_count = pass_count + 1
    io.write("PASS  " .. name .. "\n")
end

local function expect_contains(name, haystack, needles)
    for _, needle in ipairs(needles) do
        if not haystack:find(needle, 1, true) then
            fail(name, "missing: " .. needle)
            return false
        end
    end
    pass(name)
    return true
end

local function expect_excludes(name, haystack, needles)
    for _, needle in ipairs(needles) do
        if haystack:find(needle, 1, true) then
            fail(name, "unexpected: " .. needle)
            return false
        end
    end
    pass(name)
    return true
end

--------------------------------------------------------------------
-- Unit: matter_markdown
--------------------------------------------------------------------

io.write("\n-- matter_markdown unit checks --\n")

expect_contains("h1 heading",
    Markdown.toHtml("# Hello"),
    { "<h1>Hello</h1>" })

expect_contains("h4 heading from #### prefix",
    Markdown.toHtml("#### Week Two"),
    { "<h4>Week Two</h4>" })

expect_contains("bold + italic",
    Markdown.toHtml("**bold** and *italic*"),
    { "<strong>bold</strong>", "<em>italic</em>" })

expect_contains("inline code escapes HTML",
    Markdown.toHtml("Use `<div>` carefully."),
    { "<code>&lt;div&gt;</code>" })

expect_contains("link",
    Markdown.toHtml("[example](https://example.com)"),
    { '<a href="https://example.com">example</a>' })

expect_contains("image",
    Markdown.toHtml("![alt](https://example.com/x.jpg)"),
    { 'src="https://example.com/x.jpg"', 'alt="alt"', 'max-width:100%' })

expect_contains("image with title",
    Markdown.toHtml('![alt](https://example.com/x.jpg "Caption")'),
    { 'src="https://example.com/x.jpg"', 'alt="alt"', 'title="Caption"' })

expect_contains("linked image",
    Markdown.toHtml("[![](https://example.com/chart.png)](https://example.com/full)"),
    { '<img src="https://example.com/chart.png" alt=""' })

expect_excludes("linked image does not leak placeholder",
    Markdown.toHtml("[![](https://example.com/chart.png)](https://example.com/full)"),
    { "\1", "\2" })

expect_contains("image followed by text becomes separate paragraphs",
    Markdown.toHtml("![](https://example.com/chart.png)Next paragraph starts here."),
    { '<p><img src="https://example.com/chart.png" alt=""', "</p>\n<p>Next paragraph starts here.</p>" })

expect_contains("autolink",
    Markdown.toHtml("<https://example.com>"),
    { '<a href="https://example.com">https://example.com</a>' })

expect_contains("unordered list",
    Markdown.toHtml("- a\n- b\n- c"),
    { "<ul>", "<li>a</li>", "<li>b</li>", "<li>c</li>", "</ul>" })

expect_contains("blockquote",
    Markdown.toHtml("> quoted"),
    { "<blockquote>quoted</blockquote>" })

expect_contains("hr",
    Markdown.toHtml("before\n\n---\n\nafter"),
    { "<hr/>" })

expect_contains("fenced code",
    Markdown.toHtml("```python\nx = 1\n```"),
    { '<pre><code class="language-python">', "x = 1" })

expect_contains("footnote reference and definition",
    Markdown.toHtml("Cats[^1]\n\n[^1]: First note."),
    { 'class="footnote-ref"', '<section class="footnotes">', '<li id="fn-1">' })

expect_excludes("unreferenced footnote is dropped",
    Markdown.toHtml("Hi.\n\n[^orphan]: nope."),
    { 'id="fn-orphan"', '<section class="footnotes"' })

expect_contains("backslash escapes period",
    Markdown.toHtml("End\\."),
    { "End." })

expect_excludes("backslash escapes star (no bold)",
    Markdown.toHtml("\\*not bold\\*"),
    { "<strong>" })

expect_contains("html-escapes raw < and >",
    Markdown.toHtml("A <thing> here"),
    { "&lt;thing&gt;" })

--------------------------------------------------------------------
-- Heading -> TOC (mirrors matter_epub.extractToc)
--------------------------------------------------------------------

local function plain_text_from_html(s)
    if not s then return "" end
    return (s:gsub("<[^>]+>", "")
             :gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
             :gsub("&quot;", '"'):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function extract_toc(html)
    local entries = {}
    html:gsub("<[hH]([1-6])[^>]*>(.-)</[hH]%1%s*>", function(level, inner)
        local plain = plain_text_from_html(inner)
        if plain ~= "" then
            entries[#entries + 1] = { level = tonumber(level), text = plain }
        end
    end)
    return entries
end

io.write("\n-- TOC extraction --\n")

do
    local md = [[
# Top
intro

## A
text

## B
more

### B.1
nested
]]
    local toc = extract_toc(Markdown.toHtml(md))
    local labels = { "Top", "A", "B", "B.1" }
    local ok = #toc == #labels
    for i, want in ipairs(labels) do
        if not toc[i] or toc[i].text ~= want then ok = false end
    end
    if ok then
        pass("flat TOC has all 4 entries in order")
    else
        local got = {}
        for _, e in ipairs(toc) do got[#got + 1] = e.text end
        fail("flat TOC has all 4 entries in order",
            "got: [" .. table.concat(got, ", ") .. "]")
    end
end

--------------------------------------------------------------------
-- Fixture: end-to-end on a Matter-shaped response
--------------------------------------------------------------------

io.write("\n-- fixture: sample_response.json --\n")

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function extract_markdown_field(json_str)
    -- Tiny JSON-aware-ish extractor: find "markdown":" and read the string
    -- value, respecting backslash escapes.
    local key = '"markdown"%s*:%s*"'
    local _, e = json_str:find(key)
    if not e then return nil end
    local i = e + 1
    local out = {}
    while i <= #json_str do
        local c = json_str:sub(i, i)
        if c == "\\" then
            local nxt = json_str:sub(i + 1, i + 1)
            if nxt == "n" then out[#out + 1] = "\n"
            elseif nxt == "r" then out[#out + 1] = "\r"
            elseif nxt == "t" then out[#out + 1] = "\t"
            elseif nxt == '"' then out[#out + 1] = '"'
            elseif nxt == "\\" then out[#out + 1] = "\\"
            elseif nxt == "/" then out[#out + 1] = "/"
            else
                -- Preserve "\X" as-is (markdown escape inside JSON string)
                out[#out + 1] = "\\" .. nxt
            end
            i = i + 2
        elseif c == '"' then
            return table.concat(out)
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return nil
end

local function run_fixture(label, path)
    local raw = read_file(path)
    if not raw then return false, "fixture not found: " .. path end
    local md = extract_markdown_field(raw)
    if not md then return false, "no markdown field in " .. path end

    local html = Markdown.toHtml(md)
    local toc = extract_toc(html)

    io.write(string.format("    %s\n", label))
    io.write(string.format("      markdown bytes: %d\n", #md))
    io.write(string.format("      html bytes:     %d\n", #html))
    io.write(string.format("      toc entries:    %d\n", #toc))
    for i, e in ipairs(toc) do
        if i <= 10 then
            io.write(string.format("        %2d. h%d  %s\n", i, e.level, e.text))
        elseif i == 11 then
            io.write(string.format("        ... and %d more\n", #toc - 10))
            break
        end
    end
    return true, nil
end

do
    local ok, err = run_fixture("synthesized public fixture",
        here .. "fixtures/sample_response.json")
    if ok then
        pass("public fixture converts and produces TOC")
    else
        fail("public fixture converts and produces TOC", err)
    end
end

do
    local priv_path = here .. "fixtures/private_response.json"
    if read_file(priv_path) then
        local ok, err = run_fixture("private fixture (local only)", priv_path)
        if ok then
            pass("private fixture converts and produces TOC")
        else
            fail("private fixture converts and produces TOC", err)
        end
    else
        io.write("    (no private fixture present at " .. priv_path .. " - skipping)\n")
    end
end

--------------------------------------------------------------------

io.write(string.format("\n%d passed, %d failed\n", pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
