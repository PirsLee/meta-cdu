FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "file://0002-schemas-add-entity-manager-schemas-uart_port.json.patch \
            file://0003-schemas-add-ConfigSchema-in-exposes_record.json.patch \
            "

do_install:append() {
    install -d ${D}${datadir}/entity-manager/schemas
    install -m 0644 ${S}/schemas/uart_port.json ${D}${datadir}/entity-manager/schemas/
}