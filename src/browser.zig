const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
usingnamespace @import("util.zig");

// Currently opened directory and its parents.
var dir_parents = model.Parents{};

// Sorted list of all items in the currently opened directory.
// (first item may be null to indicate the "parent directory" item)
var dir_items = std.ArrayList(?*model.Entry).init(main.allocator);

// Index into dir_items that is currently selected.
var cursor_idx: usize = 0;

const View = struct {
    // Index into dir_items, indicates which entry is displayed at the top of the view.
    // This is merely a suggestion, it will be adjusted upon drawing if it's
    // out of bounds or if the cursor is not otherwise visible.
    top: usize = 0,

    // The hash(name) of the selected entry (cursor), this is used to derive
    // cursor_idx after sorting or changing directory.
    // (collisions may cause the wrong entry to be selected, but dealing with
    // string allocations sucks and I expect collisions to be rare enough)
    cursor_hash: u64 = 0,

    fn hashEntry(entry: ?*model.Entry) u64 {
        return if (entry) |e| std.hash.Wyhash.hash(0, e.name()) else 0;
    }

    // Update cursor_hash and save the current view to the hash table.
    fn save(self: *@This()) void {
        self.cursor_hash = if (dir_items.items.len == 0) 0
                           else hashEntry(dir_items.items[cursor_idx]);
        opened_dir_views.put(@ptrToInt(dir_parents.top()), self.*) catch {};
    }

    // Should be called after dir_parents or dir_items has changed, will load the last saved view and find the proper cursor_idx.
    fn load(self: *@This()) void {
        if (opened_dir_views.get(@ptrToInt(dir_parents.top()))) |v| self.* = v
        else self.* = @This(){};
        cursor_idx = 0;
        for (dir_items.items) |e, i| {
            if (self.cursor_hash == hashEntry(e)) {
                cursor_idx = i;
                break;
            }
        }
    }
};

var current_view = View{};

// Directories the user has browsed to before, and which item was last selected.
// The key is the @ptrToInt() of the opened *Dir; An int because the pointer
// itself may have gone stale after deletion or refreshing. They're only for
// lookups, not dereferencing.
var opened_dir_views = std.AutoHashMap(usize, View).init(main.allocator);

fn sortIntLt(a: anytype, b: @TypeOf(a)) ?bool {
    return if (a == b) null else if (main.config.sort_order == .asc) a < b else a > b;
}

fn sortLt(_: void, ap: ?*model.Entry, bp: ?*model.Entry) bool {
    const a = ap.?;
    const b = bp.?;

    if (main.config.sort_dirsfirst and (a.etype == .dir) != (b.etype == .dir))
        return a.etype == .dir;

    switch (main.config.sort_col) {
        .name => {}, // name sorting is the fallback
        .blocks => {
            if (sortIntLt(a.blocks, b.blocks)) |r| return r;
            if (sortIntLt(a.size, b.size)) |r| return r;
        },
        .size => {
            if (sortIntLt(a.size, b.size)) |r| return r;
            if (sortIntLt(a.blocks, b.blocks)) |r| return r;
        },
        .items => {
            const ai = if (a.dir()) |d| d.total_items else 0;
            const bi = if (b.dir()) |d| d.total_items else 0;
            if (sortIntLt(ai, bi)) |r| return r;
            if (sortIntLt(a.blocks, b.blocks)) |r| return r;
            if (sortIntLt(a.size, b.size)) |r| return r;
        },
        .mtime => {
            if (!a.isext or !b.isext) return a.isext;
            if (sortIntLt(a.ext().?.mtime, b.ext().?.mtime)) |r| return r;
        },
    }

    // TODO: Unicode-aware sorting might be nice (and slow)
    const an = a.name();
    const bn = b.name();
    return if (main.config.sort_order == .asc) std.mem.lessThan(u8, an, bn)
           else std.mem.lessThan(u8, bn, an) or std.mem.eql(u8, an, bn);
}

