# kernel/ — custom Armbian vendor kernel for the Orange Pi 4 Pro

Armbian's stock `vendor` kernel for this board (Allwinner A733 / sun60iw2, Linux 6.6) lacks
device-mapper, dm-crypt, iSCSI and CIFS — all of which Longhorn + LUKS need. `make kernel` rebuilds
the **same** kernel (same source branch, same Armbian commit the boards were imaged from) with a
different `.config`, packaged as the usual `linux-{image,dtb,headers}-vendor-sun60iw2` debs.

- `userpatches/extensions/k8s-storage.sh`      required: dm-crypt, XTS, ARMv8 crypto, iSCSI, CIFS
- `userpatches/extensions/docker-dns.sh`         host-side: public DNS for the build container (WSL2/Docker Desktop)
- `userpatches/extensions/headless-lowpower.sh` optional (default on): no HDMI/DRM/fb, sound, Wi-Fi, BT,
                                                 camera, codec, NPU, touchscreen → lower idle power
- `userpatches/VERSION`                          package version (`26.08.0-k8s.N`) — bump N on each rebuild
- `debs/`                                        build output, git-ignored; Ansible `roles/kernel` installs
                                                 these and `apt-mark hold`s them
- `build/`                                       armbian/build checkout + caches, git-ignored (~15 GB)

The Ubuntu tag in the build log is the Docker container the compiler runs in; the boards stay on Debian.
