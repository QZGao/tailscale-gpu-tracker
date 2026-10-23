# Tailscale GPU Tracker

A native macOS app for checking NVIDIA GPU usage across your Tailscale machines.

The app reads the installed Tailscale client's machine list. Enter each machine's SSH username and check its box to start monitoring. Click a machine name to set an alias. Aliases, usernames, and monitoring selections are saved on this Mac.

GPU usage refreshes every minute. Click a checked row's GPU cell for an immediate refresh without changing the automatic schedule. While refreshing, a spinner precedes the previous reading and the menu bar keeps its previous percentage. The total is the arithmetic mean of all GPU utilization readings. Each circle shows one GPU's percentage; hover over it for the GPU index. If a GPU cannot report utilization, its circle and the total show an unavailable value.

The menu bar shows each selected machine's initial in a box followed by its percentage, with `·` between machines. Aliases take precedence. The first query shows `…`; a failed query shows `!`. Open the menu for details or to reopen the window. Closing the window keeps monitoring active. Reopening the app brings its existing window forward. Drag a window edge or corner to resize it.

## Requirements

- macOS 14 or later.
- An installed, connected Tailscale client.
- NVIDIA GPUs with `nvidia-smi` available on the selected machines.
- Existing SSH access to the selected remote account.

The app uses your current Tailscale session and system SSH client. For machines that advertise Tailscale SSH host keys, it verifies the connection against those keys. Other SSH servers use your existing SSH configuration and known hosts. Connections run without password prompts. Access failures appear in the GPU cell, with the full message available on hover.

The SSH username identifies the remote account, such as `root` or `ubuntu`. SSH host keys identify the server. [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh) uses your Tailscale identity to authorize access to the requested account.

## Build and run

With the Xcode command line tools installed:

```sh
make build
open "build/Tailscale GPU Tracker.app"
```

Run `make test` for parser, connection argument, process cancellation, and timeout tests. Run `make package` to create `build/Tailscale-GPU-Tracker.zip`. The build targets the Mac's current architecture and uses local ad-hoc signing.

Quit the running app before opening a UI preview with sample machines and isolated preferences:

```sh
swift run TailscaleGPUTracker --preview
```

The preview is available in debug builds and makes no network connections.