// Should be called when:
// - config.sort_* changes
// - dir_items changes (i.e. from loadDir())
// - files in this dir have changed in a way that affects their ordering
fn sortDir() void {
    // No need to sort the first item if that's the parent dir reference,
    // excluding that allows sortLt() to ignore null values.
    const lst = dir_items.items[(if (dir_items.items.len > 0 and dir_items.items[0] == null) @as(usize, 1) else 0)..];
    std.sort.sort(?*model.Entry, lst, @as(void, undefined), sortLt);
    current_view.load();
}

// Must be called when:
// - dir_parents changes (i.e. we change directory)
// - config.show_hidden changes
// - files in this dir have been added or removed
pub fn loadDir() !void {
    dir_items.shrinkRetainingCapacity(0);
    if (dir_parents.top() != model.root)
        try dir_items.append(null);
    var it = dir_parents.top().sub;
    while (it) |e| {
        if (main.config.show_hidden) // fast path
            try dir_items.append(e)
        else {
            const excl = if (e.file()) |f| f.excluded else false;
            const name = e.name();
            if (!excl and name[0] != '.' and name[name.len-1] != '~')
                try dir_items.append(e);
        }
        it = e.next;
    }
    sortDir();
}

const Row = struct {
    row: u32,
    col: u32 = 0,
    bg: ui.Bg = .default,
    item: ?*model.Entry,

    const Self = @This();

    fn flag(self: *Self) !void {
        defer self.col += 2;
        const item = self.item orelse return;
        const ch: u7 = ch: {
            if (item.file()) |f| {
                if (f.err) break :ch '!';
                if (f.excluded) break :ch '<';
                if (f.other_fs) break :ch '>';
                if (f.kernfs) break :ch '^';
                if (f.notreg) break :ch '@';
            } else if (item.dir()) |d| {
                if (d.err) break :ch '!';
                if (d.suberr) break :ch '.';
                if (d.sub == null) break :ch 'e';
            } else if (item.link()) |_| break :ch 'H';
            return;
        };
        ui.move(self.row, self.col);
        self.bg.fg(.flag);
        ui.addch(ch);
    }

    fn size(self: *Self) !void {
        defer self.col += if (main.config.si) @as(u32, 9) else 10;
        const item = self.item orelse return;
        ui.move(self.row, self.col);
        ui.addsize(self.bg, if (main.config.show_blocks) blocksToSize(item.blocks) else item.size);
        // TODO: shared sizes
    }

    fn name(self: *Self) !void {
        ui.move(self.row, self.col);
        self.bg.fg(.default);
        if (self.item) |i| {
            ui.addch(if (i.etype == .dir) '/' else ' ');
            ui.addstr(try ui.shorten(try ui.toUtf8(i.name()), saturateSub(ui.cols, self.col + 1)));
        } else
            ui.addstr("/..");
    }

    fn draw(self: *Self) !void {
        if (self.bg == .sel) {
            self.bg.fg(.default);
            ui.move(self.row, 0);
            ui.hline(' ', ui.cols);
        }
        try self.flag();
        try self.size();
        try self.name();
    }
};

var need_confirm_quit = false;

fn drawQuit() void {
    const box = ui.Box.create(4, 22, "Confirm quit");
    box.move(2, 2);
    ui.addstr("Really quit? (");
    ui.style(.key);
    ui.addch('y');
    ui.style(.default);
    ui.addch('/');
    ui.style(.key);
    ui.addch('N');
    ui.style(.default);
    ui.addch(')');
}

