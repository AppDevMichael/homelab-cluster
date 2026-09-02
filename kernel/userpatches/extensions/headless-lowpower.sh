# Armbian build extension — strip hardware the cluster nodes never use, to cut idle power draw and
# boot time. Everything here is built into the vendor kernel (=y), so blacklisting modules at runtime
# cannot turn it off; the config is the only switch.
#
# Consequence: NO HDMI output, NO framebuffer console. Recovery is via SSH, or the serial console on
# the debug UART (console=ttyS0 stays on). Build without this extension (`KERNEL_HEADLESS=0 make kernel`)
# if you need a screen.

function custom_kernel_config__headless_lowpower() {
	# Display pipeline: DE/TCON/HDMI/eDP/DSI/LVDS PHYs stay unpowered without a driver
	opts_n+=("AW_DRM")
	opts_n+=("DRM")
	opts_n+=("FB")
	opts_n+=("FRAMEBUFFER_CONSOLE")
	opts_n+=("AW_FB_CONSOLE")
	opts_n+=("LOGO")
	# Audio: codec, I2S, SPDIF, HDMI audio, USB audio
	opts_n+=("SOUND")
	# Wi-Fi (AIC8800 SDIO combo) + the vendor rfkill that powers the module up
	opts_n+=("AIC8800_WLAN_SUPPORT")
	opts_n+=("AIC8800_BTLPM_SUPPORT")
	opts_n+=("AIC_WLAN_SUPPORT")
	opts_n+=("MAC80211")
	opts_n+=("CFG80211")
	opts_n+=("WLAN")
	opts_n+=("WIRELESS")
	opts_n+=("AW_RFKILL")
	opts_n+=("RFKILL")
	# Bluetooth
	opts_n+=("BT")
	# Camera / video-in / IR
	opts_n+=("AW_VIDEO_SUNXI_VIN")
	opts_n+=("CSI_VIN")
	opts_n+=("MEDIA_SUPPORT")
	opts_n+=("VIDEO_DEV")
	opts_n+=("LIRC")
	# Video codec, NPU, 2D blitter, deinterlacer
	opts_n+=("AW_VIDEO_ENCODER_DECODER")
	opts_n+=("AW_NNA_VIP")
	opts_n+=("AW_G2D")
	opts_n+=("AW_DI")
	# Touchscreen
	opts_n+=("INPUT_TOUCHSCREEN")
}
