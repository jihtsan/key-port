public enum SSHAuthenticationPolicy {
    public static let passwordOnlyArguments = [
        "-o", "BatchMode=no",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "PreferredAuthentications=password",
        "-o", "PasswordAuthentication=yes",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PubkeyAuthentication=no",
        "-o", "IdentityAgent=none",
        "-o", "GSSAPIAuthentication=no",
        "-o", "HostbasedAuthentication=no",
    ]

    public static let publicKeyOnlyArguments = [
        "-o", "BatchMode=yes",
        "-o", "PreferredAuthentications=publickey",
        "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PubkeyAuthentication=yes",
        "-o", "IdentityAgent=none",
        "-o", "GSSAPIAuthentication=no",
        "-o", "HostbasedAuthentication=no",
    ]
}
