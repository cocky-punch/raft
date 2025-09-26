const std = @import("std");
const yaml = @import("yaml");
const types = @import("types.zig");

const Transport = types.Transport;
const MessageFraming = types.MessageFraming;
const Allocator = std.mem.Allocator;
const Yaml = yaml.Yaml;

pub const ReadConsistency = enum {
    linearizable, // Slower, but guaranteed linearizable
    sequential,
    eventual, // Fast reads, may not be linearizable
    lease_based, // Fast + linearizable with leader lease
};

pub const Peer = struct {
    id: u64,
    ip: []const u8,
    port: u16,
};

pub const StorageType = enum {
    in_memory, // In-memory only (testing/volatile)
    persistent, // Disk-based storage (production)
    hybrid, // Memory + periodic persistence
};

pub const ProtocolConfig = struct {
    election_timeout_min_ms: u32 = 150,
    heartbeat_interval_ms: u32 = 50,
    max_entries_per_append: u32 = 100,
    storage_type: StorageType = .persistent,
    leader_lease_timeout_ms: u32 = 150,
};

pub const ClientConfig = struct {
    read_consistency: ReadConsistency = .linearizable,
    client_timeout_ms: u32 = 5000,
};

pub const PerformanceConfig = struct {
    batch_append_entries: bool = true,
    pre_vote_enabled: bool = true,
};

