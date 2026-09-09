module sshbox-notify

// Kept low deliberately: this binary gets built on whatever Go a server
// happens to have, and only needs stdlib plus x/oauth2.
go 1.22

// Newer x/oauth2 releases require Go 1.25, which would force a toolchain
// download on any server building this. This line is the last one that builds
// on Go 1.22.
require golang.org/x/oauth2 v0.21.0

require cloud.google.com/go/compute/metadata v0.3.0 // indirect
