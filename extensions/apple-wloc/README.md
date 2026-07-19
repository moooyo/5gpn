# Apple WLOC Location Override

This directory contains a normal `5gpn.io/v1` extension. It is not compiled
into either 5gpn daemon and is not installed automatically.

Install the manifest from the Console's **Install from URL** action:

```text
https://raw.githubusercontent.com/moooyo/5gpn/main/extensions/apple-wloc/extension.yaml
```

The Console renders the manifest's required `location` setting with the shared
map point picker. Enabling the extension captures only the two hosts declared
in `traffic.captureHosts`. The response script runs in the standard isolated
extension sandbox, declares no additional network origin or required egress
binding, and the transformed upstream request still exits through mihomo.
