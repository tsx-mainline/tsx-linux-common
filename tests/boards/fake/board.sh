# board.sh of the made-up test board "fake". No real hardware is behind it.
# The tests of this repo use it in place of a real board file. Every value
# differs from the values of the real families on purpose. So a test fails
# when shared code still has a family value built in.
#
# The file follows the board interface (docs/layout.md "Board interface").
# A value that is in the environment wins. A test can change a value that way.
#
# Test hooks of this board:
#   TSX_MAC_DEV         a plain file with the MAC on its first line
#                       (default /etc/tsx/fake-mac)
#   TSX_FAKE_NO_MAC     any value: the board gives no MAC

TSX_FAMILY=${TSX_FAMILY:-fake}
TSX_APK_CATEGORY=${TSX_APK_CATEGORY:-fake}
TSX_HA_MODEL=${TSX_HA_MODEL:-FAKE-100}
TSX_SOUND_CARD=${TSX_SOUND_CARD:-FakeCard}
TSX_DISPLAY_DRM=${TSX_DISPLAY_DRM:-fakedrm*}
TSX_RENDER_DRM=${TSX_RENDER_DRM:-fakedrm*}
TSX_RENDER_ES2_DRM=${TSX_RENDER_ES2_DRM-}
TSX_DISPLAY_ENV=${TSX_DISPLAY_ENV-}
TSX_BT_CHIP=${TSX_BT_CHIP:-none}
TSX_BT_PROXY_DEFAULT=${TSX_BT_PROXY_DEFAULT:-on}
TSX_BT_MAC_SETTABLE=${TSX_BT_MAC_SETTABLE:-no}
TSX_MAC_SOURCE=${TSX_MAC_SOURCE:-fakefile}
TSX_MAC_DEV=${TSX_MAC_DEV:-/etc/tsx/fake-mac}
TSX_SERIAL_CONSOLE=${TSX_SERIAL_CONSOLE:-ttyFAKE0}
TSX_RENDER_ENV=${TSX_RENDER_ENV-}
TSX_BROWSER_GL_FLAGS=${TSX_BROWSER_GL_FLAGS-}
TSX_VOLUME_CMD=${TSX_VOLUME_CMD-}
TSX_RESCUE_BACKLIGHT=${TSX_RESCUE_BACKLIGHT:-35}

# The board keeps no data in a store that needs a reader. The functions
# print fixed values, and the MAC comes from a plain file.
tsx_board_load() { :; }
tsx_board_probe() { return 0; }
tsx_board_model() { echo FAKE-100; }
tsx_board_stock_fw() { echo v7.3.1; }
tsx_board_unit_id() { echo fake-0001; }
tsx_board_hostname_hint() { :; }
tsx_board_mac_early() {
	[ -z "${TSX_FAKE_NO_MAC:-}" ] && [ -r "$TSX_MAC_DEV" ] || return 0
	_tb_m=$(head -n 1 "$TSX_MAC_DEV")
	echo "$_tb_m" | grep -qiE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' && echo "$_tb_m"
	return 0
}
tsx_board_mac() { tsx_board_mac_early; }
tsx_board_mac_source() { echo "$TSX_MAC_SOURCE"; }
tsx_board_rescue_extra() { echo "board line   : fake"; }
