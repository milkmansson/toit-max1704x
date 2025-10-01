
// Copyright (C) 2025 Toit Contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import system
import gpio
import i2c

import bme280

import ssd1306 show *
import pixel-display show *
import pixel-display.two-color show *

import font show *
import font-x11-adobe.sans-08
import font-x11-adobe.sans-08-bold

//import ublox-gnss as ublox-gnss

import ..src.max1704x show *
import ...toit-ina226.src.ina226 show *
import ...toit-tp4057.src.tp4057 show *
import ...toit-timehelper.src.timehelper show *
import ...toit-bh1750.src.bh1750 show *

/**
Battery Display Test

This test attempts to watch the battery drainage over an extended time to
determine it's correct operation.  Some ESP models with battery connectors
and built in chargers have USB lines tied such that level voltages for the
battery gauge IC will be incorrect.  This example was created to be independent
of usb/jag monitor, such that the results can be tested much more firmly.

This example uses the following I2C based components:
  - MAX17048 or MAX27049 for testing
  - SSD1306 for displaying the results throughout the test
  - An ESP32 of choice - in my case DFRobot ESP32c6 Beetle with battery pins
  - INA226 (Optional - for validating results).
  - TP4057 (Optional - my ESP32 has one of these charging IC's onboard).


*/

ESP32-SDA-PIN               ::= 26
ESP32-SCL-PIN               ::= 25
ESP32-INTERRUPT-PIN         ::= 33

ESP32C6-SDA-PIN             ::= 19
ESP32C6-SCL-PIN             ::= 20
ESP32C6-PWR-LED-PIN         ::= 15
ESP32C6-RX                  ::= 17
ESP32C6-TX                  ::= 16

time-start-us/int   := Time.monotonic-us

time-helper     := null
time-zone-helper:= null
ssd1306-device  := null
ssd1306-driver  := null
pixel-display   := null
ina226-driver   := null
bme280-driver   := null
bh1750-driver   := null
max1704x-driver := null

ic-label/Label := ?
uptime-label/Label := ?
vcell-label/Label := ?
soc-label/Label := ?
soc-rate-label/Label := ?

info1-l/Label := ?
info1-c/Label := ?
info1-r/Label := ?
info2-l/Label := ?
info2-c/Label := ?
info2-r/Label := ?

volts/Label   := ?
amps/Label    := ?
watts/Label   := ?

header/Label  := ?

tp4057-driver/Tp4057? := null

