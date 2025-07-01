const std = @import("std");
const types = @import("types.zig");
pub const StateMachine = @import("state_machine.zig").StateMachine;
const RaftState = types.RaftState;
const NodeId = types.NodeId;
const RpcMessage = types.RpcMessage;
const Log = @import("log.zig").Log;
const Command = @import("command.zig").Command;
const LogEntry = @import("log_entry.zig").LogEntry;
const RaftTcpServer = @import("raft_tcp_server.zig").RaftTcpServer;
const ElectionTimeoutBase: u64 = 150;
const ElectionTimeoutJitter: u64 = 150;

pub fn RaftNode(comptime T: type) type {
    return struct {
        config: types.RaftConfig,
        allocator: std.mem.Allocator,
        state: RaftState = .Follower,
        current_term: types.Term = 0,
        voted_for: ?NodeId = null,
        leader_id: ?NodeId = null,

        log: Log,
        election_deadline: u64 = 0, // ms timestamp

        inbox: std.ArrayList(RpcMessage),
        nodes_buffer: std.ArrayList(types.Node),
        votes_received: usize = 0,
        total_votes: usize = 0,
        commit_index: usize = 0,
        next_index: []usize, // for each follower: index of the next log entry to send
        match_index: []usize, // for each follower: highest log entry known to be replicated
        node_id_to_index: std.AutoHashMap(NodeId, usize),
        last_applied: usize = 0,

        // state_machine: anytype,
        // state_machine: ?*T,
        state_machine: ?StateMachine(T) = null,
        snapshot: ?types.Snapshot = null,
        snapshot_index: usize = 0,
        snapshot_term: u64 = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, id: NodeId, sm: StateMachine(T)) !Self {
            const nodes = std.ArrayList(types.Node).init(allocator);
            return Self{
                .allocator = allocator,
                .inbox = std.ArrayList(RpcMessage).init(allocator),
                .next_index = &[_]usize{},
                .match_index = &[_]usize{},
                .node_id_to_index = std.AutoHashMap(NodeId, usize).init(allocator),
                .log = Log.init(allocator),
                .nodes_buffer = nodes,
                .state_machine = sm,
                .config = types.RaftConfig{
                    .self_id = id,
                    .nodes = nodes.items,
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.node_id_to_index.deinit();
            self.inbox.deinit();
            self.nodes_buffer.deinit();
        }

        fn startElection(self: *RaftNode(T), cluster: *Cluster(T)) void {
            self.becomeCandidate();
            self.votes_received = 1; // vote for self
            self.total_votes = self.config.nodes.len;
            self.leader_id = null;

            // Determine last log index and term
            const last_log_index =
                if (self.log.entries.items.len > 0) self.log.entries.items.len - 1 else 0;

            const last_log_term =
                if (self.log.entries.items.len > 0) self.log.entries.items[last_log_index].term else 0;

            const req = types.RequestVote{
                .term = self.current_term,
                .candidate_id = self.config.self_id,
                .last_log_index = last_log_index,
                .last_log_term = last_log_term,
            };

            // Send RequestVote RPCs to all other nodes
            for (self.config.nodes) |node| {
                if (node.id == self.config.self_id) continue;

                _ = cluster.sendMessage(node.id, RpcMessage{ .RequestVote = req }) catch {
                    std.debug.print("Failed to send RequestVote to: {}\n", .{node.id});
                };
            }
        }

        pub fn tick(self: *RaftNode(T), cluster: *Cluster(T)) void {
            const now = std.time.milliTimestamp();

            // Process incoming messages first
            while (self.inbox.items.len > 0) {
                if (self.inbox.pop()) |msg| {
                    switch (msg) {
                        .RequestVote => |req| self.handleRequestVote(req, cluster),
                        .RequestVoteResponse => |resp| self.handleRequestVoteResponse(resp, cluster),
                        .AppendEntries => |req| self.handleAppendEntries(req, cluster),
                        .AppendEntriesResponse => |resp| self.handleAppendEntriesResponse(resp, cluster),

                        .InstallSnapshot => |_| {},
                        .InstallSnapshotResponse => |_| {},
                        .TimeoutNow => |_| {},
                        else => {
                            //TODO
                        },
                    }
                }
            }

            // Handle state-specific periodic work
            switch (self.state) {
                .Follower, .Candidate => {
                    if (now >= self.election_deadline) {
                        self.startElection(cluster);
                    }
                },
                .Leader => {
                    // Send heartbeat regularly (could add timer for heartbeat interval)
                    sendHeartbeats(self, cluster);
                },
            }

            while (self.last_applied < self.commit_index) {
                self.last_applied += 1;
                const entry = self.log.get(self.last_applied - 1) orelse continue;
                self.applyLog(entry);
            }
        }

        fn applyLog(self: *RaftNode(T), entry: LogEntry) void {
            std.debug.print("Applied entry at index {}: {}\n", .{
                self.last_applied,
                entry.command,
            });

            //TODO
            // while (self.last_applied < self.commit_index) {
            //     self.last_applied += 1;
            //     const entry = self.log.get(self.last_applied - 1) orelse continue;
            //     self.state_machine.applyLog(entry);
            // }
        }

        fn becomeCandidate(self: *RaftNode(T)) void {
            self.state = .Candidate;
            self.current_term += 1;
            self.voted_for = self.config.self_id;
            self.resetElectionTimeout();
            // Send RequestVote to other nodes (to be implemented)
        }

        fn becomeFollower(self: *RaftNode(T)) void {
            self.state = .Follower;
            self.voted_for = null;
            self.resetElectionTimeout();
        }

        pub fn resetElectionTimeout(self: *RaftNode(T)) void {
            const jitter = @mod(std.crypto.random.int(u64), ElectionTimeoutJitter);
            const now_ms: u64 = @intCast(std.time.milliTimestamp()); // safe since time is positive
            self.election_deadline = now_ms + ElectionTimeoutBase + jitter;
        }

        pub fn enqueueMessage(self: *RaftNode(T), msg: RpcMessage) !void {
            try self.inbox.append(msg);
        }

        pub fn processMessages(self: *RaftNode(T), cluster: *Cluster(T)) !void {
            while (self.inbox.items.len > 0) {
                if (self.inbox.pop()) |msg| {
                    switch (msg) {
                        RpcMessage.RequestVote => |req| {
                            self.handleRequestVote(req, cluster);
                        },
                        RpcMessage.AppendEntries => |req| {
                            self.handleAppendEntries(req, cluster);
                        },
                        RpcMessage.RequestVoteResponse => |resp| {
                            self.handleRequestVoteResponse(resp, cluster);
                        },
                        RpcMessage.AppendEntriesResponse => |resp| {
                            self.handleAppendEntriesResponse(resp, cluster);
                        },

                        RpcMessage.InstallSnapshot => |resp| {
                            try self.installSnapshot(resp, cluster);
                        },
                        RpcMessage.InstallSnapshotResponse => |resp| {
                            if (self.state != .Leader) return;

                            const follower_idx = self.node_id_to_index.get(resp.follower_id) orelse return;

                            // follower is up to date with snapshot index; set next_index and match_index accordingly
                            const new_index = self.snapshot_index + 1;
                            self.next_index[follower_idx] = new_index;
                            self.match_index[follower_idx] = self.snapshot_index;

                            // trigger a commit check here if needed
                            // Copy match_index into a temp array
                            const temp = try self.allocator.alloc(usize, self.match_index.len);
                            defer self.allocator.free(temp);
                            @memcpy(temp, self.match_index);

                            std.mem.sort(usize, temp, {}, comptime std.sort.desc(usize));
                            const majority_idx = temp[@divFloor(temp.len, 2)];

                            if (majority_idx > self.commit_index) {
                                const term_at = self.log.termAt(majority_idx);
                                if (term_at) |term_at_val| {
                                    if (term_at_val == self.current_term) {
                                        self.commit_index = majority_idx;
                                        self.applyCommitted(); // Applies entries up to commit_index
                                    }
                                }
                            }
                        },
                        RpcMessage.TimeoutNow => |_| {
                            if (self.state == .Follower) {
                                std.debug.print("Received TimeoutNow, starting election early...\n", .{});
                                self.startElection(cluster);
                            }
                        },
                        else => {
                            //TODO
                        },
                    }
                } else {
                    //TODO
                    break;
                }
            }
        }

        fn handleRequestVote(self: *RaftNode(T), req: types.RequestVote, cluster: *Cluster(T)) void {
            if (req.term > self.current_term) {
                self.current_term = req.term;
                self.voted_for = null;
                self.becomeFollower();
            }

            var vote_granted = false;

            const candidate_up_to_date = blk: {
                const last_log_index =
                    if (self.log.entries.items.len > 0) self.log.entries.items.len - 1 else 0;

                const last_log_term =
                    if (self.log.entries.items.len > 0) self.log.entries.items[last_log_index].term else 0;

                if (req.last_log_term > last_log_term) break :blk true;
                if (req.last_log_term < last_log_term) break :blk false;

                // Same term — compare index
                break :blk req.last_log_index >= last_log_index;
            };

            if (req.term == self.current_term) {
                if ((self.voted_for == null or self.voted_for.? == req.candidate_id) and candidate_up_to_date) {
                    self.voted_for = req.candidate_id;
                    vote_granted = true;

                    // Reset election timeout if needed
                    self.resetElectionTimeout();
                }
            }

            const resp = types.RequestVoteResponse{
                .term = self.current_term,
                .vote_granted = vote_granted,
                .voter_id = self.config.self_id,
            };

            _ = cluster.sendMessage(req.candidate_id, types.RpcMessage{ .RequestVoteResponse = resp }) catch {
                std.debug.print("Failed to send RequestVoteResponse to {}\n", .{req.candidate_id});
            };
        }

        fn handleAppendEntries(self: *RaftNode(T), req: types.AppendEntries, cluster: *Cluster(T)) void {
            if (req.term < self.current_term) {
                const resp = types.AppendEntriesResponse{
                    .term = self.current_term,
                    .success = false,
                    .follower_id = self.config.self_id,
                    .match_index = 0,
                };

                _ = cluster.sendMessage(req.leader_id, .{ .AppendEntriesResponse = resp }) catch {
                    std.debug.print("Failed to send AppendEntriesResponse to node_id: {}\n", .{req.leader_id});
                };
                return;
            }

            self.leader_id = req.leader_id;

            // If term is greater, step down
            if (req.term > self.current_term) {
                self.current_term = req.term;
                self.becomeFollower();
            } else {
                //TODO
                // self.resetElectionTimeout();
            }

            // Log consistency check
            const prev_log_term = self.log.termAt(req.prev_log_index);
            if (prev_log_term == null or prev_log_term.? != req.prev_log_term) {
                const resp = types.AppendEntriesResponse{
                    .term = self.current_term,
                    .success = false,
                    .follower_id = self.config.self_id,
                    .match_index = 0,
                };

                _ = cluster.sendMessage(req.leader_id, .{ .AppendEntriesResponse = resp }) catch {
                    std.debug.print("Failed to send AppendEntriesResponse to node_id: {}\n", .{req.leader_id});
                };

                return;
            }

            // Append new entries (if any), replacing conflicts
            var i: usize = 0;
            while (i < req.entries.len) {
                const index = req.prev_log_index + 1 + i;
                const existing = self.log.get(index);

                if (existing == null or existing.?.term != req.entries[i].term) {
                    // Truncate and append
                    self.log.truncate(index);
                    _ = self.log.entries.appendSlice(req.entries[i..]) catch {
                        std.debug.print("Failed to append entries; index: {}; i: {}\n", .{ index, i });
                    };
                    break;
                }

                i += 1;
            }

            // Update commit index
            if (req.leader_commit > self.commit_index) {
                const new_commit = @min(req.leader_commit, self.log.lastIndex());
                self.commit_index = new_commit;
                _ = self.applyCommitted(); // Apply entries to state machine
            }

            const resp = types.AppendEntriesResponse{
                .term = self.current_term,
                .success = true,
                .follower_id = self.config.self_id,
                .match_index = req.prev_log_index + req.entries.len,
            };

            _ = cluster.sendMessage(req.leader_id, .{ .AppendEntriesResponse = resp }) catch {};
        }

        fn applyCommitted(self: *RaftNode(T)) void {
            while (self.last_applied < self.commit_index) {
                const entry = self.log.get(self.last_applied) orelse break;
                if (self.state_machine) |sm| {
                    sm.applyLog(entry);
                }

                self.last_applied += 1;
            }
        }

        fn handleRequestVoteResponse(self: *RaftNode(T), resp: types.RequestVoteResponse, cluster: *Cluster(T)) void {
            if (self.state != .Candidate) return;

            if (resp.term > self.current_term) {
                // Step down to follower
                self.current_term = resp.term;
                self.becomeFollower();
                return;
            }

            if (resp.vote_granted) {
                self.votes_received += 1;

                const majority = (cluster.nodes.items.len / 2) + 1;
                if (self.votes_received >= majority and self.state == .Candidate) {
                    // Become leader once majority is reached
                    self.becomeLeader(cluster) catch {
                        std.debug.print("Failed to becomeLeader for the node_id: {}\n", .{self.config.self_id});
                    };
                }
            }
        }

        fn handleAppendEntriesResponse(self: *RaftNode(T), resp: types.AppendEntriesResponse, cluster: *Cluster(T)) void {
            if (resp.term > self.current_term) {
                self.current_term = resp.term;
                self.becomeFollower();
                return;
            }

            const follower_index = self.findNodeIndex(resp.follower_id) orelse return;

            if (resp.success) {
                self.match_index[follower_index] = resp.match_index;
                self.next_index[follower_index] = resp.match_index + 1;

                // Try to advance commit index
                const majority = (self.config.nodes.len / 2) + 1;
                var new_commit_index = self.commit_index + 1;

                while (new_commit_index <= self.log.entries.items.len) : (new_commit_index += 1) {
                    var replicated_count: usize = 1; // count self
                    for (self.match_index) |idx| {
                        if (idx >= new_commit_index) replicated_count += 1;
                    }

                    // Only commit entries from current term
                    if (replicated_count >= majority and
                        self.log.termAt(new_commit_index - 1) == self.current_term)
                    {
                        self.commit_index = new_commit_index;

                        // Apply committed entries
                        _ = self.applyCommitted();

                        // Broadcast updated commit index to others
                        for (cluster.nodes.items) |follower| {
                            if (follower.config.self_id == self.config.self_id) continue;

                            const idx = self.node_id_to_index.get(follower.config.self_id) orelse continue;
                            const next_idx = self.next_index[idx];

                            const ae = types.AppendEntries{
                                .term = self.current_term,
                                .leader_id = self.config.self_id,
                                .prev_log_index = next_idx - 1,
                                .prev_log_term = self.log.termAt(next_idx - 1) orelse 0,
                                .entries = self.log.sliceFrom(next_idx),
                                .leader_commit = self.commit_index,
                            };

                            _ = cluster.sendMessage(follower.config.self_id, .{ .AppendEntries = ae }) catch {
                                std.debug.print("Failed to send sendMessage to node {}\n", .{follower.config.self_id});
                            };
                        }
                    }
                }
            } else {
                // Step back and retry
                if (self.next_index[follower_index] > 1) {
                    self.next_index[follower_index] -= 1;
                }
            }
        }

        fn sendHeartbeats(self: *RaftNode(T), cluster: *Cluster(T)) void {
            for (self.config.nodes, 0..) |node, i| {
                if (node.id == self.config.self_id) continue;

                const next_idx = self.next_index[i];
                const prev_log_index = if (next_idx > 0) next_idx - 1 else 0;
                const prev_log_term = self.log.termAt(prev_log_index) orelse 0;

                // Fetch entries to send starting at next_idx
                const all_entries = self.log.entries.items;
                const to_send = if (next_idx < all_entries.len) all_entries[next_idx..] else &[_]LogEntry{};

                const req = types.AppendEntries{
                    .term = self.current_term,
                    .leader_id = self.config.self_id,
                    .prev_log_index = prev_log_index,
                    .prev_log_term = prev_log_term,
                    .entries = @constCast(to_send), // heartbeat → no new entries
                    .leader_commit = self.commit_index,
                };

                const msg = types.RpcMessage{ .AppendEntries = req };

                // Send to the target node
                _ = cluster.sendMessage(node.id, msg) catch {
                    std.debug.print("Failed to send AppendEntries to node {}\n", .{node.id});
                };
            }
        }

        fn updateTermIfNeeded(self: *RaftNode(T), new_term: u64) void {
            if (new_term > self.current_term) {
                self.current_term = new_term;
                self.state = .Follower;
                self.voted_for = null;
                self.resetElectionTimeout();
            }
        }

        fn findNodeIndex(self: *RaftNode(T), node_id: NodeId) ?usize {
            for (self.config.nodes, 0..) |node, i| {
                if (node.id == node_id) return i;
            }
            return null;
        }

        pub fn handleClientCommand(self: *RaftNode(T), command: Command) !void {
            if (self.state != .Leader) {
                return error.NotLeader;
            }

            const entry = LogEntry{
                .term = self.current_term,
                .command = command,
            };

            try self.log.append(entry);

            // After append, update own match_index and next_index accordingly
            const my_index = self.log.entries.items.len;
            const my_log_index = my_index - 1;

            self.match_index[self.findNodeIndex(self.config.self_id).?] = my_log_index;
            self.next_index[self.findNodeIndex(self.config.self_id).?] = my_log_index + 1;
        }

        pub fn submitCommand(self: *RaftNode(T), command: Command) !void {
            if (self.role != .Leader) {
                return error.NotLeader;
            }

            const entry = LogEntry{
                .term = self.current_term,
                .command = command,
            };

            try self.log.append(entry);

            // (optional) Immediately replicate, or wait until next heartbeat
            //  self.broadcastAppendEntriesNow = true;
        }

        fn becomeLeader(self: *RaftNode(T), cluster: *Cluster(T)) !void {
            const count = cluster.nodes.items.len;

            self.next_index = try self.allocator.alloc(usize, count);
            self.match_index = try self.allocator.alloc(usize, count);

            for (cluster.nodes.items, 0..) |node, i| {
                try self.node_id_to_index.put(node.config.self_id, i);
                self.next_index[i] = self.log.lastIndex() + 1;
                self.match_index[i] = 0;
            }

            self.sendHeartbeats(cluster);
        }

        fn createSnapshot(self: *RaftNode(T)) !void {
            const last_index = self.last_applied;

            // 1. Serialize state machine to bytes
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();
            try self.state_machine.ctx.serialize(&buffer); // assumes your state machine supports this

            // 2. Save snapshot
            self.snapshot = types.Snapshot{
                .last_included_index = last_index,
                .last_included_term = self.log.termAt(last_index - 1).?,
                .state_data = try self.allocator.dupe(u8, buffer.items),
            };

            // 3. Truncate log
            try self.log.truncatePrefix(last_index);
        }

        fn installSnapshot(self: *RaftNode(T), snap: types.InstallSnapshot, cluster: *Cluster(T)) !void {
            if (snap.term < self.current_term) return;

            self.state = .Follower;
            self.current_term = snap.term;
            self.voted_for = null;
            self.resetElectionTimeout();

            // Discard old log entries
            self.log.truncate(snap.last_included_index + 1);

            // Set snapshot point
            self.snapshot_index = snap.last_included_index;
            self.snapshot_term = snap.last_included_term;

            // Deserialize snapshot into state machine
            try self.state_machine.?.deserialize(snap.data);

            // Update log
            try self.log.replaceWithSnapshotPoint(snap.last_included_index, snap.last_included_term);
            self.commit_index = snap.last_included_index;
            self.last_applied = snap.last_included_index;

            const resp = types.RpcMessage{
                .InstallSnapshotResponse = types.InstallSnapshotResponse{ .term = self.current_term, .follower_id = self.config.self_id, .success = true },
            };
            try cluster.sendMessage(snap.leader_id, resp);
        }
    };
}

pub fn Cluster(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        nodes: std.ArrayList(*RaftNode(T)),
        node_addresses: std.AutoHashMap(NodeId, types.PeerAddress),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) @This() {
            return Self{
                .allocator = allocator,
                .nodes = std.ArrayList(*RaftNode(T)).init(allocator),
                .node_addresses = std.AutoHashMap(NodeId, types.PeerAddress).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            // Assuming Cluster does not own RaftNode(T) memory
            self.nodes.deinit();
        }

        //for "in-memory" transport; simulation
        pub fn addNode(self: *Self, node: *RaftNode(T)) !void {
            try self.nodes.append(node);
        }

        //for TCP, sockets transport; real network, distributed clusters
        pub fn addNodeAddress(self: *Self, id: NodeId, addr: types.PeerAddress) !void {
            try self.node_addresses.put(id, addr);
        }

        pub fn sendMessage(self: *Self, to_id: NodeId, msg: RpcMessage) !void {
            for (self.nodes.items) |node| {
                if (node.config.self_id == to_id) {
                    try node.enqueueMessage(msg);
                    return;
                }
            }
            // Node not found — ignore or log error
        }

        pub fn broadcastMessage(self: *Self, from_id: NodeId, msg: RpcMessage) !void {
            for (self.nodes.items) |node| {
                if (node.config.self_id != from_id) {
                    try node.enqueueMessage(msg);
                }
            }
        }

        pub fn tick(self: *Self) !void {
            for (self.nodes.items) |node| {
                node.tick(self);
            }

            //TODO: merge the loops
            for (self.nodes.items) |node| {
                try node.processMessages(self);
            }
        }

        //TODO
        //for TCP, sockets transport; real network, distributed clusters
        pub fn sendRpc(self: *Self, to_id: NodeId, msg: RpcMessage) !void {
            const addr = self.node_addresses.get(to_id) orelse return error.UnknownPeer;
            const stream = try std.net.tcpConnectToHost(self.allocator, addr.ip, addr.port);
            defer stream.close();

            try msg.serialize(stream.writer());
        }
    };
}
