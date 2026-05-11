local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = FFIUtil.template
local Dispatcher = require("dispatcher")

--------------------------------------------------------------------
-- Plugin
--------------------------------------------------------------------

local Matter = WidgetContainer:extend{
    name = "matter",
    api_base = "https://api.getmatter.com/public/v1",
}

--------------------------------------------------------------------
-- HTTP request helper
--------------------------------------------------------------------

-- Make an authenticated request. Returns ok, body_str, http_code, headers.
-- `opts`: { method, path, query, body_table, raw_body, no_auth }
-- - query: table of query parameters (values stringified)
-- - body_table: table to be JSON-encoded as request body
-- - raw_body: a string body (used in rare cases; sets no Content-Type)
function Matter:apiRequest(opts)
    local method = opts.method or "GET"
    local path = opts.path or "/"
    local url = self.api_base .. path

    -- Append query string
    if opts.query and next(opts.query) then
        local parts = {}
        for k, v in pairs(opts.query) do
            if v ~= nil then
                parts[#parts + 1] = tostring(k) .. "=" .. self:urlencode(tostring(v))
            end
        end
        if #parts > 0 then
            url = url .. "?" .. table.concat(parts, "&")
        end
    end

    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = "KOReader Matter Plugin",
    }
    if not opts.no_auth then
        if not self.api_token or self.api_token == "" then
            return false, "no_token", 0, {}
        end
        headers["Authorization"] = "Bearer " .. self.api_token
    end

    local body_str
    if opts.body_table then
        local ok, encoded = pcall(JSON.encode, opts.body_table)
        if not ok then return false, "json_encode_failed", 0, {} end
        body_str = encoded
        headers["Content-Type"] = "application/json"
    elseif opts.raw_body then
        body_str = opts.raw_body
    end
    if body_str then
        headers["Content-Length"] = tostring(#body_str)
    end

    local sink = {}
    socketutil:set_timeout(
        socketutil.DEFAULT_BLOCK_TIMEOUT,
        socketutil.DEFAULT_TOTAL_TIMEOUT)
    local req = {
        url     = url,
        method  = method,
        headers = headers,
        sink    = ltn12.sink.table(sink),
    }
    if body_str then req.source = ltn12.source.string(body_str) end

    local result, code, response_headers = https.request(req)
    socketutil:reset_timeout()

    if result ~= 1 then
        logger.warn("Matter: network error", method, path, code)
        return false, tostring(code), 0, {}
    end

    local body = table.concat(sink)
    local ok = type(code) == "number" and code >= 200 and code < 300
    return ok, body, code, response_headers or {}
end

function Matter:urlencode(s)
    return (s:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Decode JSON safely. Returns table or nil.
function Matter:decodeJson(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, data = pcall(JSON.decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

-- Pull a human-readable error message out of an API error response body.
function Matter:errorMessage(body, code)
    local data = self:decodeJson(body)
    if data and data.error and type(data.error) == "table" then
        return data.error.message or data.error.code or tostring(code)
    end
    return tostring(code)
end

--------------------------------------------------------------------
-- Dispatcher integration
--------------------------------------------------------------------

function Matter:onMatterInbox()
    self:ensureOnlineAndLoggedIn(function() self:browseItems({ status = "inbox" }, _("Inbox")) end)
    return true
end

function Matter:onMatterQueue()
    self:ensureOnlineAndLoggedIn(function() self:browseItems({ status = "queue" }, _("Queue")) end)
    return true
end

function Matter:onMatterFavorites()
    self:ensureOnlineAndLoggedIn(function() self:browseItems({ is_favorite = "true" }, _("Favorites")) end)
    return true
end

function Matter:onMatterArchive()
    self:ensureOnlineAndLoggedIn(function() self:browseItems({ status = "archive" }, _("Archive")) end)
    return true
end

function Matter:onMatterBulkDownload()
    self:ensureOnlineAndLoggedIn(function() self:showBulkDownloadDialog() end)
    return true
end

function Matter:onDispatcherRegisterActions()
    Dispatcher:registerAction("matter_inbox",
        { category = "none", event = "MatterInbox", title = _("Matter: inbox"), general = true, })
    Dispatcher:registerAction("matter_queue",
        { category = "none", event = "MatterQueue", title = _("Matter: queue"), general = true, })
    Dispatcher:registerAction("matter_favorites",
        { category = "none", event = "MatterFavorites", title = _("Matter: favorites"), general = true, })
    Dispatcher:registerAction("matter_archive",
        { category = "none", event = "MatterArchive", title = _("Matter: archive"), general = true, })
    Dispatcher:registerAction("matter_bulk_download",
        { category = "none", event = "MatterBulkDownload", title = _("Matter bulk download"), general = true, separator = true, })
end

--------------------------------------------------------------------
-- Init & settings
--------------------------------------------------------------------

function Matter:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:loadSettings()
    self:loadPendingPool()
    if self.ui and self.ui.link then
        self:registerLinkPopupButton()
    end
end

function Matter:onReaderReady()
    if NetworkMgr:isOnline() then
        UIManager:scheduleIn(2, function()
            if self:countPending() > 0 then
                self:drainPendingQueue({ silent = true })
            end
            self:drainPendingProgress({ silent = true })
        end)
    end
    -- If the freshly-opened document is a Matter article, pull Matter's
    -- current progress and jump forward to it if Matter is further ahead.
    -- Runs on every open — plugin-initiated, file-manager, auto-resume —
    -- so the "smart pull" works regardless of how the document was opened.
    if self.auto_sync_progress then
        self:syncOpenDocumentFromMatter()
    end
end

-- Identify a Matter download and extract its item id from the filename.
-- We match by filename pattern alone (any file basenamed `itm_<id>_…`),
-- which means moving downloads out of the configured cache folder, or
-- changing the cache folder setting after the fact, doesn't break sync.
-- The `itm_` prefix followed by an alphanumeric id is specific enough to
-- Matter that false positives are not a realistic concern.
-- Returns (item_id, doc_path) or (nil, nil) if not a Matter file.
function Matter:identifyOpenMatterDoc()
    if not self.ui or not self.ui.document then return nil, nil end
    local doc_path = self.ui.document.file
    if type(doc_path) ~= "string" or doc_path == "" then return nil, nil end
    local basename = doc_path:match("([^/]+)$") or ""
    local item_id = basename:match("^(itm_[%w]+)_")
    if not item_id then return nil, nil end
    return item_id, doc_path
end

function Matter:syncOpenDocumentFromMatter()
    local item_id = self:identifyOpenMatterDoc()
    if not item_id then return end
    if not self:isLoggedIn() then return end
    if not NetworkMgr:isOnline() then return end

    local ok, body = self:apiRequest{
        method = "GET", path = "/items/" .. item_id,
    }
    if not ok then return end
    local data = self:decodeJson(body)
    if not data then return end

    local matter_pct = tonumber(data.reading_progress) or 0
    local local_pct = 0
    if self.ui.doc_settings then
        local lp = self.ui.doc_settings:readSetting("percent_finished")
        if type(lp) == "number" then local_pct = lp end
    end

    -- Only jump forward (1% margin avoids spurious jumps on every open).
    if matter_pct <= local_pct + 0.01 then return end

    local pct = math.floor(matter_pct * 100 + 0.5)
    if pct < 1 then pct = 1 end
    if pct > 100 then pct = 100 end
    local Event = require("ui/event")
    UIManager:scheduleIn(0.5, function()
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance then
            ReaderUI.instance:handleEvent(Event:new("GoToPercent", pct))
        end
    end)
end

function Matter:onNetworkConnected()
    UIManager:scheduleIn(1, function()
        if self:countPending() > 0 then
            self:drainPendingQueue({ silent = false })
        end
        self:drainPendingProgress({ silent = true })
    end)
end

function Matter:loadSettings()
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/matter.lua")
    self.api_token             = self.settings:readSetting("api_token")
    self.account_name          = self.settings:readSetting("account_name")
    self.account_email         = self.settings:readSetting("account_email")
    self.article_limit         = self.settings:readSetting("article_limit") or 50
    self.output_format         = self.settings:readSetting("output_format") or "html"
    self.include_images        = self.settings:readSetting("include_images") or false
    self.after_download_action = self.settings:readSetting("after_download_action") or "none"
    self.cache_folder          = self.settings:readSetting("cache_folder")
    self.auto_connect_network  = self.settings:readSetting("auto_connect_network")
    if self.auto_connect_network == nil then self.auto_connect_network = true end
    self.auto_sync_progress    = self.settings:readSetting("auto_sync_progress")
    if self.auto_sync_progress == nil then self.auto_sync_progress = true end
end

function Matter:saveSettings()
    self.settings:saveSetting("api_token",             self.api_token)
    self.settings:saveSetting("account_name",          self.account_name)
    self.settings:saveSetting("account_email",         self.account_email)
    self.settings:saveSetting("article_limit",         self.article_limit)
    self.settings:saveSetting("output_format",         self.output_format)
    self.settings:saveSetting("include_images",        self.include_images)
    self.settings:saveSetting("after_download_action", self.after_download_action)
    self.settings:saveSetting("cache_folder",          self.cache_folder)
    self.settings:saveSetting("auto_connect_network",  self.auto_connect_network)
    self.settings:saveSetting("auto_sync_progress",    self.auto_sync_progress)
    self.settings:flush()
end

function Matter:isLoggedIn()
    return self.api_token ~= nil and self.api_token ~= ""
end

function Matter:ensureOnlineAndLoggedIn(callback)
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{
            text = _("Please set your Matter API token first."),
        })
        return
    end
    NetworkMgr:runWhenOnline(function() callback() end)
end

--------------------------------------------------------------------
-- Main menu
--------------------------------------------------------------------

function Matter:addToMainMenu(menu_items)
    menu_items.matter = {
        text = _("Matter"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Inbox"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:browseItems({ status = "inbox" }, _("Inbox"))
                    end)
                end,
            },
            {
                text = _("Queue"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:browseItems({ status = "queue" }, _("Queue"))
                    end)
                end,
            },
            {
                text = _("Favorites"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:browseItems({ is_favorite = "true" }, _("Favorites"))
                    end)
                end,
            },
            {
                text = _("Archive"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:browseItems({ status = "archive" }, _("Archive"))
                    end)
                end,
                separator = true,
            },
            {
                text = _("Tags"),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:fetchAndShowTags()
                    end)
                end,
            },
            {
                text = _("Search..."),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:showSearchDialog()
                    end)
                end,
            },
            {
                text = _("Bulk download..."),
                callback = function()
                    self:ensureOnlineAndLoggedIn(function()
                        self:showBulkDownloadDialog()
                    end)
                end,
                separator = true,
            },
            {
                text = _("Open downloads folder"),
                callback = function() self:openDownloadsFolder() end,
            },
            {
                text = _("Clear downloads cache"),
                keep_menu_open = true,
                callback = function() self:clearDownloadsCache() end,
            },
            {
                text_func = function()
                    local count = self:countPending()
                    if count > 0 then
                        return T(_("Process pending URLs (%1)"), tostring(count))
                    else
                        return _("Process pending URLs")
                    end
                end,
                callback = function() self:processPendingPool() end,
                separator = true,
            },
            {
                text = _("Settings"),
                keep_menu_open = true,
                callback = function() self:showSettingsDialog() end,
            },
            {
                text_func = function()
                    if self:isLoggedIn() then
                        if self.account_email and self.account_email ~= "" then
                            return T(_("Sign out (%1)"), self.account_email)
                        end
                        return _("Sign out")
                    end
                    return _("Set API token")
                end,
                keep_menu_open = true,
                callback = function()
                    if self:isLoggedIn() then
                        self:logout()
                    else
                        self:showTokenDialog()
                    end
                end,
            },
        },
    }
