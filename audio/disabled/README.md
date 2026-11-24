# Disabled Houji playback audio (AERA_HANDOFF.md section 73)

Not packaged: recovery/root is the only ramdisk overlay. To re-enable, restore
houji.audio.xml to recovery/root/vendor/etc/vintf/manifest/, append
init.recovery.houji-audio.optional.rc after a blank CRLF line in
recovery/root/init.recovery.houji-audio.rc, add $(HOUJI_AUDIO_POST_DECRYPT_MODULES)
after network9 in BoardConfig.mk and request aera-audio-bridge/aera-agm-service
in device.mk. Encrypted Stock HyperOS PIN acceptance must pass first.
