---
status: proposed
---

# Graph is a projection of Host v6 access facts

KeyPort will derive visual nodes and edges from the existing `HostV6.SyncedGraph` and device-local evidence rather than persist a second canvas graph or adopt a graph database. A rendered device-to-host edge must remain traceable through Device, SSHKeyRecord, Authorization, SSH Account, and Host; Host-to-service and account-to-actual-node edges must likewise come from SavedService and NodeAssociation.

Layout metadata may be reset without changing access, arbitrary lines cannot create authorization, and future user-defined dependency edges require their own typed domain record instead of overloading Authorization or NodeAssociation.