end

--------------------------------------------------------------------
-- Token / auth dialogs
--------------------------------------------------------------------

function Matter:showTokenDialog()
    self.token_dialog = MultiInputDialog:new{
        title = _("Matter API token"),
        fields = {
            {
                text = self.api_token or "",
                hint = _("mat_..."),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.token_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.token_dialog:getFields()
                        local token = (fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        UIManager:close(self.token_dialog)
                        if token == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Token cannot be empty."),
                            })
                            return
                        end
                        self.api_token = token
                        self:saveSettings()
                        NetworkMgr:runWhenOnline(function()
                            self:verifyToken()
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(self.token_dialog)
    self.token_dialog:onShowKeyboard()
end

function Matter:verifyToken()
    UIManager:show(InfoMessage:new{ text = _("Verifying token..."), timeout = 1 })
    local ok, body, code = self:apiRequest{ method = "GET", path = "/me" }
    if not ok then
        local msg = code == 401 and _("Token rejected (401).")
            or code == 403 and _("This token is valid but Matter Pro is required for API access.")
            or T(_("Token check failed: %1"), self:errorMessage(body, code))
        UIManager:show(InfoMessage:new{ text = msg })
        -- Clear an obviously bad token so we don't keep retrying
        if code == 401 then
            self.api_token = nil
            self:saveSettings()
        end
        return
    end
    local data = self:decodeJson(body)
    if data then
        self.account_name  = data.name
        self.account_email = data.email
        self:saveSettings()
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Signed in as %1"), self.account_email or self.account_name or "?"),
        timeout = 2,
    })
end

function Matter:logout()
    self.api_token = nil
    self.account_name = nil
    self.account_email = nil
    self:saveSettings()
    UIManager:show(InfoMessage:new{ text = _("Signed out."), timeout = 2 })
end

--------------------------------------------------------------------
-- Settings dialog
--------------------------------------------------------------------

function Matter:showSettingsDialog()
    local limit_choices = { 25, 50, 100 }  -- Matter list endpoint caps at 100
    local current_limit = self.article_limit or 50
    local limit_idx = 2
    for i, v in ipairs(limit_choices) do
        if v == current_limit then limit_idx = i; break end
    end

    local output_format = self.output_format or "html"
    local include_images = self.include_images or false
    local after_download_action = self.after_download_action or "none"
    local cache_folder = self.cache_folder
    local auto_connect = self.auto_connect_network
    if auto_connect == nil then auto_connect = true end
    local auto_sync = self.auto_sync_progress
    if auto_sync == nil then auto_sync = true end

    local settings_dialog
    local function rebuildSettingsDialog()
        if settings_dialog then UIManager:close(settings_dialog) end

        local fmt_label = output_format == "epub" and "EPUB" or "HTML"
        local img_label = include_images and _("ON") or _("OFF")
        local limit_label = tostring(limit_choices[limit_idx])
        local action_label
        if after_download_action == "archive" then
            action_label = _("Archive")
        elseif after_download_action == "read" then
            action_label = _("Mark read")
        elseif after_download_action == "archive_read" then
            action_label = _("Archive + Mark read")
        else
            action_label = _("None")
        end

        local cache_label
        if cache_folder and cache_folder ~= "" then
            if #cache_folder > 40 then
                cache_label = "..." .. cache_folder:sub(-37)
            else
                cache_label = cache_folder
            end
        else
            cache_label = _("Default")
        end

        settings_dialog = ButtonDialog:new{
            title = _("Matter settings")
                .. "\n" .. _("Article list limit: ") .. limit_label
                .. "\n" .. _("Output format: ") .. fmt_label
                .. "\n" .. _("Include images (EPUB): ") .. img_label
                .. "\n" .. _("After download: ") .. action_label
                .. "\n" .. _("Auto connect network: ") .. (auto_connect and _("ON") or _("OFF"))
                .. "\n" .. _("Auto-sync progress: ") .. (auto_sync and _("ON") or _("OFF"))
                .. "\n" .. _("Cache folder: ") .. cache_label,
            buttons = {
                {
                    { text = _("< Limit >"), callback = function()
                        limit_idx = (limit_idx % #limit_choices) + 1
                        rebuildSettingsDialog()
                    end },
                    { text = _("< Format >"), callback = function()
                        output_format = output_format == "html" and "epub" or "html"
                        rebuildSettingsDialog()
                    end },
                },
                {
                    { text = _("Images: ") .. img_label, callback = function()
                        include_images = not include_images
                        rebuildSettingsDialog()
                    end },
                    { text = _("< After download >"), callback = function()
                        if after_download_action == "none" then
                            after_download_action = "archive"
                        elseif after_download_action == "archive" then
                            after_download_action = "read"
                        elseif after_download_action == "read" then
                            after_download_action = "archive_read"
                        else
                            after_download_action = "none"
                        end
                        rebuildSettingsDialog()
                    end },
                },
                {
                    { text = _("Auto connect: ") .. (auto_connect and _("ON") or _("OFF")),
                      callback = function()
                          auto_connect = not auto_connect
                          rebuildSettingsDialog()
                      end },
                    { text = _("Auto-sync: ") .. (auto_sync and _("ON") or _("OFF")),
                      callback = function()
                          auto_sync = not auto_sync
                          rebuildSettingsDialog()
                      end },
                },
                {
                    { text = _("< Cache folder >"), callback = function()
                        UIManager:close(settings_dialog)
                        self:showCacheFolderDialog(function(new_path)
                            cache_folder = new_path
                            rebuildSettingsDialog()
                        end, cache_folder)
                    end },
                },
                {
                    { text = _("Save"), callback = function()
                        UIManager:close(settings_dialog)
                        self.article_limit  = limit_choices[limit_idx]
                        self.output_format  = output_format
                        self.include_images = include_images
                        self.after_download_action = after_download_action
                        self.auto_connect_network = auto_connect
                        self.auto_sync_progress = auto_sync
                        self.cache_folder = cache_folder
                        self:saveSettings()
                        UIManager:show(InfoMessage:new{ text = _("Settings saved."), timeout = 2 })
                    end },
                    { text = _("Cancel"), callback = function()
                        UIManager:close(settings_dialog)
                    end },
                },
            },
        }
        UIManager:show(settings_dialog)
    end
    rebuildSettingsDialog()
end

function Matter:showCacheFolderDialog(return_callback, current_folder)
    local default_dir = DataStorage:getDataDir() .. "/matter"
    local cache_dialog
    cache_dialog = MultiInputDialog:new{
        title = _("Cache folder"),
        fields = {
            {
                text = current_folder or "",
                hint = current_folder and current_folder ~= "" and current_folder or default_dir,
            },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function()
                    UIManager:close(cache_dialog)
                    if return_callback then return_callback(current_folder) end
                end },
                { text = _("OK"), is_enter_default = true, callback = function()
                    local fields = cache_dialog:getFields()
                    local new_path = fields[1]
                    UIManager:close(cache_dialog)
                    if new_path and new_path ~= "" then
                        if self:isDangerousPath(new_path) then
                            UIManager:show(InfoMessage:new{
                                text = _("This path cannot be used as a cache folder for safety reasons.\n\nPlease choose a subfolder instead of a system directory."),
                            })
                            if return_callback then return_callback(current_folder) end
                            return
                        end
                        local attr = lfs.attributes(new_path)
                        if attr and attr.mode == "directory" then
                            if return_callback then return_callback(new_path) end
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("The specified path does not exist."),
                            })
                            if return_callback then return_callback(current_folder) end
                        end
                    else
                        if return_callback then return_callback(nil) end
                    end
                end },
            },
        },
    }
    UIManager:show(cache_dialog)
    cache_dialog:onShowKeyboard()
