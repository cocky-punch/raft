const std = @import("std");
const t = @import("types.zig");
const builtin = @import("builtin");

pub const StateMachine = @import("state_machine.zig").StateMachine;
const RaftState = t.RaftState;
const NodeId = t.NodeId;
const RpcMessage = t.RpcMessage;
const Log = @import("log.zig").Log;
const LogEntry = @import("log.zig").LogEntry;
const cmd_mod = @import("command.zig");
const Command = cmd_mod.Command;
const ClientCommandResult = cmd_mod.ClientCommandResult;
const cfg = @import("config.zig");
const Config = cfg.Config;
const RaftError = @import("raft_error.zig").RaftError;

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
        last_successful_heartbeat: u64 = 0,

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
                .inbox = .empty,
                .nodes_buffer = .empty,
                .next_index = next_index,
                .match_index = match_index,
                .node_id_to_index = node_id_to_index,
                .state_machine = sm,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.next_index);
            self.allocator.free(self.match_index);
            self.log.deinit();
            self.config.deinit(self.allocator);

            self.node_id_to_index.deinit();
            self.inbox.deinit(self.allocator);
            self.nodes_buffer.deinit(self.allocator);

            //TODO
            // deinit self.snapshot
        }

        fn startElection(self: *RaftNode(T), cluster: *InMemorySimulatedCluster(T)) void {
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

        //NOTE
        //in-memory transport only
        pub fn processInMemoryData(self: *RaftNode(T), cluster: *InMemorySimulatedCluster(T)) void {
            const now_ms: u64 = @intCast(std.time.milliTimestamp());

            // Process incoming messages first
            while (self.inbox.items.len > 0) {
                if (self.inbox.pop()) |msg| {
                    switch (msg) {
                        .RequestVote => |req| self.handleRequestVote(req, cluster),
                        .RequestVoteResponse => |resp| self.handleRequestVoteResponse(resp, cluster),
                        .AppendEntries => |req| {
                            self.handleAppendEntries(req, cluster) catch |err| {
                                std.log.err("Failed to handle handleAppendEntries: {}", .{err});
                            };
                        },
                        .AppendEntriesResponse => |resp| {
                            self.handleAppendEntriesResponse(resp) catch |err| {
                                std.log.err("Failed to handle AppendEntriesResponse: {}", .{err});
                            };
                        },

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
                    if (now_ms >= self.election_deadline) {
                        self.startElection(cluster);
                    }
                },
                .Leader => {
                    // Send heartbeat regularly
                    sendHeartbeats(self);
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

        //in-memory only
        pub fn enqueueMessage(self: *RaftNode(T), msg: RpcMessage) !void {
            try self.inbox.append(self.allocator, msg);
        }

        //in-memory only
        pub fn processMessages(self: *RaftNode(T), cluster: *InMemorySimulatedCluster(T)) !void {
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
                            self.handleAppendEntriesResponse(resp);
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

        fn handleRequestVote(self: *RaftNode(T), req: t.RequestVote, cluster: *InMemorySimulatedCluster(T)) void {
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

        fn handleAppendEntries(self: *RaftNode(T), req: t.AppendEntries, cluster: *InMemorySimulatedCluster(T)) !void {
            // Reject requests from older terms
            if (req.term < self.current_term) {
                const resp = t.AppendEntriesResponse{
                    .term = self.current_term,
                    .success = false,
                    .follower_id = self.config.self_id,
                    .match_index = 0,
                };
                try cluster.sendMessage(req.leader_id, .{ .AppendEntriesResponse = resp });
                return;
            }

            // Valid AppendEntries - reset election timeout
            self.resetElectionTimeout();
            self.leader_id = req.leader_id;

            // If term is greater or equal, step down if needed
            if (req.term > self.current_term) {
                self.current_term = req.term;
                self.voted_for = null;
            }

            // Always become/stay follower when receiving valid AppendEntries
            if (self.state != .Follower) {
                self.becomeFollower();
            }

            // Log consistency check
            // Special case: prev_log_index = 0 means appending to empty log
            if (req.prev_log_index > 0) {
                const prev_log_term = self.log.getTermAtIndex(req.prev_log_index);
                if (prev_log_term == null or prev_log_term.? != req.prev_log_term) {
                    // Log doesn't match - send failure with our last log index
                    const resp = t.AppendEntriesResponse{
                        .term = self.current_term,
                        .success = false,
                        .follower_id = self.config.self_id,
                        .match_index = self.log.getLastIndex(), // Send our actual match
                    };
                    try cluster.sendMessage(req.leader_id, .{ .AppendEntriesResponse = resp });
                    return;
                }
            }

            // Append new entries, replacing conflicts
            if (req.entries.len > 0) {
                var i: usize = 0;
                while (i < req.entries.len) : (i += 1) {
                    const index = req.prev_log_index + 1 + i;
                    const existing = self.log.getEntry(index);

                    // If there's a conflict or no existing entry, truncate and append rest
                    if (existing == null or existing.?.term != req.entries[i].term) {
                        try self.log.truncateFrom(index);
                        try self.log.appendSlice(req.entries[i..]);
                        break;
                    }
                    // Else: entry matches, continue checking next
                }
            }

            // Update commit index based on leader's commit
            if (req.leader_commit > self.commit_index) {
                const last_new_entry = self.log.getLastIndex();
                self.commit_index = @min(req.leader_commit, last_new_entry);
                try self.applyCommitted();
            }

            // Send success response
            const resp = t.AppendEntriesResponse{
                .term = self.current_term,
                .success = true,
                .follower_id = self.config.self_id,
                .match_index = req.prev_log_index + req.entries.len,
            };
            try cluster.sendMessage(req.leader_id, .{ .AppendEntriesResponse = resp });

            std.log.debug("Accepted AppendEntries from leader {}: prev_log_index={}, entries={}, commit={}", .{
                req.leader_id,
                req.prev_log_index,
                req.entries.len,
                self.commit_index,
            });
        }

        fn handleRequestVoteResponse(self: *RaftNode(T), resp: t.RequestVoteResponse, cluster: *InMemorySimulatedCluster(T)) void {
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
                    self.becomeLeader() catch {
                        std.debug.print("Failed to becomeLeader for the node_id: {}\n", .{self.config.self_id});
                    };
                }
            }
        }

        fn sendHeartbeat(self: *Self, peer: cfg.Peer) !void {
            const peer_index = self.getPeerIndex(peer.id) orelse return error.PeerNotFound;

            const next_idx = self.next_index[peer_index];
            const prev_log_index = if (next_idx > 0) next_idx - 1 else 0;
            const prev_log_term = self.log.getTermAtIndex(prev_log_index) orelse 0;
            const last_index = self.log.getLastIndex();

            // Collect entries to send
            var entries_to_send: std.ArrayList(LogEntry) = .empty;
            defer entries_to_send.deinit(self.allocator);

            var current_index = next_idx;
            while (current_index <= last_index) {
                if (self.log.getEntry(current_index)) |entry| {
                    try entries_to_send.append(self.allocator, entry.*);
                }
                current_index += 1;
            }

            const req = t.AppendEntries{
                .term = self.current_term,
                .leader_id = self.config.self_id,
                .prev_log_index = prev_log_index,
                .prev_log_term = prev_log_term,
                .entries = entries_to_send.items,
                .leader_commit = self.commit_index,
            };

            switch (self.config.transport) {
                .json_rpc_http => {
                    //TODO http/https flag - from the config
                    const response0 = try self.sendJsonRpc(peer, RpcMessage{ .AppendEntries = req });
                    const response = response0.AppendEntriesResponse;

                    // Handle Raft protocol response logic
                    if (response.term > self.current_term) {
                        self.current_term = response.term;
                        self.state = .Follower;
                        return error.LeadershipLost;
                    }

                    if (!response.success) {
                        // Log inconsistency - decrement next_index and retry later
                        if (self.next_index[peer_index] > 0) {
                            self.next_index[peer_index] -= 1;
                        }
                        return error.LogInconsistency;
                    } else {
                        // Success - update next_index and match_index
                        self.next_index[peer_index] = prev_log_index + entries_to_send.items.len + 1;
                        self.match_index[peer_index] = prev_log_index + entries_to_send.items.len;
                    }
                },
                .grpc => {
                    // try self.sendGrpc(peer, req)
                    @panic("not implemented");
                },
                .msgpack_tcp => {
                    // try self.sendMsgPackTcp(peer, req)
                    @panic("not implemented");
                },
                .protobuf_tcp => {
                    // try self.sendProtobufTcp(peer, req)
                    @panic("not implemented");
                },
                .raw_tcp => {
                    // try self.sendRawTcp(peer, req)
                    @panic("not implemented");
                },
                .in_memory => {
                    // try self.sendInMemory(peer, req)
                    @panic("not implemented");
                },
            }
        }

        fn sendHeartbeats(self: *Self) void {
            for (self.config.peers) |peer| {
                if (peer.id == self.config.self_id) continue;
                self.sendHeartbeat(peer) catch |err| {
                    std.log.err("Failed to send heartbeat to node {}: {}\n", .{ peer.id, err });
                };
            }
        }

        //FIXME
        fn sendInMemory(self: *Self, peer: cfg.Peer, req: t.AppendEntries) !t.AppendEntriesResponse {
            // const target_node = self.transport.in_memory.cluster.getNode(peer.id) orelse return error.PeerNotFound;
            // const response = target_node.handleAppendEntries(req);

            // // Handle response same as network transports
            // if (response.term > self.current_term) {
            //     self.current_term = response.term;
            //     self.state = .Follower;
            //     return error.LeadershipLost;
            // }
            // // ... rest of response handling

            _ = self;
            _ = peer;
            _ = req;

            @panic("not implemented");
        }

        fn sendJsonRpc(self: *Self, peer: cfg.Peer, req: RpcMessage) !RpcMessage {
            const method = switch (req) {
                .RequestVote => "requestVote",
                .AppendEntries => "appendEntries",
                .InstallSnapshot => "installSnapshot",
                .TimeoutNow => "timeoutNow",
                .ClientCommand => "clientCommand",
                else => return error.InvalidRequestType,
            };

            const transport_config = switch (self.config.transport) {
                .json_rpc_http => |x| x,
                else => return error.InvalidTransport,
            };

            const rpc_request = struct {
                jsonrpc: []const u8 = "2.0",
                method: []const u8,
                params: RpcMessage,
                id: u32,
            }{
                .method = method,
                .params = req,
                // timestamp() returns an integer - keep it within u32
                .id = @intCast(std.time.timestamp() & 0xFFFFFFFF),
            };

            // Serialize JSON-RPC request into an allocating writer
            var payload_writer = std.Io.Writer.Allocating.init(self.allocator);
            // keep payload_writer alive until after fetch so the slice remains valid
            const fmt = std.json.fmt(rpc_request, .{ .whitespace = .indent_2 });
            try fmt.format(&payload_writer.writer);
            const protocol = if (transport_config.use_ssl_tls) "https" else "http";
            const url = try std.fmt.allocPrint(self.allocator, "{s}://{any}:{any}/rpc", .{ protocol, peer.ip, peer.port });
            defer self.allocator.free(url);

            // Prepare response writer (kept alive until after parsing)
            var response_writer = std.Io.Writer.Allocating.init(self.allocator);
            defer response_writer.deinit();
            const opts: std.http.Client.FetchOptions = .{
                .method = .POST,
                .location = .{ .url = url },
                .payload = payload_writer.writer.buffered(), // []const u8 payload
                .response_writer = &response_writer.writer,
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                    // TODO: add user-agent or other headers
                },
            };

            var client: std.http.Client = .{
                .allocator = self.allocator,
                .write_buffer_size = 8192,
            };

            defer client.deinit();
            const result = try client.fetch(opts);

            // check HTTP status
            if (result.status != .ok) {
                std.log.warn("HTTP error {} from peer {}\n", .{ @intFromEnum(result.status), peer.id });
                // deinit payload_writer before returning so its resources are freed
                payload_writer.deinit();
                return error.HttpError;
            }

            // get response bytes (they live in response_writer while it is not deinit'ed)
            const response_slice = response_writer.writer.buffered();

            // Parse JSON-RPC response envelope
            const JsonRpcResponse = struct {
                jsonrpc: []const u8,
                result: ?std.json.Value = null,
                @"error": ?struct {
                    code: i32,
                    message: []const u8,
                } = null,
                id: u32,
            };

            const parsed = std.json.parseFromSlice(JsonRpcResponse, self.allocator, response_slice, .{}) catch |err| {
                std.log.err("Failed to parse JSON-RPC response from peer {}: {}\n", .{ peer.id, err });
                payload_writer.deinit();
                return error.InvalidJsonRpcResponse;
            };

            defer parsed.deinit();
            const rpc_response = parsed.value;

            if (!std.mem.eql(u8, rpc_response.jsonrpc, "2.0")) {
                std.log.err("Invalid JSON-RPC version: {s}", .{rpc_response.jsonrpc});
                payload_writer.deinit();
                return error.RpcError;
            }

            if (rpc_response.@"error") |rpc_error| {
                std.log.warn("JSON-RPC error from peer {}: {} - {s}\n", .{ peer.id, rpc_error.code, rpc_error.message });
                payload_writer.deinit();
                return error.RpcError;
            }

            if (rpc_response.id != rpc_request.id) {
                std.log.warn("JSON-RPC response ID mismatch from peer {}: expected {}, got {}\n", .{ peer.id, rpc_request.id, rpc_response.id });
                payload_writer.deinit();
                return error.RpcIdMismatch;
            }

            const result_value = rpc_response.result orelse {
                std.log.err("Missing result in JSON-RPC response\n", .{});
                payload_writer.deinit();
                return error.MissingRpcResult;
            };

            // stringify the json::Value result into a buffer so we can parse it as RpcMessage
            var result_out = std.Io.Writer.Allocating.init(self.allocator);
            defer result_out.deinit();

            var result_stringifier = std.json.Stringify{
                .writer = &result_out.writer,
                .options = .{},
            };
            try result_stringifier.write(result_value);

            // Now parse the result JSON back into RpcMessage
            const parsed_result = std.json.parseFromSlice(RpcMessage, self.allocator, result_out.writer.buffered(), .{}) catch |err| {
                std.log.err("Failed to parse RPC result into RpcMessage: {}\n", .{err});
                payload_writer.deinit();
                return error.InvalidRpcResult;
            };
            defer parsed_result.deinit();

            // Validate response type matches the request type
            const is_valid_response = switch (req) {
                .RequestVote => switch (parsed_result.value) {
                    .RequestVoteResponse => true,
                    else => false,
                },
                .AppendEntries => switch (parsed_result.value) {
                    .AppendEntriesResponse => true,
                    else => false,
                },
                .InstallSnapshot => switch (parsed_result.value) {
                    .InstallSnapshotResponse => true,
                    else => false,
                },
                .TimeoutNow, .ClientCommand => switch (parsed_result.value) {
                    .Ack => true,
                    else => false,
                },
                else => false,
            };

            if (!is_valid_response) {
                std.log.warn("Response type mismatch for request type\n", .{});
                payload_writer.deinit();
                return error.ResponseTypeMismatch;
            }

            const out_msg = parsed_result.value;
            payload_writer.deinit();
            return out_msg;
        }

        // JSON detection
        fn isJsonData(data: []const u8) bool {
            const trimmed = std.mem.trim(u8, data, " \t\r\n");
            return trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[');
        }

        fn isProtobufData(data: []const u8) bool {
            _ = data;

            @panic("not implemented");
        }

        fn isMsgPackData(data: []const u8) bool {
            _ = data;

            @panic("not implemented");
        }

        fn isGrpcData(data: []const u8) bool {
            _ = data;

            @panic("not implemented");
        }

        fn isHttpRequest(data: []const u8) bool {
            _ = data;

            @panic("not implemented");
        }

        fn isBinaryData(data: []const u8) bool {
            // Check for non-printable characters
            for (data[0..@min(data.len, 100)]) |byte| {
                if (byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') {
                    return true;
                }
            }
            return false;
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

        fn detectTransportMismatch(self: *Self, peer_addr: []const u8, data: []const u8) void {
            switch (self.config.transport) {
                .json_rpc_http => {
                    if (isBinaryData(data)) {
                        //TODO: {any}
                        if (isProtobufData(data)) {
                            std.log.warn("Peer {any} sent Protobuf to JSON-RPC HTTP endpoint - peer likely using protobuf_tcp or grpc\n", .{peer_addr});
                        } else if (isMsgPackData(data)) {
                            std.log.warn("Peer {any} sent MessagePack to JSON-RPC HTTP endpoint - peer likely using msgpack_tcp\n", .{peer_addr});
                        } else {
                            std.log.warn("Peer {any} sent binary data to JSON-RPC HTTP endpoint - peer likely using raw_tcp\n", .{peer_addr});
                        }
                    }
                },
                .grpc => {
                    if (!isGrpcData(data)) {
                        if (isJsonData(data)) {
                            std.log.warn("Peer {any} sent JSON to gRPC endpoint - peer likely using json_rpc_http\n", .{peer_addr});
                        } else {
                            std.log.warn("Peer {any} sent non-gRPC data to gRPC endpoint\n", .{peer_addr});
                        }
                    }
                },
                .msgpack_tcp => {
                    if (!isMsgPackData(data)) {
                        if (isJsonData(data)) {
                            std.log.warn("Peer {any} sent JSON to MessagePack TCP endpoint - peer likely using json_rpc_http\n", .{peer_addr});
                        } else if (isProtobufData(data)) {
                            std.log.warn("Peer {any} sent Protobuf to MessagePack TCP endpoint - peer likely using protobuf_tcp\n", .{peer_addr});
                        }
                    }
                },
                .protobuf_tcp => {
                    if (!isProtobufData(data)) {
                        if (isJsonData(data)) {
                            std.log.warn("Peer {any} sent JSON to Protobuf TCP endpoint - peer likely using json_rpc_http\n", .{peer_addr});
                        } else if (isMsgPackData(data)) {
                            std.log.warn("Peer {any} sent MessagePack to Protobuf TCP endpoint - peer likely using msgpack_tcp\n", .{peer_addr});
                        }
                    }
                },
                .raw_tcp => {
                    // Raw TCP is flexible, but can still detect obvious mismatches
                    if (isHttpRequest(data)) {
                        std.log.warn("Peer {any} sent HTTP request to raw TCP endpoint - peer likely using json_rpc_http\n", .{peer_addr});
                    }
                },
                .in_memory => {
                    // Should never receive network data
                    std.log.warn("Peer {any} sent network data to in_memory transport - configuration error\n", .{peer_addr});
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
            const majority = (self.config.peers.len / 2) + 1;

            // sync version for simplicity
            // TODO - make it async
            //
            for (self.config.peers) |peer| {
                if (peer.id != self.config.self_id) {
                    if (self.sendHeartbeat(peer)) {
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
            for (self.config.peers, 0..) |peer, i| {
                if (peer.id == peer_id) return i;
            }

            return null; // Peer not found - this is an error condition
        }

        //TODO
        fn getPeerById(self: *Self, peer_id: u64) ?cfg.Peer {
            for (self.config.peers) |peer| {
                if (peer.id == peer_id) return peer;
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

        fn becomeLeader(self: *RaftNode(T)) !void {
            const count = self.config.peers.len;
            self.next_index = try self.allocator.alloc(usize, count);
            self.match_index = try self.allocator.alloc(usize, count);

            const initial_next_index = self.log.getLastIndex() + 1;
            @memset(self.next_index, initial_next_index);
            @memset(self.match_index, 0);

            self.sendHeartbeats();
        }


        //TODO
        fn createSnapshot(self: *RaftNode(T)) !void {
            _ = self;

            @panic("not implemented");
        }

        //TODO
        fn installSnapshot(self: *RaftNode(T), snap: t.InstallSnapshot, cluster: *InMemorySimulatedCluster(T)) !void {
            _ = self;
            _ = snap;
            _ = cluster;

            @panic("not implemented");
        }

        //TODO
        pub fn transferLeadership(self: *RaftNode(T), cluster: *InMemorySimulatedCluster(T), target_id: u64) void {
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

            const now_ms: u64 = @intCast(std.time.milliTimestamp());
            const lease_duration_ms = self.config.protocol.leader_lease_timeout_ms;
            return (now_ms - self.last_successful_heartbeat) < lease_duration_ms;
        }

        fn triggerReplication(self: *Self) !void {
            // Implementation depends on a replication mechanism
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

        // this handles both: heartbeats and log replication
        fn sendAppendEntries(self: *Self, peer: cfg.Peer) !void {
            const peer_index = self.getPeerIndex(peer.id) orelse {
                std.log.err("Peer {} not found in peers array", .{peer.id});
                return;
            };

            const next_idx = self.next_index[peer_index];
            const prev_log_index = if (next_idx > 0) next_idx - 1 else 0;
            const prev_log_term = self.log.getTermAtIndex(prev_log_index) orelse 0;
            const last_index = self.log.getLastIndex();

            // Collect entries to send (if any)
            var entries_to_send: std.ArrayList(LogEntry) = .empty;
            defer entries_to_send.deinit(self.allocator);

            // Only send entries if we have new ones for this peer
            if (next_idx <= last_index) {
                var current_index = next_idx;
                const max_entries = self.config.protocol.max_entries_per_append;
                while (current_index <= last_index) : (current_index += 1) {
                    if (self.log.getEntry(current_index)) |entry| {
                        try entries_to_send.append(self.allocator, entry.*);

                        // Check if we've reached the limit AFTER adding
                        if (entries_to_send.items.len >= max_entries) {
                            break;
                        }
                    }
                }
            }

            const append_entries_req = t.AppendEntries{
                .term = self.current_term,
                .leader_id = self.config.self_id,
                .prev_log_index = prev_log_index,
                .prev_log_term = prev_log_term,
                .entries = entries_to_send.items,
                .leader_commit = self.commit_index,
            };

            const req = RpcMessage{ .AppendEntries = append_entries_req };

            // Send the AppendEntries RPC and get response
            const response = self.sendJsonRpc(peer, req) catch |err| {
                std.log.err("Failed to send AppendEntries to peer {}: {}", .{ peer.id, err });
                return err;
            };

            std.log.debug("Sent AppendEntries to peer {}: prev_log_index={}, prev_log_term={}, entries_count={}, leader_commit={}", .{
                peer.id,
                prev_log_index,
                prev_log_term,
                entries_to_send.items.len,
                self.commit_index,
            });

            // Handle response
            switch (response) {
                .AppendEntriesResponse => |x| {
                    try self.handleAppendEntriesResponse(x);
                },
                else => {
                    std.log.err("Unexpected response type from peer {}: expected AppendEntriesResponse: {}", .{ peer.id, response });
                    return error.UnexpectedResponseType;
                },
            }
        }

        fn handleAppendEntriesResponse(self: *RaftNode(T), resp: t.AppendEntriesResponse) RaftError!void {
            // Step down if there's a higher term
            if (resp.term > self.current_term) {
                self.current_term = resp.term;
                self.becomeFollower();
                return;
            }

            // Ignore stale responses
            if (resp.term < self.current_term or self.state != .Leader) {
                return;
            }

            const follower_index = self.findNodeIndex(resp.follower_id) orelse return;
            if (resp.success) {
                // Update next_index and match_index
                self.match_index[follower_index] = resp.match_index;
                self.next_index[follower_index] = resp.match_index + 1;

                // Try to advance commit index
                try self.updateCommitIndex();
            } else {
                // Decrement next_index and retry
                if (self.next_index[follower_index] > 1) {
                    self.next_index[follower_index] -= 1;
                }

                // Immediately retry with the decremented index
                const peer = self.getPeerById(resp.follower_id) orelse return;

                //NOTE
                // Error is logged but not propagated - might be OK for network failures
                // revisit it
                self.sendAppendEntries(peer) catch |err| {
                    std.log.err("Failed to retry AppendEntries to follower {}: {}", .{ resp.follower_id, err });
                };
            }
        }

        fn updateCommitIndex(self: *RaftNode(T)) !void {
            if (self.state != .Leader) return;

            const old_commit_index = self.commit_index;
            const majority = (self.config.peers.len / 2) + 1;
            const last_index = self.log.getLastIndex();

            // Check each index from commit_index + 1 to last_index
            var n = self.commit_index + 1;
            while (n <= last_index) : (n += 1) {
                // Only commit entries from current term (Raft safety requirement)
                const term_at_n = self.log.getTermAtIndex(n) orelse continue;
                if (term_at_n != self.current_term) continue;

                // Count how many nodes have replicated this entry
                var replicated_count: usize = 1; // Count self
                for (self.match_index) |match_idx| {
                    if (match_idx >= n) {
                        replicated_count += 1;
                    }
                }

                // If majority has replicated, update commit_index
                if (replicated_count >= majority) {
                    self.commit_index = n;
                } else {
                    // Since we go in order, if this index isn't replicated enough,
                    // neither will higher indices
                    break;
                }
            }

            // Only apply if commit_index actually advanced
            if (self.commit_index > old_commit_index) {
                self.applyCommitted() catch |err| {
                    std.log.err("applyCommitted {}", .{err});
                };
            }
        }

        fn applyCommitted(self: *RaftNode(T)) !void {
            while (self.last_applied < self.commit_index) {
                self.last_applied += 1; // Increment first to get the next entry

                const entry = self.log.getEntry(self.last_applied) orelse {
                    std.log.err("Missing log entry at index {}", .{self.last_applied});
                    return;
                };

                if (self.state_machine) |sm| {
                    sm.applyLog(entry.*);
                }

                std.log.debug("Applied log entry at index {}", .{self.last_applied});
            }
        }
    };
}


// Cluster of the nodes if they're run "in-memory":
// on the single machine in a single process,
// without actual networking involved,
// communicating with each other via direct memory operations;
// Used for simulation and testing
pub fn InMemorySimulatedCluster(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        nodes: std.ArrayList(*RaftNode(T)),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) @This() {
            return Self{
                .allocator = allocator,
                .nodes = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            // Assuming Cluster does not own RaftNode(T) memory
            // self.nodes.deinit();
            // self.nodes.deinit(Self.allocator); // error - won't compile
            self.nodes.deinit(self.allocator);
        }

        pub fn addNode(self: *Self, node: *RaftNode(T)) !void {
            try self.nodes.append(node);
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


        // TODO: remove?
        // pub fn processInMemoryData(self: *Self) !void {
        //     for (self.nodes.items) |node| {
        //         node.processInMemoryData(self);
        //     }

        //     //TODO: merge the loops
        //     for (self.nodes.items) |node| {
        //         try node.processMessages(self);
        //     }
        // }
    };
}
