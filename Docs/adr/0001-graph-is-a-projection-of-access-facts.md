---
status: proposed
---

# Graph is a projection of normalized access facts

KeyPort will persist devices, remote resources, access profiles, SSH identities, key grants, services, and explicit topology relations as normalized facts, then derive Graph nodes and edges from them. The canvas itself will not become an authorization source of truth and the project will not adopt a graph database for this feature, because SSH access must remain traceable to a specific identity, account-level access profile, remote observation, and security decision while CloudKit continues to synchronize entity-level records.

The consequence is that layout metadata may be lost or reset without changing access, arbitrary lines cannot create authorization, and every rendered access edge must expose the facts and evidence that produced it.
