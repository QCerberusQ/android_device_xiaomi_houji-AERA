#
#
# aera_houji.mk - Aera Configuration for Xiaomi 14 (houji)
#
#

# -----------------------------------------------------------------------------
# Maintainer
# -----------------------------------------------------------------------------
AERA_MAINTAINER := QCerberusQ

# -----------------------------------------------------------------------------
# Screen / cutout
# -----------------------------------------------------------------------------
#
AERA_SCREEN_H             := 2400
AERA_STATUS_H             := 120
AERA_STATUS_INDENT_LEFT   := 48
AERA_STATUS_INDENT_RIGHT  := 48
AERA_HIDE_NOTCH           := 1
AERA_CLOCK_POS            := 1
AERA_ALLOW_DISABLE_NAVBAR := 0
AERA_OPTIONS_LIST_NUM     := 8

# -----------------------------------------------------------------------------
# A/B + dedicated recovery partition
# -----------------------------------------------------------------------------
AERA_AB_DEVICE_WITH_RECOVERY_PARTITION := 1

# -----------------------------------------------------------------------------
# Dynamic partitions / partition tooling
# -----------------------------------------------------------------------------
AERA_USE_DMCTL                  := 1
AERA_ENABLE_LPTOOLS             := 1
AERA_ENABLE_ALL_PARTITION_TOOLS := 1

# -----------------------------------------------------------------------------
# Encryption / decryption (FBE + metadata)
# -----------------------------------------------------------------------------
AERA_FBE_METADATA_MOUNT_IGNORE      := 1
AERA_SKIP_DECRYPTED_ADOPTED_STORAGE := 1

ifeq ($(FIXED_DECRYPT),false)
	# Set to 1 to skip the FBE decryption routines (prevents hanging at the Aera logo or Redmi/Mi logo)
	AERA_SKIP_FBE_DECRYPTION := 1
endif

# -----------------------------------------------------------------------------
# Data format
# -----------------------------------------------------------------------------
AERA_FORCE_CASEFOLDING              := 1
AERA_UNBIND_SDCARD_F2FS             := 1
AERA_WIPE_METADATA_AFTER_DATAFORMAT := 1
AERA_VAB_ORS_WIPE_DATA_IS_FORMAT    := 1

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------
AERA_QUICK_BACKUP_LIST := /boot;/data;/metadata;/vendor_boot;/dtbo;
AERA_SKIP_MULTIUSER_FOLDERS_BACKUP := 1

# -----------------------------------------------------------------------------
# Ramdisk compression - pairs with BOARD_RAMDISK_USE_LZ4 := true
# -----------------------------------------------------------------------------
AERA_USE_LZ4_COMPRESSION := 1

# -----------------------------------------------------------------------------
# Misc / device quirks
# -----------------------------------------------------------------------------
AERA_NO_TREBLE_COMPATIBILITY_CHECK  := 1
AERA_NO_ADDITIONAL_MIUI_PROPS_CHECK := 1
AERA_NO_SPLASH_CHANGE               := 1
AERA_USE_GREEN_LED                  := 0
AERA_UNMOUNT_SDCARDS_BEFORE_REBOOT  := 1
AERA_ENABLE_FRP_WIPE                := 1

# -----------------------------------------------------------------------------
# Wlan
# -----------------------------------------------------------------------------
AERA_ENABLE_WLAN := 1

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
AERA_LOOP_DEVICE_ERRORS_TO_LOG := 1
AERA_DONT_KEEP_LOG_HISTORY     := 0
