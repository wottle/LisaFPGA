# esp32_wifi_test

Bench test for the FPGA side of ESP32 WiFi mode (LisaNet): runs on the ESFloppy ESP32-S3 **in place of ESFloppy** and
exercises `ESFLOPPY_COMM_BUS[5:3]` (MODE on GPIO37, Lisa TX into GPIO38, GPIO39 out to the Lisa's RX). Not the WiFi
firmware. Written with an AI assistant. Details are in the header of `esp32_wifi_test.ino`.

## Back up first

ESFloppy is identified by its firmware strings ("ESFloppy", "Twiggy"); on the development machine it is **COM4**
(MAC `ac:a7:04:04:78:94`) and ESProFile is COM3. The port numbers can change -- check before writing anything.

    esptool --chip esp32s3 --port COM4 read-flash 0 0x800000 backup/esfloppy_flash_backup.bin

Read it twice and compare checksums. `backup/` is git-ignored.

## Build and flash (arduino-cli + ESP32 core 3.3.12)

    arduino-cli compile --fqbn "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=8M" esp32_wifi_test
    arduino-cli upload  --fqbn "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=8M" -p COM4 esp32_wifi_test

Console: the same COM port at 115200. Toggle ESP32 MODE in the LisaFPGA menu and watch for `[mode]` lines; in WIFI
mode, LisaTerminal on Serial A at 9600 8N1 should see its typing echoed back.

## Restore ESFloppy

    esptool --chip esp32s3 --port COM4 write-flash 0 backup/esfloppy_flash_backup.bin

That rewrites the whole 8 MB exactly as it was, bootloader, partition table and data included.
