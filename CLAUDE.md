@README.md

# Agentic Development Instructions

Run tests with a timeout to ensure they do not get stuck indefinitely (or become too slow):

```
timeout 120 dub test
timeout 120 nix flake check
```
