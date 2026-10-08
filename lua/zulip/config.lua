--- Options; `require("zulip").setup` overrides them in place.
return {
    --- File with the account's `email`, `key` and `site`, as downloaded from Zulip.
    zuliprc = "~/.zuliprc",
    --- Sidebar refresh period.
    refresh_ms = 10000,
    --- How many of the newest messages the sidebar groups into conversations.
    n_recent = 500,
    --- How many of its newest messages a conversation buffer shows.
    n_shown = 100,
    --- Whether opening a conversation marks its messages as read.
    mark_read = true,
    sidebar_width = 40,
    compose_height = 10,
    --- Global mappings; set one to `false` to skip it.
    keys = {
        toggle = "<leader>oz",
    },
}
