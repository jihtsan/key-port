# KeyPort

KeyPort manages SSH access from one or more local devices to accounts on remote devices.

## Language

**Device**:
A physical or virtual machine that can be discovered locally, through Tailscale, or through synchronized metadata. A device may expose multiple SSH accounts.
_Avoid_: Server account, login

**SSH Account**:
A login identity on a device, uniquely identified by its device endpoint, port, and username. Each SSH account is represented as a separate server entry.
_Avoid_: Device, machine authorization

Server screens group SSH account records by endpoint. The common single-account case uses one compact row that combines the server identity with that account's username, alias, and authorization status; endpoints with multiple accounts show one server header followed by account rows. Aliases, passwords, and local authorization remain account-scoped.

**Current Device**:
The Mac currently running KeyPort and holding the local private keys used for SSH authorization.
_Avoid_: Server, remote device

**Local Authorization**:
Permission for a key from the current device to sign in to one specific SSH account without a password. Authorization is per SSH account, not per device.
_Avoid_: Device authorization, Tailscale authorization

**Account Password**:
The secret used to test and bootstrap one SSH account. It may be available on another current device through a secure credential store, but it is not device metadata.
_Avoid_: Device password, Tailscale password