end

--------------------------------------------------------------------
-- Items: list & browse
--------------------------------------------------------------------

-- Fetch one page of items. Returns (items_list, next_cursor) or (nil, err).
function Matter:fetchItemsPage(query, cursor)
    local q = {}
    for k, v in pairs(query or {}) do q[k] = v end
    q.limit = q.limit or tostring(self.article_limit or 50)
    if cursor then q.cursor = cursor end

    local ok, body, code = self:apiRequest{
        method = "GET", path = "/items", query = q,
    }
    if not ok then
        return nil, self:errorMessage(body, code)
    end
    local data = self:decodeJson(body)
    if not data or type(data.results) ~= "table" then
        return nil, _("Failed to parse item list.")
    end
    return data.results, data.has_more and data.next_cursor or nil
end

-- Fetch a single item with markdown body. Returns (item_table, err).
-- Performs a single request — caller is responsible for retrying if Matter is
-- still processing the article. Polling would block the UI thread.
function Matter:fetchItemWithMarkdown(item_id)
    local ok, body, code = self:apiRequest{
        method = "GET", path = "/items/" .. item_id,
        query = { include = "markdown" },
    }
    if not ok then return nil, self:errorMessage(body, code) end
    local data = self:decodeJson(body)
    if not data then return nil, _("Failed to parse item.") end
    if data.markdown and data.markdown ~= "" then return data, nil end
    if data.processing_status == "failed" then
        return nil, _("Matter could not extract this article.")
    end
    return nil, _("Article is still being processed. Try again in a moment.")
