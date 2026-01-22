# IPv6Monitor

Tool to monitor the IPv6 Default GW on macOS and reacquire it as needed.

## Headless / Server Setup (sudoers)

This application is designed to run on servers where the IPv6 default route might drop unexpectedly. To allow the app to automatically repair the route without user interaction (password prompt), you must configure `sudoers`.

### Configuration

It is recommended to use a separate file in `/private/etc/sudoers.d/` instead of editing the main `/etc/sudoers` file directly.

1.  Open Terminal.
2.  Create a new sudoers configuration file (e.g., `ipv6monitor`):
    ```bash
    sudo visudo -f /private/etc/sudoers.d/ipv6monitor
    ```
3.  Add the following line to the file (replace `your_username` with the user running the app):

    ```sudoers
    your_username ALL=(ALL) NOPASSWD: /sbin/route
    ```

    *Alternatively, for tighter security (restrict arguments):*
    
    ```sudoers
    your_username ALL=(ALL) NOPASSWD: /sbin/route -n add -inet6 default *
    ```

4.  Save and exit (in nano: `Ctrl+O`, `Enter`, `Ctrl+X`).

### Verification

To verify the setup works on modern macOS (Darwin 24+ / macOS 15+):

1.  Open a new Terminal window.
2.  Run the following command (it should **not** ask for a password):
    ```bash
    sudo -n route -n get -inet6 default
    ```
    *(Note: `get` is harmless. The app uses `add`, but if `get` works without password via `-n`, `add` will too if configured as `/sbin/route`)*.

## How it works

The app monitors the routing table using the SystemConfiguration API. If the default IPv6 route is missing:
1.  It attempts to discover the router using `ndp` (Neighbor Discovery Protocol) if not found via API.
2.  It executes `sudo -n /sbin/route add ...` to restore the route.
