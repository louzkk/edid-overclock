set -e

FIRMWARE_DIR="/lib/firmware/edid"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
GRUB_CONF="/etc/default/grub"
SYSTEMD_BOOT_ENTRIES="/boot/loader/entries"

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
    exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || die "Run with sudo."
}

detect_bootloader() {
    if [[ -f "$GRUB_CONF" ]]; then
        echo "grub"
    elif [[ -d "$SYSTEMD_BOOT_ENTRIES" ]]; then
        echo "systemd-boot"
    else
        die "Could not detect bootloader. Specify with --bootloader."
    fi
}

rebuild_initramfs() {
    echo "→ Rebuilding initramfs"
    mkinitcpio -P
}

grub_add_param() {
    local param="$1"
    if grep -q "drm.edid_firmware" "$GRUB_CONF"; then
        sed -i "s|drm\.edid_firmware=[^ '\"]*|${param}|g" "$GRUB_CONF"
    else
        sed -i "s|\(GRUB_CMDLINE_LINUX_DEFAULT='[^']*\)'|\1 ${param}'|" "$GRUB_CONF"
    fi
    echo "→ Updating grub.cfg"
    grub-mkconfig -o /boot/grub/grub.cfg
}

grub_remove_param() {
    sed -i "s| drm\.edid_firmware=[^ '\"]*||g" "$GRUB_CONF"
    echo "→ Updating grub.cfg"
    grub-mkconfig -o /boot/grub/grub.cfg
}

sd_boot_add_param() {
    local param="$1"
    local entries
    entries=$(find "$SYSTEMD_BOOT_ENTRIES" -name "*.conf" | head -5)
    [[ -z "$entries" ]] && die "No entries found in $SYSTEMD_BOOT_ENTRIES"
    for entry in $entries; do
        if grep -q "^options" "$entry"; then
            if grep -q "drm.edid_firmware" "$entry"; then
                sed -i "s|drm\.edid_firmware=[^ ]*|${param}|g" "$entry"
            else
                sed -i "s|^\(options .*\)|\1 ${param}|" "$entry"
            fi
            echo "→ Updated $entry"
        fi
    done
}

sd_boot_remove_param() {
    local entries
    entries=$(find "$SYSTEMD_BOOT_ENTRIES" -name "*.conf" | head -5)
    for entry in $entries; do
        sed -i "s| drm\.edid_firmware=[^ ]*||g" "$entry"
        echo "→ Cleaned $entry"
    done
}

initcpio_add_file() {
    local path="$1"
    if grep -q "^FILES=" "$MKINITCPIO_CONF"; then
        if grep -q "$path" "$MKINITCPIO_CONF"; then
            echo "   $path already in FILES=, skipping."
        else
            sed -i "s|^FILES=(|FILES=(${path} |" "$MKINITCPIO_CONF"
        fi
    else
        echo "FILES=($path)" >> "$MKINITCPIO_CONF"
    fi
}

initcpio_remove_file() {
    local path="$1"
    sed -i "s|${path} ||g" "$MKINITCPIO_CONF"
    sed -i "s| ${path}||g" "$MKINITCPIO_CONF"
}

install_edid() {
    local bin_file="$1"
    local output="$2"
    local bootloader="$3"
    local bin_name
    bin_name=$(basename "$bin_file")

    [[ -f "$bin_file" ]] || die "File '$bin_file' not found."

    echo "→ Copying $bin_name to $FIRMWARE_DIR/"
    mkdir -p "$FIRMWARE_DIR"
    cp "$bin_file" "$FIRMWARE_DIR/$bin_name"

    echo "→ Updating $MKINITCPIO_CONF"
    initcpio_add_file "$FIRMWARE_DIR/$bin_name"

    local param="drm.edid_firmware=${output}:edid/${bin_name}"
    echo "→ Adding kernel parameter: $param"
    case "$bootloader" in
        grub)         grub_add_param "$param" ;;
        systemd-boot) sd_boot_add_param "$param" ;;
    esac

    rebuild_initramfs

    echo ""
    echo "Done. Reboot to apply."
    echo "Verify afterwards with: kscreen-doctor -o"
}

remove_edid() {
    local bin_file="$1"
    local bootloader="$2"
    local bin_name
    bin_name=$(basename "$bin_file")

    echo "→ Removing kernel parameter"
    case "$bootloader" in
        grub)         grub_remove_param ;;
        systemd-boot) sd_boot_remove_param ;;
    esac

    echo "→ Updating $MKINITCPIO_CONF"
    initcpio_remove_file "$FIRMWARE_DIR/$bin_name"

    rebuild_initramfs

    echo ""
    echo "EDID removed. Reboot to restore defaults."
}

check_root

ACTION="$1"; shift || usage
BIN_FILE="$1"; shift || usage
[[ "$ACTION" == "install" ]] && { OUTPUT="$1"; shift || usage; }

BOOTLOADER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bootloader) BOOTLOADER="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$BOOTLOADER" ]] && BOOTLOADER=$(detect_bootloader)
[[ "$BOOTLOADER" == "grub" || "$BOOTLOADER" == "systemd-boot" ]] \
    || die "Unknown bootloader '$BOOTLOADER'. Use grub or systemd-boot."

case "$ACTION" in
    install) install_edid "$BIN_FILE" "$OUTPUT" "$BOOTLOADER" ;;
    remove)  remove_edid  "$BIN_FILE" "$BOOTLOADER" ;;
    *)       usage ;;
esac