pub fn draw() !void {
    ui.style(.hd);
    ui.move(0,0);
    ui.hline(' ', ui.cols);
    ui.move(0,0);
    ui.addstr("ncdu " ++ main.program_version ++ " ~ Use the arrow keys to navigate, press ");
    ui.style(.key_hd);
    ui.addch('?');
    ui.style(.hd);
    ui.addstr(" for help");
    if (main.config.read_only) {
        ui.move(0, saturateSub(ui.cols, 10));
        ui.addstr("[readonly]");
    }
    // TODO: [imported] indicator

    ui.style(.default);
    ui.move(1,0);
    ui.hline('-', ui.cols);
    ui.move(1,3);
    ui.addch(' ');
    ui.addstr(try ui.shorten(try ui.toUtf8(model.root.entry.name()), saturateSub(ui.cols, 5)));
    ui.addch(' ');

    const numrows = saturateSub(ui.rows, 3);
    if (cursor_idx < current_view.top) current_view.top = cursor_idx;
    if (cursor_idx >= current_view.top + numrows) current_view.top = cursor_idx - numrows + 1;

    var i: u32 = 0;
    while (i < numrows) : (i += 1) {
        if (i+current_view.top >= dir_items.items.len) break;
        var row = Row{
            .row = i+2,
            .item = dir_items.items[i+current_view.top],
            .bg = if (i+current_view.top == cursor_idx) .sel else .default,
        };
        try row.draw();
    }

    ui.style(.hd);
    ui.move(ui.rows-1, 0);
    ui.hline(' ', ui.cols);
    ui.move(ui.rows-1, 1);
    ui.addstr("Total disk usage: ");
    ui.addsize(.hd, blocksToSize(dir_parents.top().entry.blocks));
    ui.addstr("  Apparent size: ");
    ui.addsize(.hd, dir_parents.top().entry.size);
    ui.addstr("  Items: ");
    ui.addnum(.hd, dir_parents.top().total_items);

    if (need_confirm_quit) drawQuit();
}

fn sortToggle(col: main.SortCol, default_order: main.SortOrder) void {
    if (main.config.sort_col != col) main.config.sort_order = default_order
    else if (main.config.sort_order == .asc) main.config.sort_order = .desc
    else main.config.sort_order = .asc;
    main.config.sort_col = col;
    sortDir();
}

pub fn key(ch: i32) !void {
    if (need_confirm_quit) {
        switch (ch) {
            'y', 'Y' => if (need_confirm_quit) ui.quit(),
            else => need_confirm_quit = false,
        }
        return;
    }

    defer current_view.save();

    switch (ch) {
        'q' => if (main.config.confirm_quit) { need_confirm_quit = true; } else ui.quit(),

        // Selection
        'j', ui.c.KEY_DOWN => {
            if (cursor_idx+1 < dir_items.items.len) cursor_idx += 1;
        },
        'k', ui.c.KEY_UP => {
            if (cursor_idx > 0) cursor_idx -= 1;
        },
        ui.c.KEY_HOME => cursor_idx = 0,
        ui.c.KEY_END, ui.c.KEY_LL => cursor_idx = saturateSub(dir_items.items.len, 1),
        ui.c.KEY_PPAGE => cursor_idx = saturateSub(cursor_idx, saturateSub(ui.rows, 3)),
        ui.c.KEY_NPAGE => cursor_idx = std.math.min(saturateSub(dir_items.items.len, 1), cursor_idx + saturateSub(ui.rows, 3)),

        // Sort & filter settings
        'n' => sortToggle(.name, .asc),
        's' => sortToggle(if (main.config.show_blocks) .blocks else .size, .desc),
        'C' => sortToggle(.items, .desc),
        'M' => if (main.config.extended) sortToggle(.mtime, .desc),
        'e' => {
            main.config.show_hidden = !main.config.show_hidden;
            try loadDir();
        },
        't' => {
            main.config.sort_dirsfirst = !main.config.sort_dirsfirst;
            sortDir();
        },
        'a' => {
            main.config.show_blocks = !main.config.show_blocks;
            if (main.config.show_blocks and main.config.sort_col == .size) {
                main.config.sort_col = .blocks;
                sortDir();
            }
            if (!main.config.show_blocks and main.config.sort_col == .blocks) {
                main.config.sort_col = .size;
                sortDir();
            }
        },

        // Navigation
        10, 'l', ui.c.KEY_RIGHT => {
            if (dir_items.items.len == 0) {
            } else if (dir_items.items[cursor_idx]) |e| {
                if (e.dir()) |d| {
                    try dir_parents.push(d);
                    try loadDir();
                }
            } else if (dir_parents.top() != model.root) {
                dir_parents.pop();
                try loadDir();
            }
        },
        'h', '<', ui.c.KEY_BACKSPACE, ui.c.KEY_LEFT => {
            if (dir_parents.top() != model.root) {
                dir_parents.pop();
                try loadDir();
            }
        },

        else => {}
    }
}
