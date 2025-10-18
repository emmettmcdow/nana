fn upgrade_zero(db: *model.DB) !void {
    try db.setVersion("1");
    return;
}

pub fn migrate(db: *model.DB) void {
    const from = db.version();
    const to = model.LATEST_V;

    if (from == to) return;
    db.backup();

    db.startTX();
    errdefer db.dropTX();
    for (from..to + 1) |v| {
        switch (v) {
            0 => try upgrade_zero(db),
            else => unreachable,
        }
    }

    db.commitTX();
    return;
}

const model = @import("model.zig");
