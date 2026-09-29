const std = @import("std");

pub const invalid_position: u32 = std.math.maxInt(u32);

pub const Node = struct {
    deadline: u64,
    index: u32,
};

pub const Heap = struct {
    nodes: []Node,
    positions: []u32,
    len: u32 = 0,

    pub fn init(nodes: []Node, positions: []u32) !Heap {
        if (nodes.len != positions.len or nodes.len > std.math.maxInt(u32)) return error.InvalidCapacity;
        @memset(positions, invalid_position);
        return .{ .nodes = nodes, .positions = positions };
    }

    fn less(a: Node, b: Node) bool {
        return a.deadline < b.deadline or (a.deadline == b.deadline and a.index < b.index);
    }

    fn swap(self: *Heap, a: u32, b: u32) void {
        std.mem.swap(Node, &self.nodes[a], &self.nodes[b]);
        self.positions[self.nodes[a].index] = a;
        self.positions[self.nodes[b].index] = b;
    }

    fn siftUp(self: *Heap, start: u32) void {
        var p = start;
        while (p != 0) {
            const parent = (p - 1) / 2;
            if (!less(self.nodes[p], self.nodes[parent])) break;
            self.swap(p, parent);
            p = parent;
        }
    }

    fn siftDown(self: *Heap, start: u32) void {
        var p = start;
        while (true) {
            const left = p * 2 + 1;
            if (left >= self.len) break;
            var best = left;
            const right = left + 1;
            if (right < self.len and less(self.nodes[right], self.nodes[left])) best = right;
            if (!less(self.nodes[best], self.nodes[p])) break;
            self.swap(p, best);
            p = best;
        }
    }

    pub fn insertOrUpdate(self: *Heap, index: u32, deadline: u64) bool {
        if (index >= self.positions.len) return false;
        const pos = self.positions[index];
        if (pos == invalid_position) {
            if (self.len >= self.nodes.len) return false;
            const p = self.len;
            self.len += 1;
            self.nodes[p] = .{ .deadline = deadline, .index = index };
            self.positions[index] = p;
            self.siftUp(p);
            return true;
        }
        const old = self.nodes[pos].deadline;
        self.nodes[pos].deadline = deadline;
        if (deadline < old) self.siftUp(pos) else self.siftDown(pos);
        return true;
    }

    pub fn remove(self: *Heap, index: u32) bool {
        if (index >= self.positions.len) return false;
        const pos = self.positions[index];
        if (pos == invalid_position) return false;
        self.positions[index] = invalid_position;
        self.len -= 1;
        if (pos == self.len) return true;
        self.nodes[pos] = self.nodes[self.len];
        self.positions[self.nodes[pos].index] = pos;
        if (pos != 0 and less(self.nodes[pos], self.nodes[(pos - 1) / 2])) self.siftUp(pos) else self.siftDown(pos);
        return true;
    }

    pub fn popExpired(self: *Heap, now: u64) ?u32 {
        if (self.len == 0 or self.nodes[0].deadline > now) return null;
        const index = self.nodes[0].index;
        _ = self.remove(index);
        return index;
    }

    pub fn waitMilliseconds(self: *const Heap, now: u64) u32 {
        if (self.len == 0) return 100;
        const deadline = self.nodes[0].deadline;
        if (deadline <= now) return 0;
        return @intCast(@min(deadline - now, @as(u64, 100)));
    }
};

test "heap insert update remove" {
    var nodes: [8]Node = undefined;
    var positions: [8]u32 = undefined;
    var heap = try Heap.init(&nodes, &positions);
    try std.testing.expect(heap.insertOrUpdate(3, 30));
    try std.testing.expect(heap.insertOrUpdate(1, 10));
    try std.testing.expect(heap.insertOrUpdate(5, 20));
    try std.testing.expectEqual(@as(?u32, 1), heap.popExpired(10));
    try std.testing.expect(heap.insertOrUpdate(5, 5));
    try std.testing.expectEqual(@as(?u32, 5), heap.popExpired(5));
    try std.testing.expect(heap.remove(3));
    try std.testing.expectEqual(@as(u32, 0), heap.len);
}
