FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
SRC_URI += "file://0001-enable-uart1.patch"
SRC_URI += "file://0002-reset-ahb-window.patch"