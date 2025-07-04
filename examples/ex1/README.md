# Example for the real TCP networking

create multiple config files; the skelleton will be:
```
# ex1-1_raft.yaml
# EDIT
self_id: 1

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

`peers` must remain identical for all the config files; `self_id` will differ.

```
# ex1-4_raft.yaml
# EDIT
self_id: 4

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

Then run multiple nodes, each in its own tab
```
./raft_node --config ./ex1-1_raft.yaml
./raft_node --config ./ex1-2_raft.yaml
./raft_node --config ./ex1-3_raft.yaml
./raft_node --config ./ex1-4_raft.yaml
./raft_node --config ./ex1-5_raft.yaml
```

Interract with them via the cli client
```
./raft_cli 127.0.0.1 9002 set key1 fdsafdsafdsafd
```