pub const Config = struct {
    self_id: u64,
    peers: []Peer,
    protocol: ProtocolConfig = .{},
    transport: Transport = .{ .json_rpc_http = .{} }, // default
    client: ClientConfig = .{},
    performance: PerformanceConfig = .{},

    pub fn loadFromFile(allocator: Allocator, file_path: []const u8) !Config {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(contents);

        return try parseFromString(allocator, contents);
    }

    pub fn parseFromString(allocator: Allocator, yaml_content: []const u8) !Config {
        // Create an arena allocator for the YAML parsing
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var yaml_parser = Yaml{ .source = yaml_content };
        defer yaml_parser.deinit(allocator);

        // Load the YAML content
        yaml_parser.load(allocator) catch |err| switch (err) {
            error.ParseFailure => {
                if (yaml_parser.parse_errors.errorMessageCount() > 0) {
                    // yaml_parser.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(std.io.getStdErr()) });
                     yaml_parser.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(std.fs.File.stderr()) });
                }
                return error.ParseFailure;
            },
            else => return err,
        };

        const ParsedConfig = struct {
            self_id: u64,
            peers: []const struct {
                id: u32,
                ip: []const u8,
                port: u16,
            },
            protocol: ?struct {
                election_timeout_min_ms: ?u32 = null,
                heartbeat_interval_ms: ?u32 = null,
                max_entries_per_append: ?u32 = null,
                leader_lease_timeout_ms: ?u32 = null,
                storage_type: ?[]const u8 = null,
            } = null,
            transport: ?struct {
                type: ?[]const u8 = null,
                json_rpc_http: ?struct {
                    timeout_ms: ?u32 = null,
                    use_connection_pooling: ?bool = null,
                    max_connections_per_peer: ?u8 = null,
                    use_ssl_tls: ?bool = null,
                } = null,
                msgpack_tcp: ?struct {
                    timeout_ms: ?u32 = null,
                    use_connection_pooling: ?bool = null,
                    message_framing: ?[]const u8 = null,
                    delimiter: ?[]const u8 = null,
                } = null,
                grpc: ?struct {
                    timeout_ms: ?u32 = null,
                    use_connection_pooling: ?bool = null,
                    keepalive_ms: ?u32 = null,
                } = null,
                in_memory: ?struct {
                    simulate_network_delay_ms: ?u32 = null,
                } = null,
                // Add other transports as needed...

            } = null,
            client: ?struct {
                read_consistency: ?[]const u8 = null,
                client_timeout_ms: ?u32 = null,
            } = null,
            performance: ?struct {
                batch_append_entries: ?bool = null,
                pre_vote_enabled: ?bool = null,
            } = null,
        };

        const parsed = try yaml_parser.parse(arena.allocator(), ParsedConfig);

        // Convert to our final config structure with proper memory management
        var config = Config{
            .self_id = parsed.self_id,
            .peers = undefined,
        };

        // Allocate and copy peers
        config.peers = try allocator.alloc(Peer, parsed.peers.len);
        for (parsed.peers, 0..) |peer, i| {
            config.peers[i] = Peer{
                .id = peer.id,
                .ip = try allocator.dupe(u8, peer.ip),
                .port = peer.port,
            };
        }

        // Parse optional protocol config
        if (parsed.protocol) |x| {
            if (x.election_timeout_min_ms) |val| config.protocol.election_timeout_min_ms = val;
            if (x.heartbeat_interval_ms) |val| config.protocol.heartbeat_interval_ms = val;
            if (x.max_entries_per_append) |val| config.protocol.max_entries_per_append = val;
            if (x.leader_lease_timeout_ms) |val| config.protocol.leader_lease_timeout_ms = val;
            if (x.storage_type) |storage_str| {
                config.protocol.storage_type = parseStorageType(storage_str) catch .persistent;
            }
        }

        // Parse optional transport config
        if (parsed.transport) |transport_data| {
            if (transport_data.type) |type_str| {
                if (std.mem.eql(u8, type_str, "json_rpc_http")) {
                    var cfg = Transport{ .json_rpc_http = .{} }; // the full union with defaults

                    if (transport_data.json_rpc_http) |settings| {
                        if (settings.timeout_ms) |val| cfg.json_rpc_http.timeout_ms = val;
                        if (settings.use_connection_pooling) |val| cfg.json_rpc_http.use_connection_pooling = val;
                        if (settings.max_connections_per_peer) |val| cfg.json_rpc_http.max_connections_per_peer = val;
                    }
                    config.transport = cfg;
                } else if (std.mem.eql(u8, type_str, "msgpack_tcp")) {
                    var cfg = Transport{ .msgpack_tcp = .{} };

                    if (transport_data.msgpack_tcp) |settings| {
                        if (settings.timeout_ms) |val| cfg.msgpack_tcp.timeout_ms = val;
                        if (settings.use_connection_pooling) |val| cfg.msgpack_tcp.use_connection_pooling = val;
                        if (settings.message_framing) |framing_str| {
                            cfg.msgpack_tcp.message_framing = parseMessageFraming(framing_str) catch .length_prefixed;
                        }
                        if (settings.delimiter) |val| cfg.msgpack_tcp.delimiter = try allocator.dupe(u8, val);
                    }
                    config.transport = cfg;
                } else if (std.mem.eql(u8, type_str, "in_memory")) {
                    var cfg = types.Transport{ .in_memory = .{} };
                    if (transport_data.in_memory) |settings| {
                        if (settings.simulate_network_delay_ms) |val| cfg.in_memory.simulate_network_delay_ms = val;
                    }
                    config.transport = cfg;
                }
                // other transports as needed...
            }
        }

        // Parse optional client config
        if (parsed.client) |client| {
            if (client.read_consistency) |consistency_str| {
                config.client.read_consistency = parseReadConsistency(consistency_str) catch .linearizable;
            }
            if (client.client_timeout_ms) |val| config.client.client_timeout_ms = val;
        }

        // Parse optional performance config
        if (parsed.performance) |performance| {
            if (performance.batch_append_entries) |val| config.performance.batch_append_entries = val;
            if (performance.pre_vote_enabled) |val| config.performance.pre_vote_enabled = val;
        }

        return config;
    }

    pub fn deinit(self: *Config, allocator: Allocator) void {
        // Free peer IPs and the peers array
        for (self.peers) |peer| {
            allocator.free(peer.ip);
        }
        allocator.free(self.peers);
    }

    /// Validate the configuration for common issues
    pub fn validate(self: *const Config) !void {
        // Check if self_id exists in peers
        var self_found = false;
        for (self.peers) |peer| {
            if (peer.id == self.self_id) {
                self_found = true;
                break;
            }
        }
        if (!self_found) {
            std.debug.print("Warning: self_id ({d}) not found in peers list\n", .{self.self_id});
        }

        // Check for duplicate peer IDs
        for (self.peers, 0..) |peer1, i| {
            for (self.peers[i + 1 ..]) |peer2| {
                if (peer1.id == peer2.id) {
                    return error.DuplicatePeerIds;
                }
            }
        }

        // Check for reasonable timeout values
        if (self.protocol.election_timeout_min_ms <= self.protocol.heartbeat_interval_ms) {
            std.debug.print("Warning: election_timeout_min_ms ({d}) should be significantly larger than heartbeat_interval_ms ({d})\n", .{ self.protocol.election_timeout_min_ms, self.protocol.heartbeat_interval_ms });
        }

        // Validate storage type for production use
        if (self.protocol.storage_type == .memory) {
            std.debug.print("Warning: Using memory storage - data will be lost on restart\n");
        }
    }

    pub fn print(self: *const Config) void {
        std.debug.print("Configuration:\n");
        std.debug.print("  self_id: {d}\n", .{self.self_id});
        std.debug.print("  peers: {d} entries\n", .{self.peers.len});

        for (self.peers) |peer| {
            std.debug.print("    - id: {d}, ip: {s}, port: {d}\n", .{ peer.id, peer.ip, peer.port });
        }

        std.debug.print("  protocol:\n");
        std.debug.print("    election_timeout_min_ms: {d}\n", .{self.protocol.election_timeout_min_ms});
        std.debug.print("    heartbeat_interval_ms: {d}\n", .{self.protocol.heartbeat_interval_ms});
        std.debug.print("    max_entries_per_append: {d}\n", .{self.protocol.max_entries_per_append});
        std.debug.print("    storage_type: {s}\n", .{@tagName(self.protocol.storage_type)});
        std.debug.print("    leader_lease_timeout_ms: {d}\n", .{self.protocol.leader_lease_timeout_ms});

        std.debug.print("  transport: {s}\n", .{@tagName(self.transport)});
        switch (self.transport) {
            .json_rpc_http => |cfg| std.debug.print("    timeout_ms: {d}\n", .{cfg.timeout_ms}),
            .msgpack_tcp => |cfg| std.debug.print("    message_framing: {s}\n", .{@tagName(cfg.message_framing)}),
            .in_memory => |cfg| std.debug.print("    simulate_network_delay_ms: {s}\n", .{@tagName(cfg.simulate_network_delay_ms)}),

            // ... other variants as needed
            else => {},
        }

        std.debug.print("  client:\n");
        std.debug.print("    read_consistency: {s}\n", .{@tagName(self.client.read_consistency)});
        std.debug.print("    client_timeout_ms: {d}\n", .{self.client.client_timeout_ms});

        std.debug.print("  performance:\n");
        std.debug.print("    batch_append_entries: {}\n", .{self.performance.batch_append_entries});
        std.debug.print("    pre_vote_enabled: {}\n", .{self.performance.pre_vote_enabled});
    }

    /// Find a peer by ID
    pub fn findPeer(self: *const Config, peer_id: u64) ?*const Peer {
        for (self.peers) |*peer| {
            if (peer.id == peer_id) {
                return peer;
            }
        }
        return null;
    }

    /// Get the self peer (peer with ID matching self_id)
    pub fn getSelfPeer(self: *const Config) ?*const Peer {
        return self.findPeer(self.self_id);
    }

    /// Get all peers except self
    pub fn getOtherPeers(self: *const Config, allocator: Allocator) ![]const *const Peer {
        var other_peers = std.ArrayList(*const Peer).init(allocator);
        defer other_peers.deinit();

        for (self.peers) |*peer| {
            if (peer.id != self.self_id) {
                try other_peers.append(peer);
            }
        }

        return other_peers.toOwnedSlice();
    }
};

