-- Adapted from omer-faruq/instapaper.koplugin (GPL-3.0):
-- https://github.com/omer-faruq/instapaper.koplugin
-- Changes: renamed module, adjusted for Matter's item shape (id, url),
-- updated User-Agent and identifiers.

local Version = require("version")
local http = require("socket.http")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socketutil = require("socketutil")
local urlmod = require("socket.url")
local util = require("util")

local MatterEpub = {}

--------------------------------------------------------------------
-- MIME type helpers
--------------------------------------------------------------------

local ext_to_mimetype = {
    png  = "image/png",
    jpg  = "image/jpeg",
    jpeg = "image/jpeg",
    gif  = "image/gif",
    svg  = "image/svg+xml",
    webp = "image/webp",
    bmp  = "image/bmp",
}

local mimetype_to_ext = {
    ["image/png"]     = "png",
    ["image/jpeg"]    = "jpg",
    ["image/gif"]     = "gif",
    ["image/svg+xml"] = "svg",
    ["image/webp"]    = "webp",
    ["image/bmp"]     = "bmp",
}

--------------------------------------------------------------------
-- Image download helpers
--------------------------------------------------------------------

local function resolveUrl(src, base_url)
    if not src or src == "" then return nil end
    if src:find("^data:") then return nil end
    if src:find("^[%w][%w%+%-.]*:") then return src end
    if not base_url or base_url == "" then return nil end
    return urlmod.absolute(base_url, src)
end

local function downloadImageToMemory(url)
    local sink = {}
    local client = url:match("^https:") and https or http
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, headers = client.request{
        url     = url,
        method  = "GET",
        sink    = socketutil.table_sink(sink),
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"]      = "KOReader Matter",
        },
    }
    socketutil:reset_timeout()
    if not ok or tostring(code):sub(1, 1) ~= "2" then
        logger.info("MatterEpub: image download failed", url, code)
        return nil, nil
    end
    local content = table.concat(sink)
    local ct = headers and headers["content-type"] or ""
    ct = ct:match("^([^;]+)") or ct
    return content, ct:lower()
end

local function isTinyImage(tag)
    local function getAttr(t, attr)
        return t:match(attr .. '%s*=%s*"([^"]*)"')
            or t:match(attr .. "%s*=%s*'([^']*)'")
    end
    local w = tonumber(getAttr(tag, "width"))
    local h = tonumber(getAttr(tag, "height"))
    if w and w <= 1 and h and h <= 1 then return true end
    return false
end

--------------------------------------------------------------------
-- HTML → EPUB image rewriting
--------------------------------------------------------------------

local function rewriteImages(html, base_url)
    local images = {}
    local seen = {}
    local imagenum = 1

    local function processTag(img_tag)
        if isTinyImage(img_tag) then return "" end

        local src = img_tag:match('[%s<][Ss][Rr][Cc]%s*=%s*"([^"]*)"')
                 or img_tag:match("[%s<][Ss][Rr][Cc]%s*=%s*'([^']*)'")
        if not src or src == "" then
            src = img_tag:match('data%-src%s*=%s*"([^"]*)"')
               or img_tag:match("data%-src%s*=%s*'([^']*)'")
        end
        if not src or src == "" then return "" end

        src = src:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")

        local abs_src = resolveUrl(src, base_url)
        if not abs_src then return "" end

        if seen[abs_src] then
            local alt = img_tag:match('[Aa][Ll][Tt]%s*=%s*"([^"]*)"') or ""
            return '<img src="' .. seen[abs_src] .. '" alt="' .. alt
                .. '" style="max-width:100%; height:auto;"/>'
        end

        local ext = abs_src:match("%.([%w]+)%??") or ""
        ext = ext:lower()

        local imgid = string.format("img%05d", imagenum)
        imagenum = imagenum + 1

        local content, ct = downloadImageToMemory(abs_src)
        if not content then return img_tag end

        if ext == "" and ct and ct ~= "" then
            ext = mimetype_to_ext[ct] or ""
        end

        local filename = ext ~= "" and (imgid .. "." .. ext) or imgid
        local imgpath  = "images/" .. filename
        local mimetype = ext_to_mimetype[ext] or (ct ~= "" and ct or "application/octet-stream")
        local no_compress = (mimetype ~= "image/svg+xml")

        seen[abs_src] = imgpath
        table.insert(images, {
            imgpath     = imgpath,
            content     = content,
            mimetype    = mimetype,
            no_compress = no_compress,
        })

        local alt = img_tag:match('[Aa][Ll][Tt]%s*=%s*"([^"]*)"') or ""
        return '<img src="' .. imgpath .. '" alt="' .. alt
            .. '" style="max-width:100%; height:auto;"/>'
    end

    local rewritten = html:gsub("(<%s*[Ii][Mm][Gg][^>]*/?%s*>)", processTag)
    return rewritten, images
