--- Visualizations in a conversation: uploaded images, and the first page of uploaded PDFs, show inline under their link
--- (snacks.nvim image support, e.g. Kitty's graphics protocol, also through tmux),
--- and `gx` opens the uploaded HTML on the line under the cursor.
local api = require("zulip.api")

local config = require("zulip.config")

local M = {}

local IMAGE = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

--- Each upload link in `line`, relative or with the server address: its path and lowercase extension.
function M.uploads(line)
    local found = {}
    for path in line:gmatch("%]%([^)%s]-(/user_uploads/[^)%s]+)%)") do
        found[#found + 1] = { path = path, ext = (path:match("%.(%w+)$") or ""):lower() }
    end
    return found
end

--- Local copy of the upload `path`, downloaded once.
local function fetch(path, on_file)
    local dest = vim.fs.joinpath(vim.fn.stdpath("cache"), "zulip", (path:gsub("^/user_uploads/", ""):gsub("[^%w._-]", "_")))
    if vim.uv.fs_stat(dest) then
        return on_file(dest)
    end
    api.download(path, dest, function(err)
        if err then
            return vim.notify("zulip: " .. err, vim.log.levels.WARN)
        end
        on_file(dest)
    end)
end

local function snacks_image()
    local ok, snacks = pcall(require, "snacks")
    return ok and snacks.image and snacks.image.supports_terminal() and snacks.image or nil
end

--- PNG of the first page of the local PDF `pdf`, rendered once with `pdftoppm`.
local function first_page(pdf, on_png)
    local png = pdf .. ".png"
    if vim.uv.fs_stat(png) then
        return on_png(png)
    end
    vim.system({ "pdftoppm", "-png", "-singlefile", "-f", "1", "-r", "100", pdf, pdf }, {}, vim.schedule_wrap(function(result)
        if result.code ~= 0 then
            return vim.notify("zulip: pdftoppm: " .. vim.trim(result.stderr), vim.log.levels.WARN)
        end
        on_png(png)
    end))
end

--- Show each uploaded image, and each uploaded PDF's first page, of `buf` inline below its line,
--- unless `config.previews` is off.
function M.show(buf)
    local image = snacks_image()
    if not image then
        return
    end
    image.placement.clean(buf)
    if not config.previews then
        return
    end
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        for _, upload in ipairs(M.uploads(line)) do
            local function place(file)
                if config.previews and vim.api.nvim_buf_is_valid(buf) then
                    local win = vim.fn.bufwinid(buf)
                    local width = vim.o.columns
                    if win ~= -1 then
                        local info = vim.fn.getwininfo(win)[1]
                        width = info.width - info.textoff
                    end
                    -- scale down to fit the window width
                    image.placement.new(buf, file, { pos = { row, 0 }, inline = true, max_width = math.max(1, width - 2) })
                end
            end
            if IMAGE[upload.ext] then
                fetch(upload.path, place)
            elseif upload.ext == "pdf" and vim.fn.executable("pdftoppm") == 1 then
                fetch(upload.path, function(file)
                    first_page(file, place)
                end)
            end
        end
    end
end

-- 🧑 "allow previews to be toggleable"
--- Turn previews on or off in every conversation buffer.
function M.toggle()
    config.previews = not config.previews
    for _, buf in pairs(require("zulip.conversation").bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
            M.show(buf)
        end
    end
end

--- Open the uploaded HTML (else any upload) on the cursor line:
--- with `viz` on PATH it goes to the viz page in the browser, else to `vim.ui.open`.
function M.open()
    local uploads = M.uploads(vim.api.nvim_get_current_line())
    table.sort(uploads, function(a, b)
        return (a.ext == "html") and b.ext ~= "html"
    end)
    local upload = uploads[1]
    if not upload then
        return vim.notify("zulip: no upload on this line", vim.log.levels.WARN)
    end
    fetch(upload.path, function(file)
        if vim.fn.executable("viz") == 1 then
            vim.system({ "viz", file, vim.fs.basename(upload.path) })
        else
            vim.ui.open(file)
        end
    end)
end

return M
