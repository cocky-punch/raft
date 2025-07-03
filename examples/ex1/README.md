# Example for the real TCP networking

create multiple config files; the skelleton will be:
```
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
