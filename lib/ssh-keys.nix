# The fleet's user SSH public keys — one list, consumed by
# hosts/common.nix (users.users.joshsymonds.openssh.authorizedKeys) and
# by shrike's home layer (nix-on-droid has no NixOS user machinery, so it
# writes ~/.ssh/authorized_keys directly).
[
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMnWlXMFExsVFYMB9eN63JcF3Ry3iFqA8KbebAwvBH4t josh+ninuan@joshsymonds.com"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINTWmaNJwRqzDMdfVOXbX6FNjcJ94VRK+aKLI2NqrcWV josh+morningstar@joshsymonds.com"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID0OvTKlW2Vk5WA11YOQ6SNDS4KsT9I1ffVGomswscZA josh+ultraviolet@joshsymonds.com"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBtAh5GIwBBQQ0IW0o+Y9HetITF2Khfeo5/QKCRzWSbY josh+shrike@joshsymonds.com"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIORmNHlIFi2MWPh9H0olD2VBvPNK7+wJkA+A/3wCOtZN josh+vermissian@joshsymonds.com"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKi6ZE7mq37XFkWvBDRAPP5eReUO5c0D2ngU4wEIhPhH josh+gnomon@joshsymonds.com"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIELbMyB/RzUvvwx8cNITJc3BrOdYktFXG66383oAtXUF joshsymonds+bluedesert@joshsymonds.com"
]
