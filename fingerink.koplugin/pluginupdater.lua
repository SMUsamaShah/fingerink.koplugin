-- Reusable updater for a public GitHub repository; uses only KOReader modules.
-- Copy this file into another plugin, then append this item to its menu:
--   local updater = dofile(plugin_dir .. "pluginupdater.lua").new{
--       repository = "owner/repo", branch = "main", folder = "name.koplugin",
--   }
--   items[#items + 1] = updater:menuItem()
-- Use folder = "" when the plugin files live at the repository root.
-- The installation directory is inferred from THIS file's location.
-- Store user data in KOReader's settings directory: updates replace the whole
-- plugin folder. One previous copy is retained beside it as .update-backup.
local Updater = {}
Updater.__index = Updater
local module_dir = assert(debug.getinfo(1, "S").source:match("^@(.*/)"))
local MAX_FILE, MAX_TOTAL, MAX_FILES = 8 * 1024 * 1024, 32 * 1024 * 1024, 512

local function check(ok, message)
    if not ok then error(message or "Plugin update failed.", 0) end
    return ok
end

local function safePath(path)
    if type(path) ~= "string" or path == "" or path:find("^/")
        or path:find("//") or path:find("/$") or path:find('[%c\\:*?"<>|]') then return false end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." or part:find("[. ]$") then return false end
    end
    return true
end

local function escape(value, keep_slashes)
    return (value:gsub(keep_slashes and "[^%w%-._~/]" or "[^%w%-._~]",
        function(c) return string.format("%%%02X", c:byte()) end))
end

-- LuaSec checks the certificate chain with verify=peer, but not the hostname.
-- Check DNS subjectAltNames too, allowing a wildcard for exactly one label.
local function tlsSocket()
    local conn = require("ssl.https").tcp{
        verify = "peer", cafile = "data/ca-bundle.crt", protocol = "tlsv1_2",
    }()
    local connect = conn.connect
    function conn:connect(host, port)
        local ok, err = connect(self, host, port)
        if not ok then return nil, err end
        local cert = self:getpeercertificate()
        local san = cert and cert:extensions()["2.5.29.17"]
        for _, name in ipairs(san and san.dNSName or {}) do
            name = name:lower()
            if name == host or (name:sub(1, 2) == "*."
                and host:match("^[^.]+(%..+)$") == name:sub(2)) then return 1 end
        end
        self:close()
        return nil, "GitHub TLS hostname verification failed."
    end
    return conn
end

local function get(url, limit)
    local http = require("socket.http")
    local socketutil = require("socketutil")
    check(not http.PROXY, "Plugin updates do not support an HTTP proxy.")
    local chunks, size = {}, 0
    local old_block, old_total = socketutil.block_timeout, socketutil.total_timeout
    socketutil:set_timeout(15, 60)
    local sink = socketutil.table_sink(chunks)
    local ok, result, code = pcall(http.request, {
        url = url, create = tlsSocket, redirect = false,
        headers = { ["user-agent"] = socketutil.USER_AGENT,
            accept = "application/vnd.github+json" },
        sink = function(chunk, err)
            if chunk then
                size = size + #chunk
                if size > limit then return nil, "Download exceeds the plugin update size limit." end
            end
            return sink(chunk, err)
        end,
    })
    socketutil:set_timeout(old_block, old_total)
    check(ok, tostring(result))
    if code == 403 or code == 429 then
        error("GitHub refused the request or its rate limit was reached. Try again later.", 0)
    end
    check(result and code == 200, "GitHub download failed (" .. tostring(code)
        .. "). Check Wi-Fi, repository/branch settings, and the Kindle's date/time.")
    return table.concat(chunks)
end

function Updater.new(options)
    check(type(options.repository) == "string"
        and options.repository:match("^[%w_.-]+/[%w_.-]+$"), "Use repository = 'owner/repo'.")
    check(options.folder == "" or safePath(options.folder), "Invalid plugin folder in repository.")
    return setmetatable({ repository = options.repository, branch = options.branch or "main",
        folder = options.folder, directory = module_dir:gsub("/$", ""),
        can_update = options.can_update }, Updater)
end

-- Runs in a cancellable subprocess. No installed files are written here.
function Updater:download()
    local json = require("rapidjson")
    local sha1 = require("ffi/sha2").sha1
    local api = "https://api.github.com/repos/" .. self.repository
    local commit = json.decode(get(api .. "/commits/" .. escape(self.branch), MAX_FILE))
    local revision = commit.sha
    check(type(revision) == "string" and #revision == 40 and revision:match("^%x+$"),
        "GitHub returned an invalid revision.")
    local tree = json.decode(get(api .. "/git/trees/" .. commit.commit.tree.sha .. "?recursive=1", MAX_FILE))
    check(not tree.truncated and type(tree.tree) == "table", "GitHub returned an incomplete file list.")
    local prefix = self.folder == "" and "" or self.folder .. "/"
    local files, names, total = {}, {}, 0
    for _, entry in ipairs(tree.tree) do
        if entry.path:sub(1, #prefix) == prefix and entry.type ~= "tree" then
            local path = entry.path:sub(#prefix + 1)
            check(safePath(path), "Unsupported file path: " .. path)
            check(entry.type == "blob" and (entry.mode == "100644" or entry.mode == "100755"),
                "Symlinks and submodules are unsupported: " .. path)
            check(not names[path:lower()], "Conflicting file names: " .. path)
            check(type(entry.size) == "number" and entry.size >= 0 and entry.size <= MAX_FILE,
                "File exceeds 8 MiB: " .. path)
            names[path:lower()] = path
            total = total + entry.size
            files[#files + 1] = { path = path, size = entry.size, sha = entry.sha, mode = entry.mode }
        end
    end
    check(names["main.lua"] == "main.lua" and names["_meta.lua"] == "_meta.lua",
        "The selected GitHub folder is not a KOReader plugin.")
    check(#files <= MAX_FILES and total <= MAX_TOTAL, "Plugin exceeds 512 files or 32 MiB.")
    for _, file in ipairs(files) do
        file.data = get("https://raw.githubusercontent.com/" .. self.repository .. "/"
            .. revision .. "/" .. escape(prefix .. file.path, true), MAX_FILE)
        check(#file.data == file.size and sha1("blob " .. #file.data .. "\0" .. file.data) == file.sha,
            "Download integrity check failed: " .. file.path)
        if file.path:match("%.lua$") then
            local compiled, err = loadstring(file.data, "@" .. file.path)
            check(compiled, "Downloaded Lua file cannot be compiled: " .. tostring(err))
        end
    end
    return { revision = revision, files = files }
end

-- Do not follow symlinks while cleaning our staging/backup directories.
local function removeTree(path)
    local lfs = require("libs/libkoreader-lfs")
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then removeTree(path .. "/" .. name) end
        end
        check(lfs.rmdir(path))
    elseif mode then check(os.remove(path)) end
end

-- Local transaction: write and close everything first, then swap folders.
-- If the second rename fails, put the original folder back immediately.
function Updater:install(package)
    local lfs = require("libs/libkoreader-lfs")
    local util = require("util")
    local dir = self.directory
    check(dir:sub(-9) == ".koplugin" and lfs.symlinkattributes(dir, "mode") == "directory",
        "Install this updater inside a real .koplugin directory.")
    local stage, backup = dir .. ".update-stage", dir .. ".update-backup"
    local ok, err = pcall(function()
        removeTree(stage)
        check(lfs.mkdir(stage))
        for _, file in ipairs(package.files) do
            check(safePath(file.path), "Invalid installation path.")
            local parent = file.path:match("^(.*)/")
            if parent then check(util.makePath(stage .. "/" .. parent)) end
            local dest = stage .. "/" .. file.path
            local f, open_err = io.open(dest, "wb")
            check(f, open_err)
            local written, write_err = f:write(file.data)
            local closed, close_err = f:close()
            check(written and closed, write_err or close_err)
            if file.mode == "100755" then
                require("ffi/posix_h")
                check(require("ffi").C.chmod(dest, 493) == 0, "Cannot set executable permission: " .. file.path)
            end
        end
        removeTree(backup)
        check(os.rename(dir, backup))
        local installed, install_err = os.rename(stage, dir)
        if not installed then
            local restored, restore_err = os.rename(backup, dir)
            check(restored, "Could not restore plugin: " .. tostring(restore_err)
                .. ". The previous copy is at " .. backup)
            error("Installation failed; previous plugin restored: " .. tostring(install_err), 0)
        end
    end)
    if not ok then pcall(removeTree, stage); error(err, 0) end
end

function Updater:start()
    if self.busy then return end
    local UIManager = require("ui/uimanager")
    if self.updated then UIManager:askForRestart("Plugin updated. Restart KOReader to use it."); return end
    require("ui/network/manager"):runWhenConnected(function()
        if self.busy or (self.can_update and not self.can_update()) then return end
        self.busy = true
        require("ui/trapper"):wrap(function()
            local ok, result = pcall(function()
                local completed, downloaded, package = require("ui/trapper"):dismissableRunInSubprocess(
                    function() return pcall(self.download, self) end,
                    "Downloading plugin update…\n\nTap to cancel.")
                if not completed then return false end
                check(downloaded, tostring(package or "Download subprocess failed."))
                self:install(package)
                self.updated = true
                return true
            end)
            self.busy = false
            if not ok then
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = "Could not update plugin:\n\n" .. tostring(result) })
            elseif result then
                UIManager:askForRestart("Plugin updated. Restart KOReader to use it.")
            end
        end)
    end)
end

function Updater:menuItem()
    return { text = "update plugin", keep_menu_open = true,
        enabled_func = function() return not self.busy and (not self.can_update or self.can_update()) end,
        callback = function() self:start() end }
end

return Updater
