# IPv6Monitor

Tool to monitor the IPv6 default route on macOS and reacquire it as needed.

## Rationale

This tool was created to address a persistent issue where macOS sporadically loses its IPv6 default route, resulting in "No route to host" errors for any IPv6 traffic outside the local network.

This behavior has been frequently observed in environments using **Ubiquiti UniFi** gateways (like the UCG-Ultra or UDM), though it may occur with other equipment. The root cause appears to be a race condition in the macOS networking stack triggered by the presence of multiple IPv6 routers on the LAN—specifically when devices acting as Thread Border Routers (like Apple TVs, HomePods, or IoT hubs) broadcast Router Advertisements (RAs) alongside the main gateway.

When this happens, macOS incorrectly drops the default route, breaking IPv6 connectivity until the route is manually restored or the interface is cycled. This tool automates that restoration process.

**References:**
*   [Reddit: macOS losing IPv6 default route](https://www.reddit.com/r/MacOS/comments/1mpefc1/macos_losing_ipv6_default_route/)
*   [Reddit: Since switching to a UniFi Cloud Gateway, macOS loses IPv6 default route](https://www.reddit.com/r/Ubiquiti/comments/1ldoh16/since_switching_to_a_unifi_cloud_gateway_macos/)

## Installation

This application is open-source and intended to be built from source. You do **not** need a paid Apple Developer Program membership to run it.

### Prerequisites
*   A Mac running macOS 13 or later.
*   **Xcode** (available for free from the Mac App Store).

### Building the App
1.  Download or clone this repository.
2.  Open `IPv6Monitor.xcodeproj` in Xcode.
3.  In the top-left corner, ensure the `IPv6Monitor` target is selected and your Mac is chosen as the destination.
4.  Go to **Product > Archive** (or simply **Run** to test it).
5.  If Archiving: Once the archive is complete, click **Distribute App**, select **Custom**, then **Copy App**. This will give you the runnable `.app` file.
6.  Move the `IPv6Monitor.app` to your `/Applications` folder.

### Run on Startup
To ensure the monitor runs automatically:
1.  Open **System Settings**.
2.  Go to **General > Login Items**.
3.  Click the `+` button under "Open at Login".
4.  Select `IPv6Monitor.app`.

## Sudoers Configuration

This tool is designed to work automatically in the background without user intervention. Since modifying the system routing table requires root privileges, the app needs a way to run the `route` command as root.

To avoid the extreme complexity of privileged helpers and the associated code signing requirements (which usually require a paid Apple Developer account), this tool uses `sudo`. A one-time setup in your `sudoers` configuration is required to allow the app to fix the route without prompting for a password.

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

The app monitors the routing table using the SystemConfiguration API and by verifying the kernel routing table directly. If the default IPv6 route is missing:
1.  It attempts to discover the router using `ndp` (Neighbor Discovery Protocol) if not found via API.
2.  It executes `sudo -n /sbin/route add ...` to restore the route.