end

--------------------------------------------------------------------
-- Heading -> table-of-contents extraction
--------------------------------------------------------------------

-- Strip HTML tags and decode common entities so heading text is plain.
local function plainTextFromHtml(s)
    if not s then return "" end
    s = s:gsub("<[^>]+>", "")
    s = s
        :gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", '"')
        :gsub("&apos;", "'")
        :gsub("&#(%d+);", function(n)
            local code = tonumber(n)
            if code and code < 128 then return string.char(code) end
            -- Leave higher codepoints alone; KOReader's NCX parser handles
            -- numeric entities fine. Re-emit verbatim.
            return "&#" .. n .. ";"
        end)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Re-escape plain text for inclusion in an XML element body.
local function xmlEscape(s)
    return (s
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;"))
end

-- Scan `body_content` for h1-h6 tags, ensure each has an id attribute, and
-- return (rewritten_body, entries). `entries` is an ordered list of
-- { level, text, anchor }.
local function extractToc(body_content)
    local entries = {}
    local counter = 0
    local rewritten = body_content:gsub(
        "<[hH]([1-6])([^>]*)>(.-)</[hH]%1%s*>",
        function(level, attrs, inner)
            local plain = plainTextFromHtml(inner)
            if plain == "" then
                return nil  -- keep original
            end
            counter = counter + 1
            local existing_id =
                attrs:match('id%s*=%s*"([^"]*)"')
                or attrs:match("id%s*=%s*'([^']*)'")
            local anchor
            if existing_id and existing_id ~= "" then
                anchor = existing_id
            else
                anchor = "mh" .. counter
                attrs = attrs .. ' id="' .. anchor .. '"'
            end
            entries[#entries + 1] = {
                level = tonumber(level),
                text = plain,
                anchor = anchor,
            }
            return "<h" .. level .. attrs .. ">" .. inner .. "</h" .. level .. ">"
        end)
    return rewritten, entries
end

-- Build the NCX navMap (and depth) for a list of TOC entries. If empty,
-- emit a single top-of-document entry so the EPUB still validates.
local function buildNavMap(entries, fallback_title)
    if #entries == 0 then
        return string.format(
            '    <navPoint id="np1" playOrder="1"><navLabel><text>%s</text></navLabel><content src="content.xhtml"/></navPoint>',
            xmlEscape(fallback_title)), 1
    end
    local parts = {}
    local max_depth = 1
    for i, e in ipairs(entries) do
        if e.level > max_depth then max_depth = e.level end
        parts[#parts + 1] = string.format(
            '    <navPoint id="np%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="content.xhtml#%s"/></navPoint>',
            i, i, xmlEscape(e.text), e.anchor)
    end
    return table.concat(parts, "\n"), max_depth
end

--------------------------------------------------------------------
-- EPUB path helper
--------------------------------------------------------------------

function MatterEpub.buildEpubPath(download_dir, item)
    local safe_title = (item.title or "article")
        :gsub("[/\\%?%%%*%:%|%\"%<%>]", "_")
        :sub(1, 100)
    safe_title = util.fixUtf8(safe_title, "_")
    return download_dir .. "/"
        .. tostring(item.id) .. "_" .. safe_title .. ".epub"
end

--------------------------------------------------------------------
-- Main EPUB creation
--------------------------------------------------------------------

-- Build a standalone EPUB from an article HTML body.
-- Returns filepath on success, nil + error string on failure.
function MatterEpub.createEpub(item, html, download_dir, include_images)
    if type(html) ~= "string" or html == "" then
        return nil, "empty_html"
    end

    local epub_path = MatterEpub.buildEpubPath(download_dir, item)
    local article_url = item.url or ""
    local title = item.title or "Untitled"
    local escaped_title = title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local mtime = os.time()

    html = html:gsub("<!%-%-%[%s%S]-%-%->", "")
    html = html:gsub("<!DOCTYPE[^>]*>", "")
    html = html:gsub("<%?xml[%s%S]-%?>", "")

    html = html:gsub("<script[^>]*>[%s%S]-</script>", "")
    html = html:gsub("<style[^>]*>[%s%S]-</style>", "")

    local ok_cre, cre = pcall(require, "libs/libkoreader-cre")
    if ok_cre and cre then
        local balanced = cre.getBalancedHTML(html, 0x0)
        if type(balanced) == "string" and balanced ~= "" then
            html = balanced
        end
    end

    local body_content
    local _, body_open_end  = html:find("<body[^>]*>")
    local body_close_start  = html:find("</body>")
    if body_open_end and body_close_start and body_close_start > body_open_end then
        body_content = html:sub(body_open_end + 1, body_close_start - 1)
    end
    if not body_content or body_content:match("^%s*$") then
        body_content = html
    end

    body_content = body_content:gsub("<(br)(%s*)>",       "<%1%2/>")
    body_content = body_content:gsub("<(hr)(%s*)>",       "<%1%2/>")
    body_content = body_content:gsub("<(input)([^/>]-)>", "<%1%2/>")

    local images = {}
    if include_images then
        body_content, images = rewriteImages(body_content, article_url)
    else
        body_content = body_content:gsub("<%s*[Ii][Mm][Gg][^>]*/?>%s*", "")
    end

    local function escapeCodeBlock(open_tag, content, close_tag)
        content = content:gsub("<([^>]+)>", function(inner)
            if inner:match("^/?[%a][%w%-]*") then
                return "<" .. inner .. ">"
            end
            return "&lt;" .. inner .. "&gt;"
        end)
        return open_tag .. content .. close_tag
    end
    body_content = body_content:gsub("(<code[^>]*>)(.-)(</code>)", escapeCodeBlock)
    body_content = body_content:gsub("(<pre[^>]*>)(.-)(</pre>)",   escapeCodeBlock)

    -- Build a real TOC from headings before wrapping in XHTML.
    local toc_entries
    body_content, toc_entries = extractToc(body_content)

    html = '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
        .. '<meta http-equiv="Content-Type" content="application/xhtml+xml; charset=utf-8"/>'
        .. '<title>' .. escaped_title .. '</title>'
        .. '<link rel="stylesheet" type="text/css" href="stylesheet.css"/>'
        .. '</head><body>'
        .. body_content
        .. '</body></html>'

    local ok_arch, Archiver = pcall(require, "ffi/archiver")
    if not ok_arch or not Archiver then
        logger.warn("MatterEpub: Archiver not available")
        return nil, "archiver_unavailable"
    end

    -- Resolve metadata for the OPF.
    local author_name
    if type(item.author) == "table" then
        author_name = item.author.name
    elseif type(item.author) == "string" then
        author_name = item.author
    end
    local excerpt = type(item.excerpt) == "string" and item.excerpt or nil
    local site_name = type(item.site_name) == "string" and item.site_name or nil
    local item_id = type(item.id) == "string" and item.id or "matter_article"

    -- Try to fetch the cover image (item.image_url). Optional; failures
    -- silently skip the cover so EPUB creation still succeeds.
    local cover_filename, cover_mimetype, cover_bytes
    if type(item.image_url) == "string" and item.image_url ~= "" then
        local content, ct = downloadImageToMemory(item.image_url)
        if content and #content > 0 then
            local ext = item.image_url:match("%.([%w]+)%??") or ""
            ext = ext:lower()
            if ext == "" and ct and ct ~= "" then
                ext = mimetype_to_ext[ct] or ""
            end
            if ext == "" then ext = "jpg" end
            cover_filename = "cover." .. ext
            cover_mimetype = ext_to_mimetype[ext]
                or (ct ~= "" and ct or "image/jpeg")
            cover_bytes = content
        end
    end

    local epub_path_tmp = epub_path .. ".tmp"
    local epub = Archiver.Writer:new{}
    if not epub:open(epub_path_tmp, "epub") then
        return nil, "epub_open_failed"
    end

    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")

    epub:addFileFromMemory("META-INF/container.xml", [[
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], mtime)

    -- Build OPF metadata block piecewise so we only emit fields we have.
    local meta_parts = {}
    meta_parts[#meta_parts + 1] = "    <dc:identifier id=\"bookid\">urn:matter:"
        .. xmlEscape(item_id) .. "</dc:identifier>"
    meta_parts[#meta_parts + 1] = "    <dc:title>" .. escaped_title .. "</dc:title>"
    meta_parts[#meta_parts + 1] = "    <dc:language>en</dc:language>"
    if author_name and author_name ~= "" then
        meta_parts[#meta_parts + 1] = "    <dc:creator>"
            .. xmlEscape(author_name) .. "</dc:creator>"
    end
    if excerpt and excerpt ~= "" then
        meta_parts[#meta_parts + 1] = "    <dc:description>"
            .. xmlEscape(excerpt) .. "</dc:description>"
    end
    if site_name and site_name ~= "" then
        meta_parts[#meta_parts + 1] = "    <dc:publisher>"
            .. xmlEscape(site_name) .. "</dc:publisher>"
    else
        meta_parts[#meta_parts + 1] = "    <dc:publisher>Matter</dc:publisher>"
    end
    if article_url and article_url ~= "" then
        meta_parts[#meta_parts + 1] = "    <dc:source>"
            .. xmlEscape(article_url) .. "</dc:source>"
    end
    if cover_filename then
        meta_parts[#meta_parts + 1] = '    <meta name="cover" content="cover-image"/>'
    end
    meta_parts[#meta_parts + 1] = "    <meta name=\"generator\" content=\"KOReader "
        .. xmlEscape(Version:getCurrentRevision()) .. "\"/>"

    local opf_parts = {}
    table.insert(opf_parts, string.format([[
<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        unique-identifier="bookid" version="2.0">
  <metadata>
%s
  </metadata>
  <manifest>
    <item id="ncx"     href="toc.ncx"      media-type="application/x-dtbncx+xml"/>
    <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
    <item id="css"     href="stylesheet.css" media-type="text/css"/>
]], table.concat(meta_parts, "\n")))

    if cover_filename then
        table.insert(opf_parts, string.format(
            '    <item id="cover-image" href="%s" media-type="%s"/>\n',
            cover_filename, cover_mimetype))
    end
    if include_images then
        for i, img in ipairs(images) do
            table.insert(opf_parts, string.format(
                '    <item id="img%05d" href="%s" media-type="%s"/>\n',
                i, img.imgpath, img.mimetype))
        end
    end

    table.insert(opf_parts, [[
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>
]])
    epub:addFileFromMemory("OEBPS/content.opf", table.concat(opf_parts), mtime)

    epub:addFileFromMemory("OEBPS/stylesheet.css", "/* Matter */\n", mtime)

    -- TOC navMap built from heading scan; falls back to one entry if no
    -- headings were found in the article.
    local nav_map, depth = buildNavMap(toc_entries or {}, title)
    local toc_ncx = string.format([[
<?xml version='1.0' encoding='utf-8'?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:matter:%s"/>
    <meta name="dtb:depth" content="%d"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
%s
  </navMap>
</ncx>
]], xmlEscape(item_id), depth, escaped_title, nav_map)
    epub:addFileFromMemory("OEBPS/toc.ncx", toc_ncx, mtime)

    epub:addFileFromMemory("OEBPS/content.xhtml", html, mtime)

    if cover_filename and cover_bytes then
        -- SVG covers compress well; everything else is already a compressed
        -- format, so skip re-deflating.
        local no_compress = cover_mimetype ~= "image/svg+xml"
        epub:addFileFromMemory("OEBPS/" .. cover_filename,
            cover_bytes, no_compress, mtime)
        cover_bytes = nil  -- release the buffer
    end

    collectgarbage()
    collectgarbage()

    if include_images then
        for _, img in ipairs(images) do
            epub:addFileFromMemory("OEBPS/" .. img.imgpath, img.content, img.no_compress, mtime)
        end
    end

    epub:close()

    local ok_rename = os.rename(epub_path_tmp, epub_path)
    if not ok_rename then
        os.remove(epub_path_tmp)
        return nil, "epub_rename_failed"
    end

    collectgarbage()
    collectgarbage()

    logger.info("MatterEpub: created", epub_path)
    return epub_path, nil
end

return MatterEpub
