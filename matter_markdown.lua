-- Minimal Markdown -> HTML converter for Matter article bodies.
-- Handles: ATX headings, paragraphs, fenced/indented code, blockquotes,
-- ordered/unordered lists (with nesting up to 4 levels), horizontal rules,
-- bold/italic/strikethrough, inline code, links, images, autolinks,
-- GFM-style footnotes ([^id] references and [^id]: definitions).
-- Not a full CommonMark implementation — calibrated for clean article bodies
-- that the Matter extractor produces.

local Markdown = {}

local function escape_html(s)
    return (s
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function escape_attr(s)
    return (s
        :gsub("&", "&amp;")
        :gsub('"', "&quot;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;"))
end

-- Token-based inline parser. We first pull out code spans (their contents are
-- HTML-escaped but not markdown-processed), then escape the remaining text,
-- then apply markdown patterns on the escaped text.
local function process_inline(text, ctx)
    if not text or text == "" then return "" end
    ctx = ctx or {}

    local placeholders = {}
    local function stash(html)
        placeholders[#placeholders + 1] = html
        return "\1" .. #placeholders .. "\2"
    end

    -- Inline code: `...` (single backtick) or ``...`` (double, allows embedded `)
    text = text:gsub("``(.-)``", function(code)
        return stash("<code>" .. escape_html(code) .. "</code>")
    end)
    text = text:gsub("`([^`\n]+)`", function(code)
        return stash("<code>" .. escape_html(code) .. "</code>")
    end)

    -- CommonMark backslash escapes: \X where X is ASCII punctuation becomes
    -- a literal X. Stashed so X bypasses later markdown patterns (e.g. \* won't
    -- start emphasis, \[ won't start a link, \. won't be touched, etc.).
    text = text:gsub("\\([%p])", function(c)
        return stash(escape_html(c))
    end)

    -- Footnote references: [^id] -> <sup><a href="#fn-id">N</a></sup>
    -- Must run BEFORE link/image regexes so [^id] isn't mistaken for a link.
    if ctx.footnotes then
        text = text:gsub("%[%^([^%]]+)%]", function(id)
            local fn = ctx.footnotes[id]
            if not fn then return "[^" .. id .. "]" end
            local refnum = fn.index
            -- Track reference occurrence count for unique backref ids.
            fn.refs = (fn.refs or 0) + 1
            local ref_suffix = fn.refs > 1 and ("-" .. fn.refs) or ""
            local ref_id = "fnref-" .. fn.slug .. ref_suffix
            local fn_id  = "fn-" .. fn.slug
            return stash(string.format(
                '<sup class="footnote-ref" id="%s"><a href="#%s">%d</a></sup>',
                escape_attr(ref_id), escape_attr(fn_id), refnum))
        end)
    end

    local function parse_link_target(target)
        target = target:gsub("^%s+", ""):gsub("%s+$", "")
        local url, title = target:match('^(%S+)%s+"(.-)"%s*$')
        if not url then
            url, title = target:match("^(%S+)%s+'(.-)'%s*$")
        end
        if not url then
            url = target:match("^(%S+)%s*$")
        end
        return url, title
    end

    local function render_image(alt, target)
        local url, title = parse_link_target(target)
        if not url then return nil end
        local title_attr = title and title ~= ""
            and string.format(' title="%s"', escape_attr(title))
            or ""
        return string.format('<img src="%s" alt="%s"%s style="max-width:100%%; height:auto;"/>',
            escape_attr(url), escape_attr(alt), title_attr)
    end

    -- Linked images: [![alt](image-url "title")](target-url). Keep only the
    -- image in the reading output; EPUB generation embeds the image itself.
    text = text:gsub("%[!%[([^%]]*)%]%(([^%)]+)%)%]%(([^%)]+)%)", function(alt, img_target)
        return stash(render_image(alt, img_target) or "")
    end)

    -- Images: ![alt](url "optional title") — stash before links so the
    -- leading ! isn't lost.
    text = text:gsub("!%[([^%]]*)%]%(([^%)]+)%)", function(alt, img_target)
        return stash(render_image(alt, img_target) or "")
    end)

    -- Links: [text](url)
    text = text:gsub("%[([^%]]+)%]%(([^)%s]+)%s*%)", function(label, url)
        return stash(string.format('<a href="%s">%s</a>',
            escape_attr(url), escape_html(label)))
    end)

    -- Autolinks: <http://...>
    text = text:gsub("<((https?://[^>]+))>", function(_, url)
        return stash(string.format('<a href="%s">%s</a>',
            escape_attr(url), escape_html(url)))
    end)

    -- Escape what's left (placeholders use \1...\2, won't collide with &<>")
    text = escape_html(text)

    -- Emphasis on escaped text.
    -- Strikethrough: ~~text~~
    text = text:gsub("~~(.-)~~", "<del>%1</del>")
    -- Bold: **text** or __text__
    text = text:gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
    text = text:gsub("__(.-)__",     "<strong>%1</strong>")
    -- Italic: *text* or _text_ (avoid matching ** by requiring non-* on edges)
    text = text:gsub("([^%*])%*([^%*\n][^\n]-)%*", "%1<em>%2</em>")
    text = text:gsub("^%*([^%*\n][^\n]-)%*", "<em>%1</em>")
    text = text:gsub("([^_])_([^_\n][^\n]-)_", "%1<em>%2</em>")
    text = text:gsub("^_([^_\n][^\n]-)_",      "<em>%1</em>")

    -- Restore placeholders
    text = text:gsub("\1(%d+)\2", function(n)
        return placeholders[tonumber(n)] or ""
    end)

    return text
end

-- Split markdown into logical lines. Tabs -> 4 spaces for simple indent math.
local function split_lines(md)
    md = md:gsub("\r\n", "\n"):gsub("\r", "\n")
    md = md:gsub("\t", "    ")
    local lines = {}
    for line in (md .. "\n"):gmatch("([^\n]*)\n") do
        local linked_img, linked_rest =
            line:match("^(%[!%[[^%]]*%]%([^%)]+%)%]%([^%)]+%))(%S.*)$")
        local img, img_rest =
            line:match("^(!%[[^%]]*%]%([^%)]+%))(%S.*)$")
        if linked_img and linked_rest and linked_rest ~= "" then
            lines[#lines + 1] = linked_img
            lines[#lines + 1] = ""
            lines[#lines + 1] = linked_rest
        elseif img and img_rest and img_rest ~= "" then
            lines[#lines + 1] = img
            lines[#lines + 1] = ""
            lines[#lines + 1] = img_rest
        else
            lines[#lines + 1] = line
        end
    end
    return lines
end

local function is_blank(line)
    return line == nil or line:match("^%s*$") ~= nil
end

local function strip_trailing(line)
    return (line:gsub("%s+$", ""))
end

-- Match an unordered list item: returns (indent_spaces, marker, content) or nil
local function match_ul(line)
    local indent, _, content = line:match("^(%s*)([%-%*%+])%s+(.*)$")
    if indent then return #indent, content end
    return nil
end

-- Match an ordered list item: returns (indent_spaces, content) or nil
local function match_ol(line)
    local indent, _, content = line:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
    if indent then return #indent, content end
    return nil
end

local function match_heading(line)
    local hashes, rest = line:match("^(#+)%s+(.*)$")
    if hashes and #hashes >= 1 and #hashes <= 6 then
        rest = rest:gsub("%s+#+%s*$", "")  -- trim optional trailing #'s
        return #hashes, rest
    end
    return nil
end

local function match_hr(line)
    local s = line:gsub("%s", "")
    if s:match("^%-%-%-+$") or s:match("^%*%*%*+$") or s:match("^___+$") then
        return true
    end
    return false
end

local function match_blockquote(line)
    local content = line:match("^%s*>%s?(.*)$")
    return content
end

local function match_fence(line)
    local fence, info = line:match("^%s*(```+)%s*([^\n]*)$")
    if not fence then fence, info = line:match("^%s*(~~~+)%s*([^\n]*)$") end
    if fence then return fence, info or "" end
    return nil
end

-- Slugify a footnote id for use in an HTML anchor.
local function slugify_fn_id(id)
    local s = id:lower():gsub("[^%w%-]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
    if s == "" then s = "x" end
    return s
end

-- Pre-pass: extract footnote definitions, leaving non-footnote lines behind.
-- Returns (filtered_lines, footnotes_map, footnotes_order).
-- A definition is `[^id]: first line content`. Subsequent indented (>=4 spaces)
-- or blank-then-indented lines are treated as continuation of the same note.
local function extract_footnotes(lines)
    local fns = {}
    local order = {}
    local out_lines = {}
    local i = 1
    while i <= #lines do
        local line = lines[i]
        local id, first = line:match("^%s*%[%^([^%]]+)%]:%s*(.*)$")
        if id then
            local content = { first }
            i = i + 1
            -- Consume continuation lines: indented (>=4 spaces) or blank
            -- followed by indented. Stop at the next non-indented non-blank line.
            while i <= #lines do
                local l = lines[i]
                if l:match("^%s*$") then
                    -- Look ahead for indented continuation
                    local j = i + 1
                    while j <= #lines and lines[j]:match("^%s*$") do j = j + 1 end
                    if j <= #lines and lines[j]:match("^    ") then
                        content[#content + 1] = ""
                        i = i + 1
                    else
                        break
                    end
                elseif l:match("^    ") then
                    content[#content + 1] = l:sub(5)
                    i = i + 1
                else
                    break
                end
            end
            local fn = {
                index = #order + 1,
                slug = slugify_fn_id(id),
                content = table.concat(content, "\n"),
                refs = 0,
            }
            fns[id] = fn
            order[#order + 1] = fn
        else
            out_lines[#out_lines + 1] = line
            i = i + 1
        end
    end
    return out_lines, fns, order
end

-- Convert markdown to HTML. Returns a string of HTML (no <html> wrapper).
function Markdown.toHtml(md)
    if not md or md == "" then return "" end

    local raw_lines = split_lines(md)
    local lines, footnotes, fn_order = extract_footnotes(raw_lines)
    local ctx = { footnotes = footnotes }
    local out = {}

    -- List state: stack of { type = "ul"|"ol", indent = N }
    local list_stack = {}
    local function close_lists_to(depth)
        while #list_stack > depth do
            local top = table.remove(list_stack)
            out[#out + 1] = top.type == "ol" and "</ol>" or "</ul>"
        end
    end

    -- Paragraph buffer
    local para = {}
    local function flush_para()
        if #para > 0 then
            out[#out + 1] = "<p>" .. process_inline(table.concat(para, " "), ctx) .. "</p>"
            para = {}
        end
    end

    local i = 1
    while i <= #lines do
        local line = lines[i]

        -- Fenced code block
        local fence_marker, info = match_fence(line)
        if fence_marker then
            flush_para()
            close_lists_to(0)
            local buf = {}
            i = i + 1
            while i <= #lines do
                local l = lines[i]
                local close_marker = l:match("^%s*(```+)%s*$") or l:match("^%s*(~~~+)%s*$")
                if close_marker and close_marker:sub(1, 1) == fence_marker:sub(1, 1)
                    and #close_marker >= #fence_marker then
                    break
                end
                buf[#buf + 1] = l
                i = i + 1
            end
            local lang = info:match("^(%S+)")
            local class_attr = lang and (' class="language-' .. escape_attr(lang) .. '"') or ""
            out[#out + 1] = "<pre><code" .. class_attr .. ">"
                .. escape_html(table.concat(buf, "\n"))
                .. "</code></pre>"
            i = i + 1
        -- Blank line
        elseif is_blank(line) then
            flush_para()
            -- Don't close lists yet — a blank line between items is allowed.
            i = i + 1
        -- ATX heading
        elseif match_heading(line) then
            flush_para()
            close_lists_to(0)
            local level, text = match_heading(line)
            out[#out + 1] = string.format("<h%d>%s</h%d>", level, process_inline(text, ctx), level)
            i = i + 1
        -- Horizontal rule
        elseif match_hr(line) then
            flush_para()
            close_lists_to(0)
            out[#out + 1] = "<hr/>"
            i = i + 1
        -- Blockquote
        elseif match_blockquote(line) then
            flush_para()
            close_lists_to(0)
            local buf = {}
            while i <= #lines and match_blockquote(lines[i]) do
                buf[#buf + 1] = match_blockquote(lines[i])
                i = i + 1
            end
            out[#out + 1] = "<blockquote>" .. process_inline(table.concat(buf, " "), ctx) .. "</blockquote>"
        -- List items
        else
            local ul_indent, ul_content = match_ul(line)
            local ol_indent, ol_content = match_ol(line)
            if ul_indent or ol_indent then
                flush_para()
                local indent = ul_indent or ol_indent
                local content = ul_content or ol_content
                local list_type = ul_indent and "ul" or "ol"
                -- Depth based on indent level (every 2 spaces = one level)
                local depth = math.floor(indent / 2) + 1

                -- Close deeper lists
                while #list_stack > 0 and list_stack[#list_stack].indent >= indent
                    and (#list_stack > depth or list_stack[#list_stack].type ~= list_type) do
                    -- Close until we either match or are shallower
                    if list_stack[#list_stack].indent > indent
                        or (list_stack[#list_stack].indent == indent
                            and list_stack[#list_stack].type ~= list_type) then
                        local top = table.remove(list_stack)
                        out[#out + 1] = top.type == "ol" and "</ol>" or "</ul>"
                    else
                        break
                    end
                end

                -- Open a new list if we're deeper or empty
                if #list_stack == 0 or list_stack[#list_stack].indent < indent then
                    list_stack[#list_stack + 1] = { type = list_type, indent = indent }
                    out[#out + 1] = list_type == "ol" and "<ol>" or "<ul>"
                end

                out[#out + 1] = "<li>" .. process_inline(content, ctx) .. "</li>"
                i = i + 1
            else
                -- Paragraph line (close any open lists since this is plain text)
                close_lists_to(0)
                para[#para + 1] = strip_trailing(line):gsub("^%s+", "")
                i = i + 1
            end
        end
    end

    flush_para()
    close_lists_to(0)

    -- Render footnotes section. Only include notes that were referenced.
    local rendered_fns = {}
    for _, fn in ipairs(fn_order) do
        if fn.refs > 0 then rendered_fns[#rendered_fns + 1] = fn end
    end
    if #rendered_fns > 0 then
        out[#out + 1] = '<hr class="footnotes-sep"/>'
        out[#out + 1] = '<section class="footnotes"><ol>'
        for _, fn in ipairs(rendered_fns) do
            local body = process_inline(fn.content:gsub("\n", " "), ctx)
            local backrefs = {}
            for r = 1, fn.refs do
                local suffix = r > 1 and ("-" .. r) or ""
                backrefs[#backrefs + 1] = string.format(
                    '<a href="#fnref-%s%s" class="footnote-back">&#8617;%s</a>',
                    escape_attr(fn.slug), suffix,
                    r > 1 and ("<sup>" .. r .. "</sup>") or "")
            end
            out[#out + 1] = string.format(
                '<li id="fn-%s"><p>%s %s</p></li>',
                escape_attr(fn.slug), body, table.concat(backrefs, " "))
        end
        out[#out + 1] = '</ol></section>'
    end

    return table.concat(out, "\n")
end

-- Wrap a body fragment in a minimal HTML document for KOReader consumption.
function Markdown.toHtmlDocument(md, title)
    local body = Markdown.toHtml(md)
    local safe_title = escape_html(title or "Article")
    return table.concat({
        "<!DOCTYPE html>",
        '<html><head><meta charset="utf-8"/>',
        "<title>", safe_title, "</title></head>",
        "<body>",
        "<h1>", safe_title, "</h1>",
        body,
        "</body></html>",
    })
end

return Markdown