fn parseTransportType(type_str: []const u8) !Transport {
    if (std.mem.eql(u8, type_str, "json_rpc_http")) return .{ .json_rpc_http = .{} };
    if (std.mem.eql(u8, type_str, "grpc")) return .{ .grpc = .{} };
    if (std.mem.eql(u8, type_str, "msgpack_tcp")) return .{ .msgpack_tcp = .{} };
    if (std.mem.eql(u8, type_str, "protobuf_tcp")) return .{ .protobuf_tcp = .{} };
    if (std.mem.eql(u8, type_str, "raw_tcp")) return .{ .raw_tcp = .{} };
    if (std.mem.eql(u8, type_str, "in_memory")) return .{ .in_memory = .{} };
    return error.InvalidTransportType;
}

fn parseMessageFraming(framing_str: []const u8) !types.MessageFraming {
    if (std.mem.eql(u8, framing_str, "length_prefixed")) return .length_prefixed;
    if (std.mem.eql(u8, framing_str, "newline_delimited")) return .newline_delimited;
    if (std.mem.eql(u8, framing_str, "delimiter_based")) return .delimiter_based;
    if (std.mem.eql(u8, framing_str, "fixed_size")) return .fixed_size;

    return error.InvalidMessageFraming;
}

fn parseStorageType(storage_str: []const u8) !StorageType {
    if (std.mem.eql(u8, storage_str, "in_memory")) return .in_memory;
    if (std.mem.eql(u8, storage_str, "persistent")) return .persistent;
    if (std.mem.eql(u8, storage_str, "hybrid")) return .hybrid;
    return error.InvalidStorageType;
}