end

function Matter:browseItems(query, title)
    local info = InfoMessage:new{ text = _("Fetching items...") }
    UIManager:show(info)
    UIManager:forceRePaint()

    local items, err = self:fetchItemsPage(query, nil)
    UIManager:close(info)
    UIManager:forceRePaint()

    if not items then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to fetch items: %1"), err or ""),
        })
        return
    end
    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No items found.") })
        return
    end
    self:showItemMenu(items, query, title)
end

function Matter:showItemMenu(items, query, title)
    local menu
    local menu_items = {}
    for _, it in ipairs(items) do
        local label = it.title
        if not label or label == "" or type(label) ~= "string" then
            label = it.url or "Untitled"
        end

        local mandatory
        if it.reading_progress and it.reading_progress > 0 then
            mandatory = string.format("%d%%", math.floor(it.reading_progress * 100))
        end
        if it.is_favorite then
            mandatory = (mandatory and (mandatory .. " ") or "") .. "★"
        end

        table.insert(menu_items, {
            text = label,
            mandatory = mandatory,
            callback = function()
                NetworkMgr:runWhenOnline(function()
                    self:downloadAndOpenItem(it)
                end)
            end,
            hold_callback = function()
                self:showItemActions(it, menu, query, title)
            end,
            hold_keep_menu_open = true,
        })
    end

    menu = Menu:new{
        title = "Matter — " .. (title or "Items"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        close_callback = function() UIManager:close(menu) end,
        onMenuHold = function(_, item)
            if item and type(item.hold_callback) == "function" then
                item.hold_callback()
            end
            return true
        end,
    }
    UIManager:show(menu, "full")
end

function Matter:buildItemMetaTitle(item)
    local lines = { item.title or _("Untitled") }
    if item.author then lines[#lines + 1] = _("Author: ") .. tostring(item.author) end
    if item.site_name then lines[#lines + 1] = _("Site: ") .. tostring(item.site_name) end
    if item.word_count and item.word_count > 0 then
        local mins = math.ceil(item.word_count / 200)
        lines[#lines + 1] = tostring(item.word_count) .. " " .. _("words")
            .. "  (~" .. tostring(mins) .. " min)"
    end
    if item.reading_progress and item.reading_progress > 0 then
        lines[#lines + 1] = _("Progress: ")
            .. string.format("%d%%", math.floor(item.reading_progress * 100))
    end
    if item.updated_at then
        local date = tostring(item.updated_at):sub(1, 10)
        lines[#lines + 1] = _("Updated: ") .. date
    end
    if item.url and item.url ~= "" then
        local url = item.url
        if #url > 60 then url = url:sub(1, 57) .. "..." end
        lines[#lines + 1] = url
    end
    return table.concat(lines, "\n")
end

function Matter:showItemActions(item, parent_menu, query, title)
    local actions_dialog
    actions_dialog = ButtonDialog:new{
        title = self:buildItemMetaTitle(item),
        buttons = {
            {
                { text = _("Download"), callback = function()
                    UIManager:close(actions_dialog)
                    NetworkMgr:runWhenOnline(function()
                        self:downloadItemOnly(item)
                    end)
                end },
                { text = _("Open"), callback = function()
                    UIManager:close(actions_dialog)
                    NetworkMgr:runWhenOnline(function()
                        self:downloadAndOpenItem(item)
                    end)
                end },
            },
            {
                { text = _("Archive"), callback = function()
                    UIManager:close(actions_dialog)
                    self:patchItem(item.id, { status = "archive" },
                        _("Archived."), parent_menu, query, title)
                end },
                { text = item.is_favorite and _("Unfavorite") or _("Favorite"),
                  callback = function()
                    UIManager:close(actions_dialog)
                    self:patchItem(item.id, { is_favorite = not item.is_favorite },
                        item.is_favorite and _("Unfavorited.") or _("Favorited."),
                        parent_menu, query, title)
                end },
            },
            {
                { text = _("Mark read"), callback = function()
                    UIManager:close(actions_dialog)
                    self:patchItem(item.id, { reading_progress = 1.0 },
                        _("Marked read."), parent_menu, query, title)
                end },
                { text = _("Sync progress"), callback = function()
                    UIManager:close(actions_dialog)
                    NetworkMgr:runWhenOnline(function()
                        self:syncProgressToMatter(item)
                    end)
                end },
            },
            {
                { text = _("Delete"), callback = function()
                    UIManager:close(actions_dialog)
                    self:deleteItem(item.id, parent_menu, query, title)
                end },
                { text = _("Cancel"), callback = function()
                    UIManager:close(actions_dialog)
                end },
            },
        },
    }
    UIManager:show(actions_dialog)
end

--------------------------------------------------------------------
-- Downloads
--------------------------------------------------------------------

function Matter:getDownloadDir()
    local dir
    if self.cache_folder and self.cache_folder ~= "" then
        dir = self.cache_folder
    else
        dir = DataStorage:getDataDir() .. "/matter"
    end
    lfs.mkdir(dir)
    return dir
end

function Matter:buildFilepath(item, ext)
    local safe_title = (item.title or "article")
        :gsub("[/\\%?%%%*%:%|%\"%<%>]", "_")
        :sub(1, 100)
    safe_title = util.fixUtf8(safe_title, "_")
    return self:getDownloadDir() .. "/"
        .. tostring(item.id) .. "_" .. safe_title .. "." .. ext
end

function Matter:saveHtmlDocument(item, html)
    local filepath = self:buildFilepath(item, "html")
    local f = io.open(filepath, "w")
    if not f then return nil end
    f:write(html)
    f:close()
    return filepath
end

function Matter:saveItemFromMarkdown(item, markdown)
    local Markdown = require("matter_markdown")
    local html = Markdown.toHtmlDocument(markdown, item.title)
    local fmt = self.output_format or "html"
    if fmt == "epub" then
        local MatterEpub = require("matter_epub")
        local filepath, err = MatterEpub.createEpub(
            item, html, self:getDownloadDir(), self.include_images)
        if not filepath then
            logger.warn("Matter: EPUB creation failed, falling back to HTML", err)
            return self:saveHtmlDocument(item, html)
        end
        return filepath
    else
        return self:saveHtmlDocument(item, html)
    end
end

-- Apply the configured after-download action to an item.
function Matter:applyAfterDownload(item)
    local action = self.after_download_action or "none"
    if action == "none" then return end
    if action == "archive" then
        self:apiRequest{ method = "PATCH", path = "/items/" .. item.id,
            body_table = { status = "archive" } }
    elseif action == "read" then
        self:apiRequest{ method = "PATCH", path = "/items/" .. item.id,
            body_table = { reading_progress = 1.0 } }
    elseif action == "archive_read" then
        self:apiRequest{ method = "PATCH", path = "/items/" .. item.id,
            body_table = { status = "archive", reading_progress = 1.0 } }
    end
end

function Matter:downloadItemOnly(item)
    UIManager:show(InfoMessage:new{ text = _("Downloading article..."), timeout = 1 })

    local full, err = self:fetchItemWithMarkdown(item.id)
    if not full then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed: %1"), err or ""),
        })
        return
    end
    for k, v in pairs(full) do item[k] = v end

    local filepath = self:saveItemFromMarkdown(item, item.markdown)
    if not filepath then
        UIManager:show(InfoMessage:new{ text = _("Could not save article file.") })
        return
    end

    local short_title = (item.title or "article"):sub(1, 40)
    UIManager:show(InfoMessage:new{
        text = T(_("Saved: %1"), short_title), timeout = 2,
    })
    self:applyAfterDownload(item)
end

function Matter:downloadAndOpenItem(item)
    UIManager:show(InfoMessage:new{ text = _("Downloading article..."), timeout = 1 })

    local full, err = self:fetchItemWithMarkdown(item.id)
    if not full then
        UIManager:show(InfoMessage:new{
            text = T(_("Download failed: %1"), err or ""),
        })
        return
    end
    for k, v in pairs(full) do item[k] = v end

    local filepath = self:saveItemFromMarkdown(item, item.markdown)
    if not filepath then
        UIManager:show(InfoMessage:new{ text = _("Could not save article file.") })
        return
    end

    self:applyAfterDownload(item)

    -- The smart pull (jump forward to Matter's progress if it's ahead) is
    -- handled by onReaderReady -> syncOpenDocumentFromMatter, which runs for
    -- *any* open of a Matter file — plugin tap, file manager, KOReader's
    -- last-book auto-resume — not just this code path.

    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(filepath)
end

--------------------------------------------------------------------
-- Item write operations
--------------------------------------------------------------------

-- Locate the cached file for an item by id prefix, returning the path or nil.
function Matter:findCachedFile(item_id)
    local dir = self:getDownloadDir()
    if not lfs.attributes(dir, "mode") then return nil end
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".."
            and entry:sub(1, #item_id + 1) == (item_id .. "_") then
            local full = dir .. "/" .. entry
            if lfs.attributes(full, "mode") == "file" then return full end
        end
    end
    return nil
end

-- Push KOReader's local reading progress for an item back up to Matter.
function Matter:syncProgressToMatter(item)
    local filepath = self:findCachedFile(item.id)
    if not filepath then
        UIManager:show(InfoMessage:new{
            text = _("This item hasn't been downloaded yet. Open it once to track progress locally."),
        })
        return
    end

    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(filepath)
    local percent = doc_settings:readSetting("percent_finished")
    if type(percent) ~= "number" then
        UIManager:show(InfoMessage:new{
            text = _("No local reading progress found. Open the article in KOReader first."),
        })
        return
    end
    if percent < 0 then percent = 0 end
    if percent > 1 then percent = 1 end

    local status, current = self:safePushProgress(item.id, percent)
    if status == "pushed" then
        UIManager:show(InfoMessage:new{
            text = T(_("Synced progress to Matter: %1%%"),
                math.floor(percent * 100 + 0.5)),
            timeout = 2,
        })
    elseif status == "skipped_already_ahead" then
        UIManager:show(InfoMessage:new{
            text = T(_("Matter is already at %1%% (local: %2%%). Not downgrading."),
                math.floor((current or 0) * 100 + 0.5),
                math.floor(percent * 100 + 0.5)),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Sync failed. Will retry when online."),
            timeout = 2,
        })
        self:queueProgressUpdate(item.id, percent)
    end
end

function Matter:patchItem(item_id, patch, success_text, parent_menu, query, title)
    local ok, body, code = self:apiRequest{
        method = "PATCH", path = "/items/" .. item_id, body_table = patch,
    }
    UIManager:show(InfoMessage:new{
        text = ok and success_text or T(_("Failed: %1"), self:errorMessage(body, code)),
        timeout = 2,
    })
    if ok and parent_menu then
        UIManager:close(parent_menu)
        self:browseItems(query, title)
    end
end

function Matter:deleteItem(item_id, parent_menu, query, title)
    local ok, body, code = self:apiRequest{
        method = "DELETE", path = "/items/" .. item_id,
    }
    UIManager:show(InfoMessage:new{
        text = ok and _("Deleted.") or T(_("Failed: %1"), self:errorMessage(body, code)),
        timeout = 2,
    })
    if ok and parent_menu then
        UIManager:close(parent_menu)
        self:browseItems(query, title)
    end
end

--------------------------------------------------------------------
-- Tags
--------------------------------------------------------------------

function Matter:fetchAllTags()
    local results = {}
    local cursor
    repeat
        local q = { limit = "100" }
        if cursor then q.cursor = cursor end
        local ok, body, code = self:apiRequest{ method = "GET", path = "/tags", query = q }
        if not ok then return nil, self:errorMessage(body, code) end
        local data = self:decodeJson(body)
        if not data then return nil, _("Failed to parse tag list.") end
        for _, t in ipairs(data.results or {}) do
            results[#results + 1] = t
        end
        cursor = (data.has_more and data.next_cursor) or nil
    until cursor == nil
    return results, nil
end

function Matter:fetchAndShowTags()
    UIManager:show(InfoMessage:new{ text = _("Fetching tags..."), timeout = 1 })
    local tags, err = self:fetchAllTags()
    if not tags then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to fetch tags: %1"), err or ""),
        })
        return
    end
    if #tags == 0 then
        UIManager:show(InfoMessage:new{ text = _("No tags found.") })
        return
    end

    local tag_menu
    local menu_items = {}
    for _, tag in ipairs(tags) do
        local t = tag
        local label = t.name or t.id
        local mandatory = t.item_count and tostring(t.item_count) or nil
        table.insert(menu_items, {
            text = label,
            mandatory = mandatory,
            callback = function()
                UIManager:close(tag_menu)
                NetworkMgr:runWhenOnline(function()
                    self:browseItems({ tag = t.id }, "#" .. (t.name or t.id))
                end)
            end,
        })
    end
    tag_menu = Menu:new{
        title = _("Matter — Tags"),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        close_callback = function() UIManager:close(tag_menu) end,
    }
    UIManager:show(tag_menu, "full")
end

--------------------------------------------------------------------
-- Search
--------------------------------------------------------------------

function Matter:showSearchDialog()
    local search_dialog
    search_dialog = MultiInputDialog:new{
        title = _("Search Matter"),
        fields = {
            { text = "", hint = _("Query (min 2 chars)") },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function()
                    UIManager:close(search_dialog)
                end },
                { text = _("Search"), is_enter_default = true, callback = function()
                    local fields = search_dialog:getFields()
                    local query = (fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(search_dialog)
                    if #query < 2 then
                        UIManager:show(InfoMessage:new{ text = _("Query must be at least 2 characters.") })
                        return
                    end
                    self:runSearch(query)
                end },
            },
        },
    }
    UIManager:show(search_dialog)
    search_dialog:onShowKeyboard()
end

function Matter:runSearch(query_text)
    UIManager:show(InfoMessage:new{ text = _("Searching..."), timeout = 1 })
    local ok, body, code = self:apiRequest{
        method = "GET", path = "/search",
        query = { query = query_text, type = "items",
                  limit = tostring(self.article_limit or 50) },
    }
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Search failed: %1"), self:errorMessage(body, code)),
        })
        return
    end
    local data = self:decodeJson(body)
    local items = data and data.search_results and data.search_results.items
        and data.search_results.items.results
    if not items or #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No matches.") })
        return
    end
    self:showItemMenu(items, nil, T(_("Search: %1"), query_text))
end

--------------------------------------------------------------------
-- Bulk download
--------------------------------------------------------------------

function Matter:showBulkDownloadDialog()
    local source_choices = {
        { text = _("Inbox"),     query = { status = "inbox" } },
        { text = _("Queue"),     query = { status = "queue" } },
        { text = _("Favorites"), query = { is_favorite = "true" } },
        { text = _("Archive"),   query = { status = "archive" } },
    }
    local selected_idx = 2  -- default to Queue
    local days_limit = 0
    local archive_after = self.settings:readSetting("bulk_archive_after") or false
    local delete_after  = self.settings:readSetting("bulk_delete_after")  or false

    local function sourceLabel() return source_choices[selected_idx].text end
    local function daysLabel()
        if days_limit == 0 then return _("All time") end
        return T(_("Last %1 days"), tostring(days_limit))
    end

    local bulk_dialog
    local function rebuildDialog()
        if bulk_dialog then UIManager:close(bulk_dialog) end
        bulk_dialog = ButtonDialog:new{
            title = _("Bulk download settings")
                .. "\n" .. _("Source: ") .. sourceLabel()
                .. "\n" .. _("Period: ") .. daysLabel()
                .. "\n" .. _("Archive after: ") .. (archive_after and _("Yes") or _("No"))
                .. "\n" .. _("Delete after: ")  .. (delete_after  and _("Yes") or _("No")),
            buttons = {
                {
                    { text = _("< Source >"), callback = function()
                        selected_idx = (selected_idx % #source_choices) + 1
                        rebuildDialog()
                    end },
                    { text = _("< Period >"), callback = function()
                        UIManager:close(bulk_dialog)
                        local spin = SpinWidget:new{
                            title_text = _("Days limit (0 = all)"),
                            value = days_limit, value_min = 0, value_max = 365, value_step = 1,
                            ok_text = _("Set"),
                            callback = function(spin_widget)
                                days_limit = spin_widget.value
                                rebuildDialog()
                            end,
                            cancel_callback = function() rebuildDialog() end,
                        }
                        UIManager:show(spin)
                    end },
                },
                {
                    { text = _("Archive after: ") .. (archive_after and _("ON") or _("OFF")),
                      callback = function()
                          archive_after = not archive_after
                          if archive_after then delete_after = false end
                          rebuildDialog()
                      end },
                    { text = _("Delete after: ") .. (delete_after and _("ON") or _("OFF")),
                      callback = function()
                          delete_after = not delete_after
                          if delete_after then archive_after = false end
                          rebuildDialog()
                      end },
                },
                {
                    { text = _("Start download"), callback = function()
                        UIManager:close(bulk_dialog)
                        self.settings:saveSetting("bulk_archive_after", archive_after)
                        self.settings:saveSetting("bulk_delete_after",  delete_after)
                        self.settings:flush()
                        self:runBulkDownload(
                            source_choices[selected_idx].query,
                            days_limit, archive_after, delete_after)
                    end },
                    { text = _("Cancel"), callback = function()
                        UIManager:close(bulk_dialog)
                    end },
                },
            },
        }
        UIManager:show(bulk_dialog)
    end
    rebuildDialog()
end

-- Convert N days ago to an ISO 8601 UTC timestamp.
local function days_ago_iso(days)
    if not days or days <= 0 then return nil end
    local t = os.time() - (days * 86400)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

function Matter:runBulkDownload(base_query, days_limit, archive_after, delete_after)
    UIManager:show(InfoMessage:new{ text = _("Fetching item list..."), timeout = 1 })

    local query = {}
    for k, v in pairs(base_query or {}) do query[k] = v end
    query.limit = "100"
    local since = days_ago_iso(days_limit)
    if since then query.updated_since = since end

    -- Page through everything
    local items = {}
    local cursor
    repeat
        local page, err_or_cursor = self:fetchItemsPage(query, cursor)
        if not page then
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to fetch items: %1"), err_or_cursor or ""),
            })
            return
        end
        for _, it in ipairs(page) do items[#items + 1] = it end
        cursor = err_or_cursor  -- second return is next cursor when first is non-nil
    until cursor == nil

    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No items match the selected filters.") })
        return
    end

    -- Stay under the 20/min markdown rate limit (3s between calls = 20/min).
    local socket = require("socket")
    local downloaded, failed = 0, 0
    for _, it in ipairs(items) do
        local full, err = self:fetchItemWithMarkdown(it.id)
        if full and full.markdown then
            for k, v in pairs(full) do it[k] = v end
            local saved = self:saveItemFromMarkdown(it, it.markdown)
            if saved then
                downloaded = downloaded + 1
                if archive_after then
                    self:apiRequest{ method = "PATCH", path = "/items/" .. it.id,
                        body_table = { status = "archive" } }
                elseif delete_after then
                    self:apiRequest{ method = "DELETE", path = "/items/" .. it.id }
                end
            else
                failed = failed + 1
            end
        else
            logger.warn("Matter bulk: failed to download", it.id, err)
            failed = failed + 1
        end
        socket.sleep(3)
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Bulk download complete.\nDownloaded: %1  Failed: %2"),
            tostring(downloaded), tostring(failed)),
    })