main:
  sda-pin-number      := 0
  scl-pin-number      := 0

  // Rudimentary pin selection for my two devices
  if system.architecture == "esp32c6":
    // Beetle pins
    sda-pin-number = ESP32C6-SDA-PIN
    scl-pin-number = ESP32C6-SCL-PIN
  else:
    sda-pin-number = ESP32-SDA-PIN
    scl-pin-number = ESP32-SCL-PIN

  // Initialise I2C
  frequency := 400_000
  sda-pin := gpio.Pin sda-pin-number
  scl-pin := gpio.Pin scl-pin-number
  bus := i2c.Bus --sda=sda-pin --scl=scl-pin --frequency=frequency
  scandevices := bus.scan

  // Initialise Display, throw if not present.
  if not scandevices.contains Ssd1306.I2C-ADDRESS:
    throw "No SSD1306 display found"
    return

  ssd1306-device = bus.device Ssd1306.I2C-ADDRESS // --height=32 for the smaller display
  ssd1306-driver = Ssd1306.i2c ssd1306-device
  pixel-display = PixelDisplay.two-color ssd1306-driver
  pixel-display.background = BLACK
  pixel-display.draw

  font-sans-08/Font      := Font [sans-08.ASCII, sans-08.LATIN-1-SUPPLEMENT]
  font-sans-08-b/Font    := Font [sans-08-bold.ASCII, sans-08-bold.LATIN-1-SUPPLEMENT]
  style-sans-08-l/Style    := Style --font=font-sans-08 --color=WHITE
  style-sans-08-r/Style  := Style --font=font-sans-08 --color=WHITE --align-right
  style-sans-08-c/Style  := Style --font=font-sans-08 --color=WHITE --align-center
  style-sans-08-bc/Style := Style --font=font-sans-08-b --color=WHITE --align-center
  style-map              := Style --type-map={"label": style-sans-08-l}
  pixel-display.set-styles [style-map]

  [
    Label --x=64 --y=10 --id="header"  --style=style-sans-08-bc,

    Label --x=0 --y=20 --id="ic"       --style=style-sans-08-l,
    Label --x=128 --y=20 --id="uptime" --style=style-sans-08-r,

    Label --x=0 --y=30 --id="vcell"      --style=style-sans-08-l,
    Label --x=58 --y=30 --id="soc"       --style=style-sans-08-c,
    Label --x=128 --y=30 --id="soc-rate" --style=style-sans-08-r,

    Label --x=0 --y=40 --id="info1-l" --style=style-sans-08-l,
    Label --x=58 --y=40 --id="info1-c" --style=style-sans-08-c,
    Label --x=128 --y=40 --id="info1-r" --style=style-sans-08-r,

    Label --x=0 --y=50 --id="info2-l" --style=style-sans-08-l,
    Label --x=70 --y=50 --id="info2-c" --style=style-sans-08-c,
    Label --x=128 --y=50 --id="info2-r" --style=style-sans-08-r,

    Label --x=0  --y=64 --id="volts"   --style=style-sans-08-l,
    Label --x=64   --y=64 --id="amps"  --style=style-sans-08-c,
    Label --x=128 --y=64 --id="watts"  --style=style-sans-08-r,
  ].do: pixel-display.add it

  ic-label = pixel-display.get-element-by-id "ic"
  uptime-label = pixel-display.get-element-by-id "uptime"
  vcell-label = pixel-display.get-element-by-id "vcell"
  soc-label = pixel-display.get-element-by-id "soc"
  soc-rate-label = pixel-display.get-element-by-id "soc-rate"

  info1-l = pixel-display.get-element-by-id "info1-l"
  info1-c = pixel-display.get-element-by-id "info1-c"
  info1-r = pixel-display.get-element-by-id "info1-r"
  info2-l = pixel-display.get-element-by-id "info2-l"
  info2-c = pixel-display.get-element-by-id "info2-c"
  info2-r = pixel-display.get-element-by-id "info2-r"

  volts   = pixel-display.get-element-by-id "volts"
  amps    = pixel-display.get-element-by-id "amps"
  watts   = pixel-display.get-element-by-id "watts"

  header  = pixel-display.get-element-by-id "header"

  header.text   = "MAX1704x Battery Test"
  pixel-display.draw

  // Get/keep time Updated to help with display/testing.
  time-helper      = TimeHelper
  time-zone-helper = TimezoneHelper
  task:: time-zone-helper.update-data-from-internet
  task:: time-zone-helper.update-timezone
  time-helper.maintain-system-time-via-ntp
  task:: update-screen

  // Setup INA226 (if present) - to validate measured values.
  if not scandevices.contains Ina226.I2C-ADDRESS:
    print "No INA226 device found"
  else:
    ina226-driver = Ina226 (bus.device Ina226.I2C-ADDRESS)
    ina226-driver.set-sampling-rate Ina226.AVERAGE-1024-SAMPLES
    ina226-driver.set-shunt-resistor 0.100
  task:: update-screen

  // Setup TP4057 - comment out if not present.
  tp4057-exception      := catch --trace:
    tp4057-driver  = Tp4057 --adc-pin=(gpio.Pin 0)
  if tp4057-exception:
    // No Tp4057 Device
  if tp4057-driver != null:
    tp4057-driver.set-sampling-size 100
    tp4057-driver.set-sampling-rate 4
  task:: update-screen

  // Setup BME280 - Environment Sensor - as load.
  if not scandevices.contains bme280.I2C-ADDRESS:
    print "No BME280 device found [0x$(%02x bme280.I2C-ADDRESS)]"
  else:
    bme280-driver = bme280.Driver (bus.device bme280.I2C-ADDRESS)
  task:: update-screen

  // Setup BH1750 - Ambient Light Sensor - as load.
  if not scandevices.contains Bh1750.I2C-ADDRESS:
    print "No BH1750 device found [0x$(%02x Bh1750.I2C-ADDRESS)]"
  else:
    bh1750-driver = Bh1750 (bus.device Bh1750.I2C-ADDRESS)
  task:: update-screen

  // Setup MAX1704x driver.
  if not scandevices.contains Max1704x.I2C-ADDRESS:
    print "No MAX1704x device found [0x$(%02x Max1704x.I2C-ADDRESS)]"
  else:
    max1704x-driver = Max1704x (bus.device Max1704x.I2C_ADDRESS)
    max1704x-driver.set-design-capacity-mah 3700.0
    max1704x-driver.set-design-capacity-wh 13.7

  task:: update-screen-task

