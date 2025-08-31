const std = @import("std");
const t = @import("types.zig");
const builtin = @import("builtin");

pub const StateMachine = @import("state_machine.zig").StateMachine;
const RaftState = t.RaftState;
const NodeId = t.NodeId;
const RpcMessage = t.RpcMessage;
const Log = @import("log.zig").Log;
const LogEntry = @import("log.zig").LogEntry;
const cmd_mod = @import("command_v3.zig");
const Command = cmd_mod.Command;
const ClientCommandResult = cmd_mod.ClientCommandResult;
const cfg = @import("config_v3.zig");
const Config = cfg.Config;

const RaftTcpServer = @import("raft_tcp_server.zig").RaftTcpServer;
const ElectionTimeoutBase: u64 = 150;
const ElectionTimeoutJitter: u64 = 150;

pub fn RaftNode(comptime T: type) type {
    return struct {
        config: cfg.Config,
        allocator: std.mem.Allocator,
        state: RaftState = .Follower,
        current_term: t.Term = 0,
        voted_for: ?NodeId = null,
        leader_id: ?NodeId = null,

        log: Log,
        election_deadline: u64 = 0, // ms timestamp
        last_successful_heartbeat: i64 = 0,

        inbox: std.ArrayList(RpcMessage),
        nodes_buffer: std.ArrayList(cfg.Peer),
        votes_received: usize = 0,
        total_votes: usize = 0,
        commit_index: usize = 0,
        next_index: []usize, // for each follower: index of the next log entry to send
        match_index: []usize, // for each follower: highest log entry known to be replicated
        node_id_to_index: std.AutoHashMap(NodeId, usize),
        last_applied: usize = 0,
        state_machine: ?StateMachine(T) = null,
        snapshot: ?t.Snapshot = null,
        snapshot_index: usize = 0,
        snapshot_term: u64 = 0,

        const Self = @This();

        //TODO: pass Config
        // pub fn _init(allocator: std.mem.Allocator, id: NodeId, sm: StateMachine(T)) !Self {
        //     const nodes = std.ArrayList(cfg.Peer).init(allocator);
        //     // Memory log
        //     var log_memory_opts = std.StringHashMap([]const u8).init(allocator);
        //     defer log_memory_opts.deinit();
        //     try log_memory_opts.put("storage_type", "memory");
        //     const memory_log = try Log.init(allocator, log_memory_opts);

        //     return Self{
        //         .allocator = allocator,
        //         .inbox = std.ArrayList(RpcMessage).init(allocator),
        //         .next_index = &[_]usize{},
        //         .match_index = &[_]usize{},
        //         .node_id_to_index = std.AutoHashMap(NodeId, usize).init(allocator),
        //         .log = memory_log,
        //         .nodes_buffer = nodes,
        //         .state_machine = sm,
        //         .config = cfg.Config{
        //             .self_id = id,
        //             .peers = nodes.items,
        //         },
        //     };
        // }

        pub fn init(allocator: std.mem.Allocator, config_or_path: union(enum) {
            config: cfg.Config,
            path: []const u8,
        }, sm: StateMachine(T)) !Self {
            const config = switch (config_or_path) {
                .config => |c| c,
                .path => |p| try cfg.Config.loadFromFile(allocator, p),
            };

            // Initialize arrays based on peer count
            const peer_count = config.peers.len;
            const next_index = try allocator.alloc(usize, peer_count);
            const match_index = try allocator.alloc(usize, peer_count);

            // Initialize with default values
            for (next_index, 0..) |*idx, i| {
                _ = i;
                idx.* = 1; // Raft log indices start at 1
            }
            for (match_index) |*idx| {
                idx.* = 0;
            }

            // Build node_id_to_index mapping
            var node_id_to_index = std.AutoHashMap(NodeId, usize).init(allocator);
            for (config.peers, 0..) |peer, i| {
                try node_id_to_index.put(peer.id, i);
            }

            // Initialize log based on config
            var log_opts = std.StringHashMap([]const u8).init(allocator);
            defer log_opts.deinit();
            try log_opts.put("storage_type", @tagName(config.protocol.storage_type));
            const log = try Log.init(allocator, log_opts);

            return Self{
                .config = config,
                .allocator = allocator,
                .log = log,
                .inbox = std.ArrayList(RpcMessage).init(allocator),
                .nodes_buffer = std.ArrayList(cfg.Peer).init(allocator),
                .next_index = next_index,
                .match_index = match_index,
                .node_id_to_index = node_id_to_index,
                .state_machine = sm,
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
            self.total_votes = self.config.peers.len;
            self.leader_id = null;

            // Determine last log index and term
            const last_log_index0 = self.log.getLastIndex();
            const last_log_index = if (last_log_index0 > 0) last_log_index0 - 1 else 0;

            const last_log_term0 = self.log.getLastTerm();
            const last_log_term = if (last_log_term0 > 0) last_log_term0 - 1 else 0;
            //

            const req = t.RequestVote{
                .term = self.current_term,
                .candidate_id = self.config.self_id,
                .last_log_index = last_log_index,
                .last_log_term = last_log_term,
            };

            // Send RequestVote RPCs to all other nodes
            for (self.config.peers) |node| {
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

                        //TODO
                        .InstallSnapshot => |_| {},
                        .InstallSnapshotResponse => |_| {},
                        .TimeoutNow => |_| {
                            // Start election immediately
                            self.startElection(cluster);
                            if (builtin.mode == .Debug) {
                                std.debug.print("Node {} received TimeoutNow, starting election immediately\n", .{self.config.self_id});
                            }
                        },
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
                const entry = self.log.getEntry(self.last_applied - 1) orelse continue;
                self.applyLog(entry.*);
            }
        }

        fn applyLog(self: *RaftNode(T), entry: LogEntry) void {
            if (self.state_machine) |sm| {
                sm.applyLog(entry);
                std.debug.print("Applied entry at index {}: {any}\n", .{
                    self.last_applied,
                    entry.data,
                });
            }
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
                                const term_at = self.log.getTermAtIndex(majority_idx);
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

        fn handleRequestVote(self: *RaftNode(T), req: t.RequestVote, cluster: *Cluster(T)) void {
            if (req.term > self.current_term) {
                self.current_term = req.term;
                self.voted_for = null;
                self.becomeFollower();
            }

            var vote_granted = false;

            const is_candidate_up_to_date = blk: {
                const last_log_index = self.log.getLastIndex();
                const last_log_term = self.log.getLastTerm();

                if (req.last_log_term > last_log_term) break :blk true;
                if (req.last_log_term < last_log_term) break :blk false;

                // Same term — compare index
                break :blk req.last_log_index >= last_log_index;
            };

            if (req.term == self.current_term) {
                if ((self.voted_for == null or self.voted_for.? == req.candidate_id) and is_candidate_up_to_date) {
                    self.voted_for = req.candidate_id;
                    vote_granted = true;

                    // Reset election timeout if needed
                    self.resetElectionTimeout();
                }
            }

            const resp = t.RequestVoteResponse{
                .term = self.current_term,
                .vote_granted = vote_granted,
                .voter_id = self.config.self_id,
            };

            _ = cluster.sendMessage(req.candidate_id, t.RpcMessage{ .RequestVoteResponse = resp }) catch {
                std.debug.print("Failed to send RequestVoteResponse to {}\n", .{req.candidate_id});
            };
        }

        fn handleAppendEntries(self: *RaftNode(T), req: t.AppendEntries, cluster: *Cluster(T)) void {
            if (req.term < self.current_term) {
                const resp = t.AppendEntriesResponse{
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
            const prev_log_term = self.log.getTermAtIndex(req.prev_log_index);
            if (prev_log_term == null or prev_log_term.? != req.prev_log_term) {
                const resp = t.AppendEntriesResponse{
                    .term = self.current_term,
                    .success = false,
                    .follower_id = self.config.self_id,
                    .match_index = 0,
                };

                _ = cluster.sendMessage(req.leader_id, .{ .AppendEntriesResponse = resp }) catch {
                    std.log.err("Failed to send AppendEntriesResponse to node_id: {}\n", .{req.leader_id});
                };

                return;
            }

            // Append new entries (if any), replacing conflicts
            var i: usize = 0;
            while (i < req.entries.len) {
                const index = req.prev_log_index + 1 + i;
                const existing = self.log.getEntry(index);

                if (existing == null or existing.?.term != req.entries[i].term) {
                    // Truncate and append
                    self.log.truncateFrom(index) catch {
                        std.debug.print("Failed to truncate entries; index: {}\n", .{index});
                    };

                    _ = self.log.appendSlice(req.entries[i..]) catch {
                        std.debug.print("Failed to append entries; index: {}; i: {}\n", .{ index, i });
                    };
                    break;
                }

                i += 1;
            }

            // Update commit index
            if (req.leader_commit > self.commit_index) {
                const new_commit = @min(req.leader_commit, self.log.getLastIndex());
                self.commit_index = new_commit;
                _ = self.applyCommitted(); // Apply entries to state machine
            }

            const resp = t.AppendEntriesResponse{
                .term = self.current_term,
                .success = true,
                .follower_id = self.config.self_id,
                .match_index = req.prev_log_index + req.entries.len,
            };

            _ = cluster.sendMessage(req.leader_id, .{ .AppendEntriesResponse = resp }) catch {};
        }

        fn applyCommitted(self: *RaftNode(T)) void {
            while (self.last_applied < self.commit_index) {
                const entry = self.log.getEntry(self.last_applied) orelse break;
                if (self.state_machine) |sm| {
                    sm.applyLog(entry.*);
                }

                self.last_applied += 1;
            }
        }

        fn handleRequestVoteResponse(self: *RaftNode(T), resp: t.RequestVoteResponse, cluster: *Cluster(T)) void {
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

        fn handleAppendEntriesResponse(self: *RaftNode(T), resp: t.AppendEntriesResponse, cluster: *Cluster(T)) void {
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
                const majority = (self.config.peers.len / 2) + 1;
                var new_commit_index = self.commit_index + 1;

                while (new_commit_index <= self.log.getLastIndex()) : (new_commit_index += 1) {
                    var replicated_count: usize = 1; // count self
                    for (self.match_index) |idx| {
                        if (idx >= new_commit_index) replicated_count += 1;
                    }

                    // Only commit entries from current term
                    if (replicated_count >= majority and
                        self.log.getTermAtIndex(new_commit_index - 1) == self.current_term)
                    {
                        self.commit_index = new_commit_index;

                        // Apply committed entries
                        _ = self.applyCommitted();

                        // Broadcast updated commit index to others
                        for (cluster.nodes.items) |follower| {
                            if (follower.config.self_id == self.config.self_id) continue;

                            const idx = self.node_id_to_index.get(follower.config.self_id) orelse continue;
                            const next_idx = self.next_index[idx];
                            const sliced_entries = self.log.sliceFrom(self.allocator, next_idx) catch |err| blk: {
                                std.log.err("log.sliceFrom failed: {}", .{err});
                                break :blk &[_]LogEntry{}; // Empty slice
                            };

                            const ae = t.AppendEntries{
                                .term = self.current_term,
                                .leader_id = self.config.self_id,
                                .prev_log_index = next_idx - 1,
                                .prev_log_term = self.log.getTermAtIndex(next_idx - 1) orelse 0,
                                .entries = @constCast(sliced_entries),
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
            for (self.config.peers, 0..) |node, i| {
                if (node.id == self.config.self_id) continue;

                const next_idx = self.next_index[i];
                const prev_log_index = if (next_idx > 0) next_idx - 1 else 0;
                const prev_log_term = self.log.getTermAtIndex(prev_log_index) orelse 0;

                const last_index = self.log.getLastIndex();
                const start_index = next_idx + 1; // Convert to 1-based Raft indexing

                // Collect entries to send
                var entries_to_send = std.ArrayList(LogEntry).init(self.allocator);
                defer entries_to_send.deinit();
                var current_index = start_index;
                while (current_index <= last_index) {
                    if (self.log.getEntry(current_index)) |x| {
                        entries_to_send.append(x.*) catch {
                            std.log.err("Failed to append element {} to entries_to_send\n", .{x.*});
                        };
                    }
                    current_index += 1;
                }

                const to_send = entries_to_send.items;

                const req = t.AppendEntries{
                    .term = self.current_term,
                    .leader_id = self.config.self_id,
                    .prev_log_index = prev_log_index,
                    .prev_log_term = prev_log_term,
                    .entries = to_send, // heartbeat → no new entries
                    .leader_commit = self.commit_index,
                };

                const msg = t.RpcMessage{ .AppendEntries = req };

                // Send to the target node
                _ = cluster.sendMessage(node.id, msg) catch {
                    std.log.err("Failed to send AppendEntries to node {}\n", .{node.id});
                };
            }
        }

        fn sendHeartbeat(self: *Self, peer: cfg.Peer) !void {
            // A heartbeat is an AppendEntries RPC with no entries
            // This is specifically for leadership confirmation, not log replication

            const peer_index = self.getPeerIndex(peer.id) orelse 0;

            const prev_log_index =
                if (self.next_index[peer_index] > 0) self.next_index[peer_index] - 1 else 0;

            const prev_log_term =
                if (prev_log_index > 0) (self.log.getTermAtIndex(prev_log_index) orelse 0) else 0;

            // const heartbeat = AppendEntriesRequest{
            const heartbeat = t.AppendEntries{
                .term = self.current_term,
                .leader_id = self.config.self_id,
                .prev_log_index = prev_log_index,
                .prev_log_term = prev_log_term,
                .entries = &[_]LogEntry{}, // Empty for heartbeat
                .leader_commit = self.commit_index,
            };

            //TODO
            _ = heartbeat;

            //TODO
            // Send via RPC
            // const response =
            //     try self.rpc_client.sendAppendEntriesWithTimeout(peer, heartbeat, self.config.heartbeat_timeout_ms);

            // // Update term if we receive a higher term
            // if (response.term > self.current_term) {
            //     try self.log.updateTerm(response.term);
            //     self.current_term = response.term;
            //     self.state = .Follower;
            //     return error.LeadershipLost;
            // }

            // // For heartbeats, we mainly care about success/failure for leadership confirmation
            // if (!response.success) {
            //     std.log.warn("Heartbeat to peer {} failed", .{peer.id});
            // }
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
            for (self.config.peers, 0..) |node, i| {
                if (node.id == node_id) return i;
            }
            return null;
        }

        // v1: Raw data handler (backward compatible)
        pub fn handleClientCommand(self: *Self, command: []const u8) !void {
            if (self.state != .Leader) {
                return error.NotLeader;
            }

            const entry = LogEntry{
                .term = self.current_term,
                .index = self.log.getLastIndex() + 1,
                .data = try self.allocator.dupe(u8, command),
            };

            try self.log.append(entry);

            // Update own match_index and next_index
            const my_node_index = self.findNodeIndex(self.config.self_id) orelse return error.NodeNotFound;
            const new_log_index = self.log.getLastIndex();

            self.match_index[my_node_index] = new_log_index;
            self.next_index[my_node_index] = new_log_index + 1;

            // Trigger replication to followers
            try self.triggerReplication();
        }

        // v2 2: Structured command handler (new API)
        pub fn handleClientCommandStructured(self: *Self, command: Command) !ClientCommandResult {
            if (self.state != .Leader) {
                return ClientCommandResult{ .err = .not_leader };
            }

            // Handle read-only commands differently
            switch (command) {
                .get => |get_cmd| {
                    if (self.state_machine) |*sm| {
                        _ = sm; // Silence unused warning

                        // Choose read consistency level based on configuration
                        const value = switch (self.config.client.read_consistency) {
                            .eventual => try self.handleReadCommand(get_cmd.key),
                            .linearizable => try self.handleLinearizableRead(get_cmd.key),
                            .lease_based => try self.handleLeaseBasedRead(get_cmd.key),
                            .sequential => {
                                @panic("not implemented");
                            },
                        };

                        return ClientCommandResult{ .query_result = .{ .value = value } };
                    } else {
                        return ClientCommandResult{ .err = .state_machine_not_initialized };
                    }
                },
                else => {
                    // Write operations go through the log
                    const next_index = self.log.getLastIndex() + 1;
                    const entry = try LogEntry.fromCommand(self.allocator, self.current_term, next_index, command);

                    try self.log.append(entry);

                    // Update own indices
                    const my_node_index = self.findNodeIndex(self.config.self_id) orelse {
                        return ClientCommandResult{ .err = .internal_error };
                    };
                    const new_log_index = self.log.getLastIndex();

                    self.match_index[my_node_index] = new_log_index;
                    self.next_index[my_node_index] = new_log_index + 1;

                    // Trigger replication to followers
                    try self.triggerReplication();

                    return ClientCommandResult{ .write_result = .{
                        .index = new_log_index,
                        .term = self.current_term,
                    } };
                },
            }
        }

        fn handleReadCommand(self: *Self, key: []const u8) !?[]const u8 {
            // Ensure we're still the leader before reading
            if (self.state != .Leader) {
                return error.NotLeader;
            }

            // For Raft, we have different consistency options for reads:
            // 1. Read from state machine directly (fast but not linearizable)
            // 2. Read-through log (slower but linearizable)
            // 3. Leader lease based reads (fast and linearizable with lease)

            // Option 1: Direct read (fastest, but not linearizable)
            // This provides "read-your-writes" consistency for the leader
            if (self.state_machine) |*sm| {
                return sm.queryGet(key);
            }

            return null;
        }

        // Alternative: Linearizable read implementation
        fn handleLinearizableRead(self: *Self, key: []const u8) !?[]const u8 {
            if (self.state != .Leader) {
                return error.NotLeader;
            }

            // Method 1: Read-index approach (from Raft paper section 6.4)
            // 1. Record current commit index
            const read_index = self.commit_index;
            //TODO
            _ = read_index;

            // 2. Send heartbeat to majority to confirm leadership
            if (!try self.confirmLeadership()) {
                return error.LeadershipLost;
            }

            // 3. Wait until state machine has applied up to read_index
            // try self.waitForApply(read_index);

            // 4. Now safe to read from state machine
            if (self.state_machine) |*sm| {
                return sm.queryGet(key);
            }

            return null;
        }

        // Supporting methods for linearizable reads
        fn confirmLeadership(self: *Self) !bool {
            // Send heartbeat to majority of followers
            var success_count: usize = 1; // Count self
            // const majority = (self.config.peers.len / 2) + 1;
            const majority = (self.config.peers.len / 2) + 1;

            // sync version for simplicity
            // TODO - make it async
            //
            // for (self.config.peers) |peer| {
            //
            for (self.config.peers) |peer| {
                if (peer.id != self.config.self_id) {
                    if (self.sendHeartbeat(peer)) {
                        // if (self.sendHeartbeats(peer)) {
                        success_count += 1;
                        if (success_count >= majority) {
                            return true;
                        }
                    } else |_| {
                        // Heartbeat failed, continue with others
                        continue;
                    }
                }
            }

            return success_count >= majority;
        }

        fn getPeerIndex(self: *Self, peer_id: u64) ?usize {
            // Find the array index of peer with given ID in our peers array
            for (self.config.peers, 0..) |peer, i| {
                if (peer.id == peer_id) return i;
            }
            return null; // Peer not found - this is an error condition
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
                self.next_index[i] = self.log.getLastIndex() + 1;
                self.match_index[i] = 0;
            }

            self.sendHeartbeats(cluster);
        }

        //TODO
        fn createSnapshot(self: *RaftNode(T)) !void {
            _ = self;

            @panic("not implemented");
        }

        //TODO
        fn installSnapshot(self: *RaftNode(T), snap: t.InstallSnapshot, cluster: *Cluster(T)) !void {
            _ = self;
            _ = snap;
            _ = cluster;

            @panic("not implemented");
        }

        //TODO
        pub fn transferLeadership(self: *RaftNode(T), cluster: *Cluster(T), target_id: u64) void {
            becomeFollower(self);
            // Tell the target to start election
            cluster.send(target_id, .{ .TimeoutNow = {} });

            if (builtin.mode == .Debug) {
                std.debug.print("Node {} stepped down, asked node {} to take over\n", .{ self.id, target_id });
            }
        }

        fn handleLeaseBasedRead(self: *Self, key: []const u8) !?[]const u8 {
            // Check if we have a valid leader lease
            if (!self.hasValidLeaderLease()) {
                return error.LeaseExpired;
            }

            // Read directly from state machine without going through log
            if (self.state_machine) |*sm| {
                return sm.queryGet(key);
            }

            return error.StateMachineNotInitialized;
        }

        fn hasValidLeaderLease(self: *Self) bool {
            // Check if our leader lease is still valid
            // Lease is valid if:
            // 1. We are the leader
            // 2. We have received heartbeat responses from majority recently
            // 3. The lease hasn't expired

            if (self.state != .Leader) {
                return false;
            }

            const now = std.time.milliTimestamp();
            const lease_duration_ms = self.config.protocol.leader_lease_timeout_ms;
            return (now - self.last_successful_heartbeat) < lease_duration_ms;
        }

        fn triggerReplication(self: *Self) !void {
            // Implementation depends on your replication mechanism
            // This might involve:
            // 1. Sending AppendEntries RPCs to all followers
            // 2. Starting async replication tasks
            // 3. Updating replication state

            // Placeholder implementation
            for (self.config.peers) |peer| {
                if (peer.id != self.config.self_id) {
                    // Async send AppendEntries to peer
                    try self.sendAppendEntries(peer);
                }
            }
        }

        // Enhanced version based on your reference - handles both heartbeats and log replication
        // fn sendAppendEntries(self: *Self, peer: t.Node) !void {
        fn sendAppendEntries(self: *Self, peer: cfg.Peer) !void {
            const peer_index = self.getPeerIndex(peer.id) orelse {
                std.log.err("Peer {} not found in peers array", .{peer.id});
                return error.PeerNotFound;
            };

            const next_idx = self.next_index[peer_index];
            const prev_log_index = if (next_idx > 0) next_idx - 1 else 0;
            const prev_log_term = self.log.getTermAtIndex(prev_log_index) orelse 0;

            const last_index = self.log.getLastIndex();

            // Collect entries to send (if any)
            var entries_to_send = std.ArrayList(LogEntry).init(self.allocator);
            defer entries_to_send.deinit();

            // Only send entries if we have new ones for this peer
            if (next_idx <= last_index) {
                var current_index = next_idx;
                while (current_index <= last_index) : (current_index += 1) {
                    if (self.log.getEntry(current_index)) |entry| {
                        entries_to_send.append(entry.*) catch |err| {
                            std.log.err("Failed to append entry {} to entries_to_send: {}", .{ entry.*, err });
                            return err;
                        };
                    }
                }
            }

            // const req = AppendEntriesRequest{
            const req = t.AppendEntries{
                .term = self.current_term,
                .leader_id = self.config.self_id,
                .prev_log_index = prev_log_index,
                .prev_log_term = prev_log_term,
                .entries = entries_to_send.items,
                .leader_commit = self.commit_index,
            };

            //
            //TODO
            _ = req;

            // Send the AppendEntries RPC
            // const response = self.rpc_client.sendAppendEntries(peer, req) catch |err| {
            //     std.log.err("Failed to send AppendEntries to peer {}: {}", .{ peer.id, err });
            //     return err;
            // };

            // // Handle response
            // try self.handleAppendEntriesResponse(peer_index, req, response);
        }
    };
}

pub fn Cluster(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        nodes: std.ArrayList(*RaftNode(T)),
        node_addresses: std.AutoHashMap(NodeId, t.PeerAddress),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) @This() {
            return Self{
                .allocator = allocator,
                .nodes = std.ArrayList(*RaftNode(T)).init(allocator),
                .node_addresses = std.AutoHashMap(NodeId, t.PeerAddress).init(allocator),
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
        pub fn addNodeAddress(self: *Self, id: NodeId, addr: t.PeerAddress) !void {
            try self.node_addresses.put(id, addr);
        }

        pub fn addNodeAddress2(self: *Self, id: NodeId, ip_addr: []const u8, ip_port: u16) !void {
            try self.node_addresses.put(id, t.PeerAddress{ .ip = ip_addr, .port = ip_port });
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

        //for TCP, sockets transport; real network, distributed clusters
        pub fn sendRpc(self: *Self, to_id: NodeId, msg: RpcMessage) !void {
            const addr = self.node_addresses.get(to_id) orelse return error.UnknownPeer;
            const stream = try std.net.tcpConnectToHost(self.allocator, addr.ip, addr.port);
            defer stream.close();
            try msg.serialize(stream.writer());
        }
    };
}
