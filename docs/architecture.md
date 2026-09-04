# Architecture Overview

A role-level view of the host and how the two long-running LXCs divide
responsibility. Individual services are listed in the [main README](../README.md);
this document is about the shape of the system, not its contents.

---

## 1. The host

One bare-metal node running Proxmox VE. Everything else is an unprivileged
Debian LXC with Docker inside it — no full VMs, so there is no second kernel or
guest memory reservation to pay for.

```mermaid
graph TB
    subgraph METAL["Bare metal — single node"]
        CPU["CPU · RAM · integrated GPU"]
        NIC["1 GbE NIC"]
        SSD[("SSD<br/>hypervisor + container rootfs")]
        POOL[("ZFS pool<br/>application data")]
        BULK[("HDD<br/>bulk media + backup target")]
    end

    CPU --> PVE["Proxmox VE"]
    NIC --> BR["Linux bridge<br/>guests sit directly on the LAN"]
    PVE --> BR

    PVE --> N["LXC · network"]
    PVE --> A["LXC · apps"]
    PVE --> L["LXC · llm"]

    BR -.veth.-> N
    BR -.veth.-> A
    BR -.veth.-> L

    POOL -.->|"bind mount"| A
    BULK -.->|"bind mount"| A
    CPU -.->|"GPU device passthrough<br/>hardware transcoding"| A

    style N fill:#1a2a3a,color:#fff
    style A fill:#2a1a3a,color:#fff
    style L fill:#1a3a2a,color:#fff
```

Guests are bridged rather than NATed, so each one holds its own static LAN
address and is reachable without hairpinning through the host.

Storage is split by access pattern rather than by owner: the SSD carries the
hypervisor and the container root filesystems, a ZFS pool carries application
state that benefits from checksums and snapshots, and a large HDD carries bulk
media plus the backup target — it can idle and spin down without stalling
anything interactive.

---

## 2. How the two LXCs interact

The split is deliberate: **network** is the edge and **apps** is the workload.
Nothing in the apps container talks to the internet directly, and nothing in the
network container stores application state.

```mermaid
graph LR
    WAN(["Internet"])
    ADMIN(["Remote admin"])
    LAN(["LAN clients"])

    subgraph NET["LXC · network — edge"]
        TUN["Tunnel client<br/>outbound-only, no open ports"]
        VPN["Mesh VPN node"]
        FILTER["Filtering DNS server<br/>:53 for the whole LAN"]
        RESOLV["Recursive resolver<br/>loopback-bound"]
        FILTER --> RESOLV
    end

    subgraph APP["LXC · apps — workload"]
        RP["Reverse proxy<br/>single ingress point"]
        IDS["Intrusion detection"]
        SHARED["shared proxy network"]
        PRIV["per-stack private networks<br/>service + database + cache"]
        RP --> SHARED --> PRIV
    end

    WAN -->|"inbound sessions"| TUN
    ADMIN --> VPN
    LAN -->|"DNS"| FILTER

    TUN -->|"HTTP across the bridge"| RP
    VPN -.->|"admin reaches both<br/>without public exposure"| APP
    APP -->|"every container resolves here"| FILTER
    RESOLV -->|"queries root servers directly"| WAN

    RP -->|"access log"| IDS
    IDS -->|"block decisions"| RP

    style NET fill:#1a2a3a,color:#fff
    style APP fill:#2a1a3a,color:#fff
```

Four things cross the boundary between them, and only four:

| Direction | What crosses | Why |
| :--- | :--- | :--- |
| network → apps | Inbound HTTP from the tunnel | The tunnel client terminates outside, then hands plain HTTP to the reverse proxy over the LAN bridge. |
| apps → network | DNS queries | Every container inherits the filtering resolver, so blocklists and query logs cover the whole estate, not just browsers. |
| network → both | Mesh VPN reachability | Admin interfaces are never published through the tunnel; they are reached over the VPN only. |
| apps → network | Management agent traffic | A single container-management UI in apps drives lightweight agents in the other LXCs, giving one pane across all three. |

Inside apps, the reverse proxy is the only container on both the shared proxy
network and the outside world. Each application stack keeps its database and
cache on a private network of its own, so a compromised front end cannot reach
another stack's data store.

The reverse proxy and the intrusion-detection service form a closed loop: the
proxy writes structured access logs to a shared volume, the IDS reads them and
scores the traffic, and the proxy queries it back on every request to decide
whether to serve or drop.

---

## 3. Startup order

```mermaid
graph LR
    P(["Host boot"]) --> PVE["Proxmox VE"]
    PVE -->|"start order 1"| N["LXC · network"]
    N --> DNS(["DNS answering"])
    DNS -->|"fixed delay, then start order 2"| A["LXC · apps"]
    A --> SVC(["Services up"])
```

Ordering is explicit rather than incidental. The apps container resolves registry
and API hostnames as soon as Docker starts, so the edge container has to be
answering DNS before it comes up — otherwise the first minute after every reboot
is a wave of resolution failures and restart backoff.

---

## 4. Configuration flow

The host pulls live configuration out of each container on a schedule and
commits it here. The repository is a **mirror, not a deployment source** — edits
land on the running containers first, and the sync catches up.

```mermaid
graph LR
    C1["LXC · network"] -->|"pull"| S["sync job on the host<br/>scheduled nightly"]
    C2["LXC · apps"] -->|"pull"| S
    C3["LXC · llm"] -->|"pull"| S
    S --> SCAN{"secret scan"}
    SCAN -->|"clean"| REPO[("this repository")]
    SCAN -->|"finding"| STOP["abort — nothing committed"]

    style STOP stroke-dasharray: 4 4
```

Application data is backed up separately and never enters this repository:
the ZFS pool replicates to the bulk HDD on its own schedule, with database
dumps taken from inside the running containers.
