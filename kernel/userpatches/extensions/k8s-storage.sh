# Armbian build extension — enable the kernel features the cluster's storage layer needs.
#
# The stock Armbian vendor kernel for the Orange Pi 4 Pro (linux-sun60iw2-vendor.config) has no
# device-mapper at all, no iSCSI initiator and no CIFS client. Longhorn attaches volumes over iSCSI,
# the `longhorn-encrypted` StorageClass is LUKS (dm-crypt, aes-xts-plain64), and Longhorn's backup
# target on the Hetzner Storage Box is SMB.
#
# Option names are given without the CONFIG_ prefix (framework convention). `olddefconfig` runs
# afterwards and pulls in dependencies (libiscsi, crypto helpers, ...).

function custom_kernel_config__k8s_storage() {
	# device-mapper + LUKS
	opts_y+=("MD")                          # "Multiple devices" menu — gate for BLK_DEV_DM
	opts_m+=("BLK_DEV_DM")
	opts_m+=("DM_CRYPT")
	opts_m+=("CRYPTO_XTS")                  # aes-xts-plain64 (cryptsetup default)
	opts_m+=("CRYPTO_USER_API_SKCIPHER")    # lets cryptsetup use kernel crypto (and `cryptsetup benchmark`)
	# ARMv8 Crypto Extensions — A733 cores have them; makes LUKS throughput usable
	opts_m+=("CRYPTO_AES_ARM64_CE_BLK")
	opts_m+=("CRYPTO_SHA256_ARM64")
	opts_m+=("CRYPTO_SHA2_ARM64_CE")
	opts_m+=("CRYPTO_GHASH_ARM64_CE")
	# iSCSI initiator (Longhorn engine <-> node)
	opts_m+=("SCSI_ISCSI_ATTRS")
	opts_m+=("ISCSI_TCP")
	# SMB client (Longhorn backup target cifs://)
	opts_m+=("CIFS")
	opts_y+=("CIFS_XATTR")
	opts_y+=("CIFS_POSIX")
	opts_y+=("CIFS_DFS_UPCALL")
}