end

--------------------------------------------------------------------
-- Downloads folder maintenance
--------------------------------------------------------------------

function Matter:isDangerousPath(path)
    if not path or path == "" then return false end
    local normalized = path:gsub("//+", "/"):gsub("/$", "")
    local dangerous = {
        "/", "/mnt", "/mnt/onboard", "/mnt/sd", "/mnt/us",
        "/mnt/us/documents", "/sdcard", "/storage", "/system",
        "/data", "/etc", "/bin", "/usr", "/lib", "/home", "/root",
    }
    for _, d in ipairs(dangerous) do
        if normalized == d then return true end
    end
    return false
end

function Matter:clearDownloadsCache()
    local dir = self:getDownloadDir()
    local ConfirmBox = require("ui/widget/confirmbox")

    if self.cache_folder and self.cache_folder ~= "" then
        UIManager:show(InfoMessage:new{
            text = _("Cache clearing is disabled when using a custom cache folder for safety reasons.\n\nTo clear the cache, please manually delete Matter files from your custom folder."),
        })
        return
    end
    if self:isDangerousPath(dir) then
        UIManager:show(InfoMessage:new{
            text = _("Cannot clear cache: the cache folder path appears to be a system directory.\n\nPlease check your cache folder settings."),
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Delete Matter files (.html, .epub, .sdr, .tmp) from the downloads folder?"),
        ok_text = _("Delete"),
        ok_callback = function() self:_doClearDownloadsCache(dir) end,
    })