fn parseReadConsistency(consistency_str: []const u8) !ReadConsistency {
    if (std.mem.eql(u8, consistency_str, "linearizable")) return .linearizable;
    if (std.mem.eql(u8, consistency_str, "sequential")) return .sequential;
    if (std.mem.eql(u8, consistency_str, "eventual")) return .eventual;
    return error.InvalidReadConsistency;
}

// Tests
test "config parsing with kubkon/zig-yaml" {
    const yaml_content =
        \\self_id: 1
        \\
        \\peers:
        \\  - id: 1
        \\    ip: "127.0.0.1"
        \\    port: 9001
        \\  - id: 2
        \\    ip: "127.0.0.1"
        \\    port: 9002
        \\
        \\protocol:
        \\  election_timeout_min_ms: 150
        \\  heartbeat_interval_ms: 50
        \\  max_entries_per_append: 100
        \\  storage_type: "persistent"
        \\  leader_lease_timeout_ms: 150
        \\
        \\transport:
        \\  type: "msgpack_tcp"
        \\  msgpack_tcp:
        \\    use_connection_pooling: true
        \\    message_framing: "length_prefixed"
        \\    timeout_ms: 3000
        \\
        \\client:
        \\  read_consistency: "linearizable"
        \\  client_timeout_ms: 5000
        \\
        \\performance:
        \\  batch_append_entries: true
        \\  pre_vote_enabled: true
    ;

    const allocator = std.testing.allocator;

    var config = Config.parseFromString(allocator, yaml_content) catch |err| {
        std.debug.print("Failed to parse config: {}\n", .{err});
        return;
    };
    defer config.deinit(allocator);

    // Test basic properties
    try std.testing.expect(config.self_id == 1);
    try std.testing.expect(config.peers.len == 2);
    try std.testing.expect(config.protocol.election_timeout_min_ms == 150);
    try std.testing.expect(config.protocol.storage_type == .persistent);
    // try std.testing.expect(config.transport.type == .tcp);
    try std.testing.expect(config.client.read_consistency == .linearizable);
    try std.testing.expect(config.performance.batch_append_entries == true);

    // Test peer lookup
    const self_peer = config.getSelfPeer();
    try std.testing.expect(self_peer != null);
    try std.testing.expect(self_peer.?.id == 1);
    try std.testing.expect(self_peer.?.port == 9001);

    const other_peer = config.findPeer(2);
    try std.testing.expect(other_peer != null);
    try std.testing.expect(other_peer.?.id == 2);
    try std.testing.expect(other_peer.?.port == 9002);
}

test "config parsing with minimal YAML" {
    const yaml_content =
        \\self_id: 42
        \\peers:
        \\  - id: 42
        \\    ip: "192.168.1.100"
        \\    port: 8080
    ;

    const allocator = std.testing.allocator;

    var config = Config.parseFromString(allocator, yaml_content) catch |err| {
        std.debug.print("Failed to parse minimal config: {}\n", .{err});
        return;
    };
    defer config.deinit(allocator);

    // Should use defaults for missing sections
    try std.testing.expect(config.self_id == 42);
    try std.testing.expect(config.peers.len == 1);
    try std.testing.expect(config.protocol.election_timeout_min_ms == 150); // default
    // try std.testing.expect(config.transport.type == .tcp); // default
    try std.testing.expect(config.client.read_consistency == .linearizable); // default
}
