# Example for the real TCP networking

create multiple config files; the skelleton will be:
```
self:
    # EDIT
    id: 2
    ip: "127.0.0.1"

    # EDIT
    port: 9002

peers:
    - id: 1
      ip: "127.0.0.1"
      port: 9001

    - id: 2
      ip: "127.0.0.1"
      port: 9002

    - id: 3
      ip: "127.0.0.1"
      port: 9003

    - id: 4
      ip: "127.0.0.1"
      port: 9004

```

that is, `self.id` and `self.port` will differ for each one:

```
# node 1
self:
    id: 1
    ip: "127.0.0.1"
    port: 9001


# node 2
self:
    id: 2
    ip: "127.0.0.1"
    port: 9002

# and so one
```

Then run multiple nodes in its own tab
```
./raft_node --config ./ex1_raft.yaml
./raft_node --config ./ex2_raft.yaml
./raft_node --config ./ex3_raft.yaml
./raft_node --config ./ex4_raft.yaml
./raft_node --config ./ex5_raft.yaml
```

Interract with them via the cli client
```
./raft_cli <TODO>
```