end

function Matter:_doClearDownloadsCache(dir)
    local function isMatterFile(filename)
        local lower = filename:lower()
        return lower:match("%.html$") or lower:match("%.epub$")
            or lower:match("%.sdr$") or lower:match("%.tmp$")
    end

    local function remove(path)
        local attr = lfs.attributes(path)
        if not attr then return 0 end
        local removed = 0
        if attr.mode == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    removed = removed + remove(path .. "/" .. entry)
                end
            end
            if path:match("%.sdr$") then lfs.rmdir(path) end
        else
            if isMatterFile(path) then os.remove(path); removed = 1 end
        end
        return removed
    end

    local count = 0
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            count = count + remove(dir .. "/" .. entry)
        end
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Deleted %1 Matter file(s) from downloads folder."), count),
        timeout = 3,
    })
end

function Matter:openDownloadsFolder()
    local dir = self:getDownloadDir()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:reinit(dir)
    else
        FileManager:showFiles(dir)
    end
end

--------------------------------------------------------------------
-- Save URL: pending pool & API
--------------------------------------------------------------------

function Matter:loadPendingPool()
    self.pending_pool = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/matter_pending.lua")
end

function Matter:getPendingUrls()
    if not self.pending_pool then self:loadPendingPool() end
    return self.pending_pool:readSetting("pending_urls") or {}