update-screen-task -> none:
  while true:
    update-screen
    sleep --ms=250

update-screen -> none:
  if time-helper != null:
    ic-label.text          = "$(time-helper.current-time)"
    uptime-label.text      = "$(us-to-stopwatch time-start-us Time.monotonic-us)"
  else:
    uptime-label.text      = "$(us-to-stopwatch time-start-us Time.monotonic-us)"

  if max1704x-driver != null:
    if time-helper == null:
      ic-label.text          = "IC:$(%02d max1704x-driver.get-chip-version).$(%02d max1704x-driver.get-chip-id)"
    vcell-label.text       = "$(%0.3f max1704x-driver.read-cell-voltage)v"
    soc-label.text         = "$(%0.2f max1704x-driver.read-cell-state-of-charge)%"
    soc-rate-label.text    = "$(%0.2f max1704x-driver.read-cell-charge-rate)%/h"
  else:
    vcell-label.text       = "[No max1704x]"
    soc-label.text         = "-"
    soc-rate-label.text    = "-"

  if bme280-driver != null:
    info2-l.text           = "$(%0.1f bme280-driver.read-temperature)°C"
    info2-c.text           = "$(%0.4f bme280-driver.read-pressure * 0.01 / 1000)b"
    info2-r.text           = "$(%0.1f bme280-driver.read-humidity)%"
  else:
    info2-l.text           = "[No bme280]"
    info2-c.text           = "-"
    info2-r.text           = "-"

  if (tp4057-driver != null):
    info1-l.text           = "$(%0.3f tp4057-driver.read-voltage)v"
    info1-c.text           = "$(%0.2f tp4057-driver.estimate-state-of-charge * 100)%"
  else:
    info1-l.text           = "[No tp4057]"
    info1-l.text           = "-"

  if (bh1750-driver != null):
    info1-r.text           = "$(%0.2f bh1750-driver.read-lux)lx"
  else:
    info1-r.text           = "[No bh1750]"

  if ina226-driver != null:
    volts.text    = "$(%0.3f ina226-driver.read-supply-voltage)v"
    amps.text     = "$(%0.3f ina226-driver.read-shunt-current)a"
    watts.text    = "$(%0.3f ina226-driver.read-load-power)w"
  else:
    volts.text    = "[No INA226 found]"
    amps.text     = "-"
    watts.text    = "-"

  pixel-display.draw


// return uptime in since start using time.monotonic-us
us-to-stopwatch start-us/int now-us/int -> string:
  total-us := now-us - start-us
  total-s  := total-us / 1_000_000
  s        := total-s % 60
  total-m  := total-s / 60
  m        := total-m % 60
  h        := total-m / 60
  h-string := (h > 0) ? "$(%02d h):" : ""
  return "$(h-string)$(%02d m):$(%02d s)"

  //uptime-h := uptime.in-h
  //uptime-m := uptime - (Duration --h=uptime.in-h)
  //uptime-s := uptime - (Duration --h=uptime.in-h) - (Duration --h=uptime.in-h)
  //return out