end

function Matter:savePendingUrls(urls)
    if not self.pending_pool then self:loadPendingPool() end
    self.pending_pool:saveSetting("pending_urls", urls)
    self.pending_pool:flush()
end

function Matter:addToPendingPool(url, title)
    local pending = self:getPendingUrls()
    table.insert(pending, { url = url, title = title or url, added_at = os.time() })
    self:savePendingUrls(pending)
end

function Matter:countPending()
    return #self:getPendingUrls()
end

function Matter:saveItemByUrl(url)
    if not url or url == "" then return false, "empty_url" end
    local ok, body, code = self:apiRequest{
        method = "POST", path = "/items",
        body_table = { url = url, status = "queue" },
    }
    if ok then
        logger.info("Matter: saved", url)
        return true
    end
    return false, self:errorMessage(body, code)
end

function Matter:drainPendingQueue(opts)
    opts = opts or {}
    if self._draining then return end
    if not self:isLoggedIn() then return end
    if not NetworkMgr:isOnline() then return end

    local pending = self:getPendingUrls()
    if #pending == 0 then return end

    self._draining = true
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local success_count, fail_count = 0, 0
        local remaining = {}
        local stopped_for_network = false
        local last_err

        for _, item in ipairs(pending) do
            if stopped_for_network then
                table.insert(remaining, item)
            else
                local ok, err = self:saveItemByUrl(item.url)
                if ok then
                    success_count = success_count + 1
                else
                    fail_count = fail_count + 1
                    last_err = err
                    if not NetworkMgr:isOnline() then
                        stopped_for_network = true
                    end
                    table.insert(remaining, item)
                end
            end
        end

        self:savePendingUrls(remaining)
        self._draining = false
        if opts.silent then return end
        if success_count == 0 and fail_count == 0 then return end

        local parts = {}
        if success_count > 0 then
            table.insert(parts, T(_("Sent %1 pending URL(s) to Matter."), success_count))
        end
        if fail_count > 0 then
            table.insert(parts, T(_("Failed: %1"), fail_count))
            if last_err then table.insert(parts, "(" .. last_err .. ")") end
        end
        if #remaining > 0 then
            table.insert(parts, T(_("%1 still pending."), #remaining))
        end

        local Notification = require("ui/widget/notification")
        UIManager:show(Notification:new{ text = table.concat(parts, " ") })
    end)
end

function Matter:processPendingPool()
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{ text = _("Please set your Matter API token first.") })
        return
    end
    local pending = self:getPendingUrls()
    if #pending == 0 then
        UIManager:show(InfoMessage:new{ text = _("No pending URLs."), timeout = 2 })
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:drainPendingQueue({ silent = false })
    end)
end

--------------------------------------------------------------------
-- Auto-sync progress on document close
--------------------------------------------------------------------

-- Pending progress updates, keyed by item id. Each later update overwrites
-- the previous one for the same item, so we never push stale percentages.
function Matter:queueProgressUpdate(item_id, percent)
    if not self.pending_pool then self:loadPendingPool() end
    local pending = self.pending_pool:readSetting("pending_progress") or {}
    pending[item_id] = { percent = percent, ts = os.time() }
    self.pending_pool:saveSetting("pending_progress", pending)
    self.pending_pool:flush()
end

-- Push `percent` to Matter only if it would *advance* the item's progress.
-- Returns one of: "pushed", "skipped_already_ahead", "skipped_zero", "failed".
-- This prevents auto-push from overwriting a more-recent read on web/mobile
-- with a stale local position from KOReader.
function Matter:safePushProgress(item_id, percent)
    -- Never push a zero/near-zero progress: it can't advance Matter's state,
    -- and if Matter is at some non-zero value this would regress it.
    if percent <= 0.001 then return "skipped_zero" end

    -- Verify Matter's current value before pushing. If we can't read it
    -- (network, 5xx, transient outage), do NOT push — a blind PATCH risks
    -- writing a regression. Caller is expected to queue for retry.
    local ok_get, body = self:apiRequest{
        method = "GET", path = "/items/" .. item_id,
    }
    if not ok_get then return "failed" end
    local data = self:decodeJson(body)
    local current = data and tonumber(data.reading_progress) or 0
    if current >= percent then return "skipped_already_ahead", current end

    local ok = self:apiRequest{
        method = "PATCH", path = "/items/" .. item_id,
        body_table = { reading_progress = percent },
    }
    return ok and "pushed" or "failed"
end

function Matter:drainPendingProgress(opts)
    opts = opts or {}
    if not self:isLoggedIn() then return end
    if not NetworkMgr:isOnline() then return end
    if not self.pending_pool then self:loadPendingPool() end

    local pending = self.pending_pool:readSetting("pending_progress") or {}
    if not next(pending) then return end

    local remaining = {}
    local sent = 0
    for item_id, entry in pairs(pending) do
        local status = self:safePushProgress(item_id, entry.percent)
        if status == "pushed" or status == "skipped_already_ahead" then
            if status == "pushed" then sent = sent + 1 end
            -- Either way, drop from queue: pushed means done, already-ahead
            -- means the queued value is stale and would never be valid.
        else
            remaining[item_id] = entry
        end
    end
    self.pending_pool:saveSetting("pending_progress", remaining)
    self.pending_pool:flush()
    if sent > 0 and not opts.silent then
        local Notification = require("ui/widget/notification")
        UIManager:show(Notification:new{
            text = T(_("Synced %1 progress update(s) to Matter."), sent),
        })
    end
end

-- Fire-and-forget push for a single item's progress, queuing on failure.
-- Won't downgrade Matter's progress — if Matter is already further ahead
-- (e.g. the user read on web since closing here), the push is silently
-- skipped instead of clobbering the more-recent value.
function Matter:pushProgressForItem(item_id, percent)
    if not item_id or type(percent) ~= "number" then return end
    if percent < 0 then percent = 0 end
    if percent > 1 then percent = 1 end
    if not self:isLoggedIn() then
        self:queueProgressUpdate(item_id, percent)
        return
    end
    if not NetworkMgr:isOnline() then
        self:queueProgressUpdate(item_id, percent)
        return
    end
    local status = self:safePushProgress(item_id, percent)
    if status == "failed" then self:queueProgressUpdate(item_id, percent) end
end

-- Called by KOReader when a document is being closed. If the document is a
-- Matter download and auto-sync is enabled, push the final progress upstream.
function Matter:onCloseDocument()
    if not self.auto_sync_progress then return end
    local item_id = self:identifyOpenMatterDoc()
    if not item_id then return end

    local percent
    if self.ui.doc_settings then
        percent = self.ui.doc_settings:readSetting("percent_finished")
    end
    if type(percent) ~= "number" then return end

    self:pushProgressForItem(item_id, percent)
end

function Matter:saveLinkFromDocument(url, title)
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new{
            text = _("Please set your Matter API token first."), timeout = 2,
        })
        return
    end
    if NetworkMgr:isOnline() then
        local ok = self:saveItemByUrl(url)
        if ok then
            UIManager:show(InfoMessage:new{ text = _("Saved to Matter."), timeout = 2 })
        else
            self:addToPendingPool(url, title)
            UIManager:show(InfoMessage:new{ text = _("Failed. Added to pending pool."), timeout = 2 })
        end
        return
    end
    if self.auto_connect_network then
        NetworkMgr:runWhenOnline(function()
            local ok = self:saveItemByUrl(url)
            if ok then
                UIManager:show(InfoMessage:new{ text = _("Saved to Matter."), timeout = 2 })
            else
                self:addToPendingPool(url, title)
                UIManager:show(InfoMessage:new{ text = _("Failed. Added to pending pool."), timeout = 2 })
            end
        end)
    else
        self:addToPendingPool(url, title)
        UIManager:show(InfoMessage:new{ text = _("Added to pending pool."), timeout = 2 })
    end
end

function Matter:registerLinkPopupButton()
    if not self.ui or not self.ui.link then return end
    local Blitbuffer = require("ffi/blitbuffer")
    self.ui.link:addToExternalLinkDialog("45_save_to_matter", function(external_dialog, link_url)
        return {
            text = _("Save to Matter"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(external_dialog.external_link_dialog)
                local target_url = link_url
                if type(target_url) ~= "string" or not target_url:match("^https?://") then
                    UIManager:show(InfoMessage:new{ text = _("Invalid URL."), timeout = 2 })
                    return
                end
                self:saveLinkFromDocument(target_url, target_url)
            end,
            show_in_dialog_func = function()
                return type(link_url) == "string" and link_url:match("^https?://") ~= nil
            end,
        }
    end)
end

return Matter
